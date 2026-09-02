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
# 内核由 `make kernel` 的产物提供，DTB 由 `make dtb` 的产物提供。
# 唯一不能现造的是 busybox —— 它的二进制不入库（见 .gitignore），
# 这里从刚 debootstrap 完的 arm64 根里装 busybox-static 再拷出来，
# 于是整个链路仍然是从源码/发行版出发、可复现的。
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-rootfs.sh <输出目录> [内核产物目录] [DTB 产物目录]}
KOUT=${2:-$OUT/../kernel}
DOUT=${3:-$OUT/../dtb}
# 变体由 make 的 ODIN_VARIANT 传下来（core 无 GUI / gui 带 Plasma Mobile）。
# 只影响两件事：装什么包（交给 setup-rootfs.sh）与产出镜像叫什么名字。
VARIANT=${ODIN_VARIANT:-core}
case "$VARIANT" in
	core|gui) ;;
	*) echo "[rootfs] 未知变体: $VARIANT（可选 core / gui）" >&2; exit 1 ;;
esac
STAGE_CACHE_HIT=${ODIN_STAGE_CACHE_HIT:-false}
# staging 根目录必须按变体分开。debootstrap 是重活，下面靠
# `if [ ! -d "$ROOT/etc" ]` 判断是否要重来；两个变体共用一个目录时，
# 第二个变体会直接复用第一个已经摆好的根 —— 表现为"编了 gui，出来的却是 core"。
ROOT=${ROOT:-/tmp/odin-rootfs-$VARIANT}
SUITE=${SUITE:-bookworm}
# 镜像站：本地构建走国内镜像（debootstrap 与 chroot 里的 apt 都用它），
# CI 不设这个变量、用官方源。只影响构建速度 —— 导出镜像前会把 chroot 的
# sources.list 还原成官方源，免得本地编出来的镜像与 CI 编出来的内容不一致
# （发布制品以 CI 为准，两者不该有差异）。
MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}

mkdir -p "$OUT"
# 必须转绝对路径：下面会 cd 进内核树，届时 "out/kernel" 这种相对路径就指到别处去了
# （CI 上表现为编译 22 分钟成功、最后 cp 时 "No such file or directory"）
OUT=$(cd "$OUT" && pwd)
say() { printf '[rootfs] %s\n' "$*"; }
[ -f "$KOUT/vmlinuz" ] || { echo "缺内核产物: $KOUT/vmlinuz（先跑 make kernel）" >&2; exit 1; }

say "变体: $VARIANT（staging: $ROOT）"
# ---------------------------------------------------------------- 1. debootstrap
#
# 2026-09-01：debootstrap 是整个 rootfs job 最大的单项开销（core 变体实测
# 283 秒、占 83%），但它的产物只由 suite / arch / --include 决定，**与变体无关**
# —— 每轮重跑纯属浪费。所以在 debootstrap 之后、装变体包之前打一份 tar
# 交给 actions/cache，下一轮直接解开。
#
# 两个必须遵守的约束（顺序错了就会缓存进不该缓存的东西）：
#   1) 打包点在"装变体包"**之前** —— 否则缓存里会混进 core/gui 的差异包；
#   2) 也在改 sources.list **之前** —— 缓存里留官方源，恢复后再按 $MIRROR 改。
#
# 缓存键由 workflow 计算（suite + arch + debootstrap 版本 + --include 列表，
# 见 .github/workflows/release-build.yml）。这里只按 $ODIN_BASE_TAR 指到的路径
# 解包 / 打包；不设这个变量就退化成原来的行为（总是 debootstrap）。
BASE_TAR=${ODIN_BASE_TAR:-}
if [ ! -d "$ROOT/etc" ]; then
  if [ -n "$BASE_TAR" ] && [ -s "$BASE_TAR" ]; then
    say "从缓存恢复基础根: $BASE_TAR → $ROOT"
    mkdir -p "$ROOT"
    if ! tar -xzf "$BASE_TAR" -C "$ROOT"; then
      echo "基础根缓存解包失败: $BASE_TAR" >&2
      exit 1
    fi
    # proc / sys 是伪文件系统、不进包，但目录要在（后面 chroot 要用）
    mkdir -p "$ROOT/proc" "$ROOT/sys"
  else
    say "debootstrap $SUITE / arm64 → $ROOT"
    rm -rf "$ROOT"; mkdir -p "$ROOT"
    # tee 双写：既实时进 CI 日志，也留一份文件。
    # 必须写成 `if ! ... | tee` 而不是靠 set -e：后者会在管道失败的瞬间直接退出，
    # 下面那句"debootstrap 失败"永远打印不出来。
    if ! debootstrap --arch arm64 --variant=minbase \
      --include=busybox-static,udev,ssh,sudo,systemd,iproute2,dnsmasq,parted,e2fsprogs \
      "$SUITE" "$ROOT" "$MIRROR" \
      2>&1 | tee /tmp/odin-debootstrap.log; then
      echo "debootstrap 失败，日志见上面（同一份也留在 /tmp/odin-debootstrap.log）" >&2
      exit 1
    fi
    # 打一份基础根留给后续轮次。打包失败不致命，只是本轮没留下缓存。
    if [ -n "$BASE_TAR" ]; then
      say "打包基础根 → $BASE_TAR（供后续 CI 轮次复用）"
      if tar -czf "$BASE_TAR" -C "$ROOT" --exclude=./proc --exclude=./sys . 2>/dev/null; then
        say "  基础根打包完成 $(stat -c %s "$BASE_TAR" 2>/dev/null || stat -f %z "$BASE_TAR") 字节"
      else
        say "  基础根打包失败（不致命，本轮只是没留下缓存）"
      fi
    fi
  fi
