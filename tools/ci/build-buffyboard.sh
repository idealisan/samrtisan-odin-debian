#!/bin/bash
# tools/ci/build-buffyboard.sh —— 在 arm64 根里编译 BuffyBoard（触屏虚拟键盘）
#
#   tools/ci/build-buffyboard.sh <arm64 根文件系统目录>
#
# 产物直接装进这个根：/usr/bin/buffyboard + /etc/buffyboard.conf +
# /usr/lib/systemd/system/buffyboard.service + getty@.service.d/buffyboard.conf
#
# ---------------------------------------------------------------------------
# 为什么在 chroot 里编，而不是交叉编译
# ---------------------------------------------------------------------------
# BuffyBoard 依赖 libinput / libudev / libdrm / xkbcommon / inih，全是动态库。
# 要交叉编译就得在 runner（Ubuntu）上装这些的 arm64 版 —— 于是跟 rmtfs 当初
# 踩的是同一个坑：链接进去的 glibc 符号版本高于设备上 Debian bookworm 的 2.36，
# 构建期全绿、设备上运行时才 `GLIBC_2.xx not found`。
#
# 所以这里改成：**在 debootstrap 出来的 arm64 根里、借 qemu-user-static 直接编**。
# 用的是根里自己的 bookworm 库，ABI 天然一致。代价是 qemu 下编译慢一些
# （471 个编译单元，原生 arm64 约 19 秒，qemu 下数分钟），可接受。
#
# 编完把构建依赖 purge 掉、清掉源码树与 apt 缓存，镜像里只留下二进制和运行时库。
#
# ---------------------------------------------------------------------------
# 上游锚点（钉死）
# ---------------------------------------------------------------------------
#   buffybox  gitlab.postmarketos.org/postmarketOS/buffybox @ 3.6.0
#             == d0f52495f7f3afa8839eef4b19f43f4ca1243107
#   lvgl      子模块 @ 85aa60d18b3d5e5588d7b247abf90198f07c8a63
#             （https://github.com/lvgl/lvgl.git，buffybox 的 .gitmodules 指定）
#
# -Dsystemd=true 很关键：带上它 meson 才会生成 buffyboard.service 与
# getty@.service.d/buffyboard.conf（后者会在新 getty 会话时给 buffyboard 发
# SIGUSR1 让它重绘）。自己手写 unit 容易漏掉这个联动。

set -euo pipefail

say() { printf '[buffyboard] %s\n' "$*"; }

ROOT=${1:?用法: build-buffyboard.sh <arm64 根目录>}
[ -d "$ROOT/etc" ] || { echo "[buffyboard] 不像一个根目录: $ROOT" >&2; exit 1; }

BUFFYBOX_URL=https://gitlab.postmarketos.org/postmarketOS/buffybox.git
BUFFYBOX_REF=3.6.0
LVGL_SHA=85aa60d18b3d5e5588d7b247abf90198f07c8a63

SRCDIR=/usr/src/buffybox
BUILD=$SRCDIR/_build

# 构建期需要；运行时只需要右边那组
BUILD_DEPS="gcc meson ninja-build pkg-config git ca-certificates \
            libinih-dev libinput-dev libudev-dev libxkbcommon-dev libdrm-dev"
# 显式装成"手动安装"，免得 purge 构建依赖时被 autoremove 一起带走
RUN_DEPS="libinput10 libdrm2 libxkbcommon0 libinih1"

# chroot 里的 apt / git 都要解析域名，而 Debian 默认把 resolv.conf 做成指向
# systemd-resolved 的符号链接 —— 设备没事，构建 chroot 里它是悬空的。
# 跟 setup-rootfs.sh 的 fix_dns 同一套做法：拿构建环境的顶上。
# 导出镜像前 build-rootfs.sh 的「导出前卫生」会把它换回 stub 符号链接，
# 不会把构建机的 DNS 带进发布镜像。这里再确认一次是为了不依赖调用顺序。
if [ -L "$ROOT/etc/resolv.conf" ] || [ ! -s "$ROOT/etc/resolv.conf" ]; then
	rm -f "$ROOT/etc/resolv.conf"
	cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf"
	say "resolv.conf: 换成构建环境的（chroot 内要解析域名）"
fi

say "装构建依赖（在 arm64 根里，qemu 下会慢一点）"
chroot "$ROOT" apt-get update -qq
chroot "$ROOT" apt-get install -y -qq --no-install-recommends $RUN_DEPS $BUILD_DEPS

say "取源码 buffybox @ $BUFFYBOX_REF"
chroot "$ROOT" sh -c "
	set -e
	rm -rf '$SRCDIR'
	mkdir -p '$SRCDIR'
	cd '$SRCDIR'
	git init -q
	git remote add origin '$BUFFYBOX_URL'
	git fetch -q --depth 1 origin '$BUFFYBOX_REF'
	git checkout -q FETCH_HEAD
"

say "取 lvgl 子模块 @ ${LVGL_SHA:0:12}"
chroot "$ROOT" sh -c "
	set -e
	cd '$SRCDIR'
	git submodule init -q
	git -c protocol.version=2 submodule update --depth 1 -q
	git -C lvgl rev-parse HEAD
"

say "配置与编译（meson + ninja）"
chroot "$ROOT" sh -c "
	set -e
	cd '$SRCDIR'
	meson setup '$BUILD' -Dman=false -Dsystemd=true
	meson compile -C '$BUILD' buffyboard
"

say "装进根文件系统"
install -d -m 0755 "$ROOT/usr/bin"
install -m 0755 "$ROOT$BUILD/buffyboard/buffyboard" "$ROOT/usr/bin/buffyboard"
chroot "$ROOT" strip /usr/bin/buffyboard 2>/dev/null || true
install -m 0644 "$ROOT$SRCDIR/buffyboard/buffyboard.conf" "$ROOT/etc/buffyboard.conf"
install -d -m 0755 "$ROOT/usr/lib/systemd/system"
install -m 0644 "$ROOT$BUILD/buffyboard/buffyboard.service" \
	"$ROOT/usr/lib/systemd/system/buffyboard.service"
install -d -m 0755 "$ROOT/usr/lib/systemd/system/getty@.service.d"
install -m 0644 "$ROOT$SRCDIR/buffyboard/getty-buffyboard.conf" \
	"$ROOT/usr/lib/systemd/system/getty@.service.d/buffyboard.conf"
say "  /usr/bin/buffyboard $(stat -c%s "$ROOT/usr/bin/buffyboard" 2>/dev/null || stat -f%z "$ROOT/usr/bin/buffyboard") 字节"

# uinput 是模块（CONFIG_INPUT_UINPUT=m），BuffyBoard 靠它造虚拟键盘设备。
# 不预加载的话 /dev/uinput 打不开，键盘起不来。
install -d -m 0755 "$ROOT/etc/modules-load.d"
printf 'uinput\n' > "$ROOT/etc/modules-load.d/odin-uinput.conf"

# 启用服务。getty@tty1 也要显式开：键盘是给登录提示词用的，framebuffer 上
# 没有 getty 就只剩一块键盘、无处可输。
chroot "$ROOT" systemctl enable buffyboard.service getty@tty1.service
say "  已启用 buffyboard.service 与 getty@tty1.service"

say "清掉构建依赖与源码树（镜像里只留产物）"
chroot "$ROOT" apt-get purge -y -qq $BUILD_DEPS
chroot "$ROOT" apt-get autoremove --purge -y -qq
chroot "$ROOT" apt-get clean
chroot "$ROOT" sh -c "rm -rf '$SRCDIR' /var/lib/apt/lists/*"
say "完成"
