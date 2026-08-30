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
  # tee 双写：既实时进 CI 日志，也留一份文件。
  # 必须写成 `if ! ... | tee` 而不是靠 set -e：后者会在管道失败的瞬间直接退出，
  # 下面那句"debootstrap 失败"永远打印不出来。
  if ! debootstrap --arch arm64 --variant=minbase \
    --include=busybox-static,udev,ssh,sudo,systemd,iproute2,dnsmasq,parted,e2fsprogs \
    "$SUITE" "$ROOT" http://deb.debian.org/debian \
    2>&1 | tee /tmp/odin-debootstrap.log; then
    echo "debootstrap 失败，日志见上面（同一份也留在 /tmp/odin-debootstrap.log）" >&2
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
ODIN_ROOTFS="$ROOT" bash "$REPO/dist/build/setup-rootfs.sh"

say "apply-staging-fixes.sh（增量修复 + overlay + DTB + extlinux）"
# 用 CI 刚编出来的 DTB，而不是仓库里（可能过期的）那份
if [ -d "$DOUT" ]; then
  mkdir -p "$ROOT/boot/dtbs/qcom"
  cp -f "$DOUT"/*.dtb "$ROOT/boot/dtbs/qcom/"
fi
bash "$REPO/dist/build/apply-staging-fixes.sh" "$ROOT"

# ---------------------------------------------------------------- 5. 导出镜像
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
# 上限仍是 GitHub Release 的单个资产限制 2147483648 字节，且要求"严格小于"。
# build-image.sh 末尾还会再校验一次，超了直接 fail。
GH_MAX=$(( 2147483648 / 4096 ))   # 524287 块
stage_mb=$(du -sm "$ROOT" 2>/dev/null | cut -f1)
[ -n "$stage_mb" ] || stage_mb=900
# pmOS 公式，向上取整；再兜一个下限，避免 staging 异常小时 mke2fs 都建不起来
size_mb=$(( stage_mb * 12 / 10 + 50 ))
[ "$size_mb" -lt 512 ] && size_mb=512
blocks=$(( size_mb * 1024 * 1024 / 4096 ))
if [ "$blocks" -gt "$GH_MAX" ]; then
  echo "  [rootfs] WARN: 按内容算出的初始大小 ${size_mb} MiB 超过 GitHub 上限，压到 ${GH_MAX} 块" >&2
  blocks=$GH_MAX
fi
say "初始大小按内容算（pmOS 公式 ×1.2 + 50MiB）：staging ${stage_mb} MiB → ${size_mb} MiB = ${blocks} 块"
bash "$REPO/tools/build-image.sh" "$ROOT" "$OUT/odin-debian.img" "$blocks" pmOS_root

say "产物："
ls -la "$OUT"