fi
say "rootfs 就绪: $ROOT"
if [ "$STAGE_CACHE_HIT" = true ]; then
  say "从 staging 层缓存恢复，跳过内核安装、initramfs 生成和全部 apt 安装"
fi

# 镜像站对已存在的 staging 同样要生效：上一行可能被跳过（debootstrap 过一次就不再
# 重来），但后续 chroot 里的 apt 仍应走镜像站。导出前会还原，见第 6 节。
if [ "$MIRROR" != "http://deb.debian.org/debian" ] && [ -f "$ROOT/etc/apt/sources.list" ]; then
	sed -i "s|http://deb.debian.org/debian|$MIRROR|g" "$ROOT/etc/apt/sources.list"
	say "sources.list 指向镜像站: $MIRROR"
fi

# staging 层缓存覆盖到 setup-rootfs 完成之后；命中时只重跑下面的增量修复、
# 导出卫生和镜像生成，避免再次启动 qemu-arm64 下的 dpkg/postinst。
if [ "$STAGE_CACHE_HIT" != true ]; then
# ---------------------------------------------------------------- 2. 内核模块 + vmlinuz
say "安装内核模块与 vmlinuz"
mkdir -p "$ROOT/boot"
install -m 0644 "$KOUT/vmlinuz" "$ROOT/boot/vmlinuz"
TMPMOD=$(mktemp -d)
tar -xf "$KOUT/modules.tar" -C "$TMPMOD"
mkdir -p "$ROOT/usr/lib/modules"
test -d "$TMPMOD/usr/lib/modules"
cp -a "$TMPMOD"/usr/lib/modules/. "$ROOT/usr/lib/modules/"
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

# 骨架目录必须在这里重建，不能指望仓库里那份：
#   · git 不跟踪空目录，dev/ proc/ sys/ mnt/ 这些本来就不在版本库里
#   · bin/ 里有 busybox（1.8MB 二进制）和一批指向它的符号链接，prepare-public-repo.sh
#     会把 busybox 当大 blob 摘掉、把符号链接按 file(1) 的判定也当二进制摘掉，
#     于是公开仓库（CI 拉的就是它）里整个 bin/ 都不存在
mkdir -p "$ISTAGE"/{bin,dev,etc,lib,mnt,proc,run,sbin,sys/kernel,tmp,usr/bin,usr/sbin}

BB=$ROOT/bin/busybox
[ -x "$BB" ] || { echo "rootfs 里没有 /bin/busybox" >&2; exit 1; }
install -m 0755 "$BB" "$ISTAGE/bin/busybox"

# applet 名单同理不能靠 ls bin/ 得到（见上），走一份文本文件
while read -r applet; do
  [ -n "$applet" ] || continue
  [ -e "$ISTAGE/bin/$applet" ] && rm -f "$ISTAGE/bin/$applet"
  ln -sf busybox "$ISTAGE/bin/$applet"
done < "$REPO/dist/build/initramfs-applets.txt"
# 仓库里那份 sbin/switch_root 是指向同目录 busybox 的相对链接，而 busybox 只在
# bin/ 下 —— 断链。显式重建成指向 /bin/busybox 的绝对链接。
rm -f "$ISTAGE/sbin/switch_root"
ln -sf /bin/busybox "$ISTAGE/sbin/switch_root"
mkdir -p "$ROOT/boot"
# 一律走显式解释器：pack_initramfs.sh 在 git 里是 100644（没有可执行位），
# 直接调用会 Permission denied / exit 126
bash "$REPO/tools/pack_initramfs.sh" "$ISTAGE" "$ROOT/boot/initramfs.cpio.gz"
rm -rf "$ISTAGE"
say "  initramfs: $(stat -c%s "$ROOT/boot/initramfs.cpio.gz" 2>/dev/null || stat -f%z "$ROOT/boot/initramfs.cpio.gz") 字节"

# ---------------------------------------------------------------- 4. 系统配置
say "setup-rootfs.sh（用户 / 网络 / 服务）"
ODIN_ROOTFS="$ROOT" ODIN_VARIANT="$VARIANT" bash "$REPO/dist/build/setup-rootfs.sh"

else
  say "staging 层缓存已包含包和基础配置"
fi

