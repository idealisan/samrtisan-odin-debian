#!/bin/bash
# ODIN — USB 外置存储自动挂载（由 udev 的 RUN 调用）
#
#   odin-automount.sh <devnode> [mountpoint]
#
# 为什么要有这层包装，而不是在 udev 规则里直接调 systemd-mount：
#   实测（WORKLOG 12:26）systemd 252 的 systemd-mount **不读** SYSTEMD_MOUNT_OPTIONS
#   环境变量，必须用 --options= 显式传；而选项要按 fstype 分流，udev 命令行里
#   拼不出来。所以把"取 fstype → 算选项 → 调 systemd-mount"收进脚本。
#
# 只处理 USB 总线上的设备（ID_BUS=usb），内部 eMMC/SD 天然排除。
# 有分区表和"整盘一个文件系统"的 U 盘都支持。
#
# 任何分支都 exit 0：挂载失败只记日志，绝不因 udev RUN 失败留下红灯。

LOG=${ODIN_AUTOMOUNT_LOG:-/var/log/odin-automount.log}
DEV="${1:-}"
NAME="${2:-}"

log() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

[ -n "$DEV" ] || { log "no devnode, skip"; exit 0; }
[ -b "$DEV" ] || { log "$DEV not a block device, skip"; exit 0; }

[ -n "$NAME" ] || NAME=$(basename "$DEV")
WHERE="/run/media/$NAME"

# 只管 USB
#
# ⚠️ 只认 ID_BUS=usb 会把 **UAS 设备整类漏掉**（2026-09-06 实测踩到）：
#   UAS（USB Attached SCSI）盘的 SCSI 层把总线报成 **ID_BUS=ata**，
#   USB 那套属性全在 ID_USB_* 上（这台是 ID_USB_DRIVER=uas）。
#   所以判定要改成"ID_BUS=usb **或** 有 ID_USB_DRIVER"。
#   内部 eMMC / SD 没有 ID_USB_DRIVER，天然排除，不会误挂。
PROPS=$(udevadm info -q property -n "$DEV" 2>/dev/null)
BUS=$(printf '%s\n' "$PROPS" | sed -n 's/^ID_BUS=//p')
USBDRV=$(printf '%s\n' "$PROPS" | sed -n 's/^ID_USB_DRIVER=//p')
if [ "$BUS" != usb ] && [ -z "$USBDRV" ]; then
	log "$DEV ID_BUS='$BUS' ID_USB_DRIVER='$USBDRV' —— 不是 USB 设备，skip"
	exit 0
fi

FSTYPE=$(printf '%s\n' "$PROPS" | sed -n 's/^ID_FS_TYPE=//p')
[ -n "$FSTYPE" ] || { log "$DEV no ID_FS_TYPE, skip"; exit 0; }

OPTS=$(/usr/local/sbin/odin-mount-opts.sh "$FSTYPE")
[ -n "$OPTS" ] || OPTS=noatime

# blkid / udev 对 NTFS 盘报的类型是 **ntfs**，不是 ntfs3。
# 而我们镜像里既没有老的内核 ntfs 驱动，也没装 ntfs-3g（无 mount.ntfs helper），
# 所以让 systemd 自己探测会去找 `ntfs` ⇒ 直接
#     mount: unknown filesystem type 'ntfs'
# 实测（2026-09-06 虚拟盘）：
#     -t ntfs3        → type ntfs3 (rw,...)，中文名读写正常
#     不指定类型       → 有 ntfs-3g 时走 fuseblk；没装时 unknown filesystem type 'ntfs'
#     没装 ntfs-3g + 显式 -t ntfs3 → 仍可用 ✅
# 内核 ntfs3 是内建的（CONFIG_NTFS3_FS=y），比 FUSE 的 ntfs-3g 更好，归一到它。
MNT_TYPE=$FSTYPE
[ "$FSTYPE" = ntfs ] && MNT_TYPE=ntfs3

# 已挂载则幂等返回
if mountpoint -q "$WHERE" 2>/dev/null; then
	log "$DEV already mounted at $WHERE, skip"
	exit 0
fi

log "mount $DEV ($FSTYPE → -t $MNT_TYPE) -> $WHERE [$OPTS]"
if ! /usr/bin/systemd-mount --no-block --collect --type="$MNT_TYPE" \
		--options="$OPTS" "$DEV" "$WHERE" >> "$LOG" 2>&1; then
	log "systemd-mount FAILED for $DEV ($FSTYPE)"
fi
exit 0
