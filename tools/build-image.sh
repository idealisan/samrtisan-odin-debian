#!/bin/bash
# ODIN Debian 根镜像导出管线（可复现，容器内执行）。
#
#   build-image.sh <staging-dir> <out-img> <blocks> [label]
#
# 例：
#   tools/build-image.sh /mnt/stage /mnt/img/odin-debian.img 524288 pmOS_root
#
# 每一条约束都对应 reports/013 解包复核的一个实测教训：
#   1. staging 必须是"未挂载的普通目录"——挂载态复制会让超级块 free 计数与位图不一致
#   2. 特性集保守：lk2nd 的 ext2 驱动只接受 ro_compat ⊆ {sparse_super, large_file}
#      （lib/fs/ext2/ext2.c:162-166，它完全不检查 compat/incompat）
#   3. 必须保留 resize_inode + reserved GDT：否则在线扩容在第 128 组（16GiB）处
#      命中 fs/ext4/resize.c 的 "No reserved GDT blocks, can't resize" 而 EPERM
#   4. 导出后 e2fsck 至干净、img2simg、check_sparse、逐项回读校验，任一失败即非零退出
set -e

STAGE=${1:?usage: build-image.sh <staging-dir> <out-img> <blocks> [label]}
OUT=${2:?}
BLOCKS=${3:?}
LABEL=${4:-pmOS_root}

REPO=$(cd "$(dirname "$0")/.." && pwd)
SPARSE="${OUT%.img}-sparse.img"