say "apply-staging-fixes.sh（增量修复 + overlay + DTB + extlinux）"
# 用 CI 刚编出来的 DTB，而不是仓库里（可能过期的）那份
if [ -d "$DOUT" ]; then
  mkdir -p "$ROOT/boot/dtbs/qcom"
  cp -f "$DOUT"/*.dtb "$ROOT/boot/dtbs/qcom/"
fi
bash "$REPO/dist/build/apply-staging-fixes.sh" "$ROOT"

# ---------------------------------------------------------------- 6. 导出前卫生
# 构建期为了方便在 chroot 里装包，动过两处与运行环境有关的东西，导出前必须还原，
# 否则本地编出来的镜像会带着构建机的痕迹，和 CI 编出来的不是一回事
# （发布制品以 CI 为准，两者不该有差异）。
#
#   · /etc/resolv.conf：setup-rootfs.sh 换成了构建环境的那份（chroot 里的
#     systemd-resolved 没在跑，stub 符号链接指向的文件不存在，不换就没法解析域名）。
#     设备上 DNS 由 systemd-resolved 提供，所以恢复成它留下的那个 stub 符号链接。
#   · sources.list：用了国内镜像站的换回官方源。
if [ -e "$ROOT/usr/lib/systemd/systemd-resolved" ] || [ -e "$ROOT/lib/systemd/systemd-resolved" ]; then
	ln -sfn ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
	say "导出卫生: resolv.conf 恢复为 systemd-resolved 的 stub 符号链接"
else
	rm -f "$ROOT/etc/resolv.conf"
	say "导出卫生: 删掉构建环境的 resolv.conf（镜像里没有 resolved）"
fi
if [ "$MIRROR" != "http://deb.debian.org/debian" ]; then
	sed -i "s|$MIRROR|http://deb.debian.org/debian|g" "$ROOT/etc/apt/sources.list"
	say "导出卫生: sources.list 还原为官方源（构建期用的是 $MIRROR）"
fi

# ---------------------------------------------------------------- 7. 导出镜像
say "build-image.sh（保守特性集 + 导出 + 回读校验）"
# 初始大小按 staging 实际内容估算。
#
# 系数照抄 postmarketOS 的 pmb/install/_install.py:41-59（get_subpartitions_size）：
#     root = folder_size_MiB * 1.20 + 50 + extra_space
# 它源码里那句注释很实在，一并抄下来当依据：
#     "Estimate root partition size, then add some free space. The size
#      calculation is not as trivial as one may think, and depending on the
#      file system etc it seems to be just impossible to get it right."
# 也就是 pmOS 自己承认估不准，所以给 20% + 50 MiB 余量了事。
#
# 我们比它多一步保险：这只是给 mke2fs 的**起始值**，真正定尺寸在 build-image.sh
# 里做 —— 灌入后 resize2fs -M 收缩到精确最小值，再加冗余并截断文件。所以这里
# 估大一点最多让 mke2fs 期间的 journal/inode 表稍大，不会带进最终产物。
# 但也不能像从前那样写死 491520 块：journal 与 inode 表都按初始尺寸分配，
# 起始值给大了，后面紧缩也收不回来（实测收完仍要 1.36 GiB）。
#
# 上限不再是 GitHub 的 2 GiB —— 超过 2 GiB 的资产由 publish 阶段切成片段上传，
# 构建期按真实内容给尺寸即可（mke2fs 给小了会直接 "Could not allocate block"，
# GUI 变体实测就是这个报错）。但仍留 8 GiB 硬上限兜住失控的情况，
# 与 tools/build-image.sh 的 HARD_LIMIT 保持一致。
HARD_MAX=$(( 8589934592 / 4096 ))   # 2097152 块
stage_mb=$(du -sm "$ROOT" 2>/dev/null | cut -f1)
[ -n "$stage_mb" ] || stage_mb=900
# pmOS 公式，向上取整；再兜一个下限，避免 staging 异常小时 mke2fs 都建不起来
size_mb=$(( stage_mb * 12 / 10 + 50 ))
[ "$size_mb" -lt 512 ] && size_mb=512
blocks=$(( size_mb * 1024 * 1024 / 4096 ))
if [ "$blocks" -gt "$HARD_MAX" ]; then
  echo "  [rootfs] WARN: 按内容算出的初始大小 ${size_mb} MiB 超过硬上限，压到 ${HARD_MAX} 块" >&2
  blocks=$HARD_MAX
fi
# 镜像名：core 沿用历史名 odin-debian.img —— flash-all.sh 的默认路径、
# dist/FLASH.md 与几处文档都按这个名字取，改名要连带改一堆地方却没有任何收益。
# 其余变体加后缀（sparse 名由 build-image.sh 按 ${OUT%.img}-sparse.img 自动派生）。
case "$VARIANT" in
	core) IMG=odin-debian.img ;;
	*)    IMG=odin-debian-$VARIANT.img ;;
esac

say "初始大小按内容算（pmOS 公式 ×1.2 + 50MiB）：staging ${stage_mb} MiB → ${size_mb} MiB = ${blocks} 块"
bash "$REPO/tools/build-image.sh" "$ROOT" "$OUT/$IMG" "$blocks" pmOS_root

say "产物："
ls -la "$OUT"
