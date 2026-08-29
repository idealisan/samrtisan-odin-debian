#!/bin/bash
# tools/ci/build-rootfs.sh —— 从零组装 odin-debian 刷机镜像
#
#   tools/ci/build-rootfs.sh <输出目录> [内核产物目录] [DTB 产物目录]
#
# 流程：debootstrap bookworm/arm64 → 装内核模块与 vmlinuz → 造 initramfs
#      → setup-rootfs.sh（用户/网络/服务）→ apply-staging-fixes.sh（增量修复）
#      → build-image.sh（保守特性集 + 导出 + 逐项回读校验）
#
# 这一步刻意不依赖任何"上一次构建留下来的东西"：根文件系统从发行版现装，
# 内核由 build-kernel.sh 的产物提供，DTB 由 build-dtb.sh 的产物提供。
# 唯一不能现造的是 busybox —— 它的二进制不入库（见 .gitignore），
# 这里从刚 debootstrap 完的 arm64 根里装 busybox-static 再拷出来，
# 于是整个链路仍然是从源码/发行版出发、可复现的。
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-rootfs.sh <输出目录> [内核产物目录] [DTB 产物目录]}
KOUT=${2:-$OUT/../kernel}
DOUT=${3:-$OUT/../dtb}
ROOT=${ROOT:-/tmp/odin-rootfs}
SUITE=${SUITE:-bookworm}

mkdir -p "$OUT"
# 必须转绝对路径：下面会 cd 进内核树，届时 "out/kernel" 这种相对路径就指到别处去了
# （CI 上表现为编译 22 分钟成功、最后 cp 时 "No such file or directory"）
OUT=$(cd "$OUT" && pwd)
say() { printf '[rootfs] %s\n' "$*"; }
[ -f "$KOUT/vmlinuz" ] || { echo "缺内核产物: $KOUT/vmlinuz（先跑 build-kernel.sh）" >&2; exit 1; }

# ---------------------------------------------------------------- 1. debootstrap
if [ ! -d "$ROOT/etc" ]; then
  say "debootstrap $SUITE / arm64 → $ROOT"
  rm -rf "$ROOT"; mkdir -p "$ROOT"
  debootstrap --arch arm64 --variant=minbase \
    --include=busybox-static,udev,ssh,sudo,systemd,iproute2,dnsmasq,parted,e2fsprogs \
    "$SUITE" "$ROOT" http://deb.debian.org/debian \
    2>&1 | tee /tmp/odin-debootstrap.log
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "debootstrap 失败，日志见上面" >&2
    exit 1
  fi
fi
say "rootfs 就绪: $ROOT"

# ---------------------------------------------------------------- 2. 内核模块 + vmlinuz
say "安装内核模块与 vmlinuz"
mkdir -p "$ROOT/boot"
install -m 0644 "$KOUT/vmlinuz" "$ROOT/boot/vmlinuz"
TMPMOD=$(mktemp -d)
tar -xf "$KOUT/modules.tar" -C "$TMPMOD"
mkdir -p "$ROOT/usr/lib/modules"
cp -a "$TMPMOD"/lib/modules/. "$ROOT/usr/lib/modules/"
rm -rf "$TMPMOD"
KVER=$(ls "$ROOT/usr/lib/modules" | head -1)
say "  内核版本: $KVER"
depmod -b "$ROOT" "$KVER"

# ---------------------------------------------------------------- 3. initramfs
# busybox 二进制不入库，从刚装的 arm64 根里取（busybox-static 无动态依赖，
# 省掉拷一堆 .so 的麻烦）
say "造 initramfs"
ISTAGE=$(mktemp -d)
cp -a "$REPO/dist/build/initramfs/." "$ISTAGE/"
BB=$ROOT/bin/busybox
[ -x "$BB" ] || { echo "rootfs 里没有 /bin/busybox" >&2; exit 1; }
install -m 0755 "$BB" "$ISTAGE/bin/busybox"
while read -r applet; do
  [ -e "$ISTAGE/bin/$applet" ] && rm -f "$ISTAGE/bin/$applet"
  ln -sf busybox "$ISTAGE/bin/$applet"
done < <(cd "$REPO/dist/build/initramfs/bin" && ls | grep -v '^busybox$')
for d in sbin usr/bin usr/sbin; do
  while read -r applet; do
    [ -L "$ISTAGE/$d/$applet" ] || ln -sf /bin/busybox "$ISTAGE/$d/$applet"
  done < <(cd "$REPO/dist/build/initramfs/$d" 2>/dev/null && ls)
done
mkdir -p "$ROOT/boot"
"$REPO/tools/pack_initramfs.sh" "$ISTAGE" "$ROOT/boot/initramfs.cpio.gz"
rm -rf "$ISTAGE"
say "  initramfs: $(stat -c%s "$ROOT/boot/initramfs.cpio.gz") 字节"

# ---------------------------------------------------------------- 4. 系统配置
say "setup-rootfs.sh（用户 / 网络 / 服务）"
ODIN_ROOTFS="$ROOT" "$REPO/dist/build/setup-rootfs.sh"

say "apply-staging-fixes.sh（增量修复 + overlay + DTB + extlinux）"
# 用 CI 刚编出来的 DTB，而不是仓库里（可能过期的）那份
if [ -d "$DOUT" ]; then
  mkdir -p "$ROOT/boot/dtbs/qcom"
  cp -f "$DOUT"/*.dtb "$ROOT/boot/dtbs/qcom/"
fi
"$REPO/dist/build/apply-staging-fixes.sh" "$ROOT"

# ---------------------------------------------------------------- 5. 导出镜像
say "build-image.sh（保守特性集 + 导出 + 回读校验）"
"$REPO/tools/build-image.sh" "$ROOT" "$OUT/odin-debian.img" 524288 pmOS_root

say "产物："
ls -la "$OUT"