say()  { echo "[build] $*"; }
fail() { echo "[build] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 前置检查
[ -d "$STAGE" ] || fail "staging not found: $STAGE"
for f in boot/vmlinuz boot/initramfs.cpio.gz extlinux/extlinux.conf .odin-debian \
         usr/lib/systemd/systemd etc/fstab; do
  [ -e "$STAGE/$f" ] || fail "missing in staging: /$f"
done
DTB=$(ls "$STAGE"/boot/dtbs/qcom/*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] || fail "no dtb under /boot/dtbs/qcom"

# 内核版本不能写死：scripts/setlocalversion 在"工作树不干净"时会追加一个 +，
# 而 CI 里补丁是打在工作树上的（git 里永远是脏的），实际目录名是
# 6.19.0-postmarketos-qcom-msm8953+ —— 少那个 + 就找不到模块。
KVER=$(ls "$STAGE/usr/lib/modules" 2>/dev/null | head -1)
[ -n "$KVER" ] || fail "no kernel modules under /usr/lib/modules"
say "staging OK: $STAGE ($(du -sh "$STAGE" | cut -f1)), kernel $KVER"

# ------------------------------------------------- 1. 模块树统一为标准 kernel/ 布局
# 现状：msm8953 模块是手工拷贝进来的，缺 kernel/ 层级，而 modules.builtin 用
# kernel/ 前缀 —— 两套前缀并存会让后续 apt 重装内核头/模块时路径错位。
normalize_modules() {
  local base="$1" root="$2" ver d e
  [ -d "$base" ] || return 0
  for d in "$base"/*; do
    [ -d "$d" ] || continue
    ver=$(basename "$d")
    [ "$ver" = "build" ] || [ "$ver" = "source" ] && continue
    if [ -d "$d/kernel" ]; then
      say "modules $ver: already standard layout"
      continue
    fi
    say "modules $ver: moving into kernel/ ..."
    mkdir -p "$d/kernel"
    for e in "$d"/*; do
      case "$(basename "$e")" in
        kernel | modules.* | build | source) continue ;;
      esac
      mv "$e" "$d/kernel/"
    done
    # depmod 的 basedir 必须是 rootfs 根（merged-usr 下 /lib -> usr/lib）
    depmod -b "$root" "$ver"
    say "modules $ver: depmod regenerated"
  done
}
normalize_modules "$STAGE/usr/lib/modules" "$STAGE"

# ---------------------------------------------------------------- 2. 干净化清单
# machine-id 非空 ⇒ 每台刷出来的设备 ID 相同（并会让 journal 目录沿用旧 ID）。
# 注意：只清空 /etc/machine-id 没用——实测 systemd 会从 /var/lib/dbus/machine-id
# 回填旧值（/etc/machine-id 为空时的 dbus 兼容路径），两个都必须清。
: > "$STAGE/etc/machine-id"
[ -f "$STAGE/var/lib/dbus/machine-id" ] && : > "$STAGE/var/lib/dbus/machine-id"
# SSH 主机私钥同理：镜像要公开发布，带一把固定私钥等于所有设备共用同一身份。
# 由 odin-ssh-hostkeys.service 在首启用 ssh-keygen -A 生成（apply-staging-fixes.sh 装的）。
rm -f "$STAGE"/etc/ssh/ssh_host_*_key "$STAGE"/etc/ssh/ssh_host_*_key.pub
rm -f  "$STAGE/var/lib/systemd/random-seed"
rm -rf "$STAGE"/var/log/journal/*
rm -f  "$STAGE/var/log/wtmp" "$STAGE/var/log/btmp" "$STAGE/var/log/lastlog"
rm -f  "$STAGE/root/.bash_history"
rm -rf "$STAGE"/tmp/* "$STAGE"/var/tmp/* 2>/dev/null || true
rm -rf "$STAGE/mnt/dist"
say "cleanup done (machine-id/random-seed/journal/wtmp/lastlog)"

# ---------------------------------------------------------------- 3. 建文件系统
# 保守特性集 + 显式保留 resize_inode（=> mke2fs 会分配 reserved GDT blocks）
rm -f "$OUT"
mke2fs -q -F -t ext4 -L "$LABEL" \
  -O resize_inode,^extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize \
  -I 256 -b 4096 -d "$STAGE" "$OUT" "$BLOCKS"
say "mke2fs done ($BLOCKS blocks)"

# 灌入后立即修一次：mke2fs -d 不会同步 free 计数到最终状态
e2fsck -f -y "$OUT" > /dev/null 2>&1 || true
say "e2fsck pass done"

# ---------------------------------------------------------------- 4. 导出 sparse
rm -f "$SPARSE"
img2simg "$OUT" "$SPARSE"
say "img2simg done: $(du -h "$SPARSE" | cut -f1)"

# ---------------------------------------------------------------- 5. 回读校验
rc=0
note() { printf '  %-34s %s\n' "$1" "$2"; }

echo "[build] === verify ==="

FEAT=$(dumpe2fs -h "$OUT" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
LBL=$(dumpe2fs -h "$OUT" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')
# e2fsprogs 1.47 的 dumpe2fs -h 不再打印 Reserved GDT blocks，直接读超级块 0xCE
RDT=$(od -A n -j 1230 -N 2 -t u2 "$OUT" | tr -d ' ')
RO=$(od -A n -j 1124 -N 4 -t u4 "$OUT" | tr -d ' ')
note "features" "$FEAT"
note "reserved GDT blocks" "${RDT:-0}"
note "label" "$LBL"

case "$FEAT" in *resize_inode*) note "resize_inode" "OK" ;;
  *) note "resize_inode" "MISSING"; rc=1 ;; esac
[ "${RDT:-0}" -gt 0 ] && note "reserved GDT > 0" "OK" || { note "reserved GDT > 0" "ZERO"; rc=1; }
for bad in extent 64bit metadata_csum huge_file dir_nlink extra_isize; do
  case "$FEAT" in *$bad*) note "forbidden feature: $bad" "PRESENT"; rc=1 ;; esac
done
# lk2nd ext2 驱动的挂载门槛：ro_compat 只允许 sparse_super|large_file
MRO=$(( RO & ~3 ))
note "ro_compat" "0x$(printf '%x' "$RO") (masked 0x$(printf '%x' "$MRO"))"
[ "$MRO" -eq 0 ] && note "lk2nd mountable" "OK" || { note "lk2nd mountable" "WILL REFUSE"; rc=1; }
[ "$LBL" = "$LABEL" ] || { note "label" "expected $LABEL"; rc=1; }

# e2fsck -fn 干净时退出码为 0（1.47 的输出里没有 "clean" 字样，只能看退出码）
if e2fsck -fn "$OUT" > /tmp/_fsck.out 2>&1; then
  note "e2fsck -fn" "clean ($(grep -c . /tmp/_fsck.out) lines)"
else
  note "e2fsck -fn" "DIRTY (rc=$?)"; grep -vE "^Pass|^$" /tmp/_fsck.out | head -8; rc=1
fi

# debugfs 对不存在的路径也返回 0，必须看输出里有没有 Inode 行
exists() { debugfs -R "stat $1" "$OUT" 2>&1 | grep -q "^Inode: [0-9]"; }

python3 "$REPO/tools/check_sparse.py" "$SPARSE" "$OUT" > /tmp/_sparse.out 2>&1 \
  && note "check_sparse" "$(cat /tmp/_sparse.out)" \
  || { note "check_sparse" "FAILED: $(cat /tmp/_sparse.out)"; rc=1; }

# initramfs / vmlinuz 与仓库 stage 副本一致性
if [ -f "$REPO/dist/stage/initramfs.cpio.gz" ]; then
  A=$(debugfs -R "cat /boot/initramfs.cpio.gz" "$OUT" 2>/dev/null | md5sum | cut -d' ' -f1)
  B=$(md5sum "$REPO/dist/stage/initramfs.cpio.gz" | cut -d' ' -f1)
  [ "$A" = "$B" ] && note "initramfs md5" "$A" || { note "initramfs md5" "image=$A repo=$B"; rc=1; }
fi
for p in /extlinux/extlinux.conf /boot/vmlinuz /boot/dtbs/qcom/$(basename "$DTB") /.odin-debian \
         /usr/local/sbin/odin-firstboot-resize.sh /etc/NetworkManager/conf.d/99-odin-usb0.conf \
         /usr/lib/modules/$KVER/kernel/drivers/gpu/drm/panel/panel-r69006.ko; do
  exists "$p" && note "present $p" "OK" || { note "present $p" "MISSING"; rc=1; }
done
# 发布态不得带这些残留
for p in /var/lib/odin-resize-done /var/lib/systemd/random-seed /mnt/dist \
         /boot/msm8953-smartisan-odin.dtb /usr/lib/modules/$KVER/drivers; do
  exists "$p" && { note "residual $p" "PRESENT (should be gone)"; rc=1; } || note "residual $p" "absent"
done
# 扩容服务必须处于启用态；machine-id 必须为空（否则所有设备同 ID）
exists /etc/systemd/system/multi-user.target.wants/odin-firstboot-resize.service \
  && note "resize service enabled" "OK" || { note "resize service enabled" "NOT ENABLED"; rc=1; }
MID=$(debugfs -R "cat /etc/machine-id" "$OUT" 2>/dev/null | tr -d '\0\r\n')
[ -z "$MID" ] && note "machine-id" "empty (regenerates on first boot)" \
  || { note "machine-id" "NOT EMPTY: $MID"; rc=1; }
DID=$(debugfs -R "cat /var/lib/dbus/machine-id" "$OUT" 2>/dev/null | tr -d '\0\r\n')
[ -z "$DID" ] && note "dbus machine-id" "empty (no stale id to restore)" \
  || { note "dbus machine-id" "NOT EMPTY: $DID"; rc=1; }

echo "[build] ========================"
[ "$rc" -eq 0 ] && echo "[build] ALL CHECKS PASSED -> $OUT" || echo "[build] CHECKS FAILED"
exit "$rc"
