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
BUS=$(udevadm info -q property -n "$DEV" 2>/dev/null | sed -n 's/^ID_BUS=//p')
if [ "$BUS" != "usb" ]; then
	log "$DEV ID_BUS='$BUS' != usb, skip"
	exit 0
fi

FSTYPE=$(udevadm info -q property -n "$DEV" 2>/dev/null | sed -n 's/^ID_FS_TYPE=//p')
[ -n "$FSTYPE" ] || { log "$DEV no ID_FS_TYPE, skip"; exit 0; }

OPTS=$(/usr/local/sbin/odin-mount-opts.sh "$FSTYPE")
[ -n "$OPTS" ] || OPTS=noatime

# 已挂载则幂等返回
if mountpoint -q "$WHERE" 2>/dev/null; then
	log "$DEV already mounted at $WHERE, skip"
	exit 0
fi

log "mount $DEV ($FSTYPE) -> $WHERE [$OPTS]"
if ! /usr/bin/systemd-mount --no-block --collect --options="$OPTS" \
		"$DEV" "$WHERE" >> "$LOG" 2>&1; then
	log "systemd-mount FAILED for $DEV ($FSTYPE)"
fi
exit 0
