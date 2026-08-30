#!/bin/sh
# odin-modem-fw.sh —— 在 switch_root 之前，把蜂窝基带（MSS）的固件放进真正的根
#
# 用法:
#   odin-modem-fw.sh <真实根的挂载点>            # 取出缺失的文件
#   odin-modem-fw.sh <真实根的挂载点> --check    # 只检查是否齐全，不动盘
#
# 为什么必须在 initramfs 里做（与 WiFi 那份同理，见 reports/021）：
#   内核的 qcom_q6v5_mss（&mpss）在开机早期就索取 mba.mbn / modem.mdt，
#   那时 systemd 还没起来，任何 late service 都太晚；而 request_firmware 失败后
#   remoteproc 会停在 offline 且不会自己重试，补上文件也没用。
#
# 固件来源：**modem 分区**（/dev/disk/by-partlabel/modem）的 /image/ 目录。
#   这是我们从没动过的原厂分区，只要没被清掉数据就在。
#   与 WiFi 那份同理由：二进制，不该进版本库。
#
# 落点必须与设备树里 &mpss 的 firmware-name 一致：
#   firmware-name = "qcom/msm8953/smartisan/u2pro/mba.mbn",
#                   "qcom/msm8953/smartisan/u2pro/modem.mdt";
#
# ⚠ 段号不连续：原厂是 b00 b01 b02 b04 b05 b06 b07 b08 b09 b10 b11 b12 b13
#   b16 b17 b18 b19 b20 —— **没有 b03 / b14 / b15**。所以这里按模式取
#   "modem.b*"，不要写成 b00..b20 的范围，否则 cp 会报找不到文件。
#
# 失败一律不致命 —— 最坏结果只是没有蜂窝网络，绝不能因为取不到把启动搞挂。
set -u

FIRM_DIR=qcom/msm8953/smartisan/u2pro
LOG=/var/log/odin-modem-fw.log
LOGFILE=

log() {
	echo "[odin-modem-fw] $*" >&2
	[ -n "$LOGFILE" ] && echo "$(date '+%F %T') $*" >> "$LOGFILE" 2>/dev/null
	return 0
}

# 按 GPT 分区名找设备节点：initramfs 里没有 udev，
# 但 sysfs 每个块设备的 uevent 里有 DEVNAME 与 PARTNAME。
part_dev() {
	name=$1
	for d in /sys/class/block/*; do
		[ -f "$d/uevent" ] || continue
		if grep -q "^PARTNAME=$name$" "$d/uevent" 2>/dev/null; then
			sed -n 's/^DEVNAME=//p' "$d/uevent" 2>/dev/null | head -1 | sed 's|^|/dev/|'
			return 0
		fi
	done
	return 1
}

# ---------- 入口 ----------
ROOT=${1:-}
[ -n "$ROOT" ] || { log "用法: odin-modem-fw.sh <真实根挂载点> [--check]"; exit 1; }
[ -d "$ROOT" ] || { log "真实根挂载点不存在: $ROOT"; exit 1; }
# 只在真实根确实有 /var/log 时才落日志（重定向报错来自 shell 本身，
# 命令上的 2>/dev/null 管不到）
if [ -d "$ROOT/var/log" ]; then LOGFILE="$ROOT/$LOG"; fi

DEST="$ROOT/lib/firmware/$FIRM_DIR"

for a in "$@"; do
	if [ "$a" = "--check" ]; then
		if [ -s "$DEST/mba.mbn" ] && [ -s "$DEST/modem.mdt" ] && \
		   [ -s "$DEST/modem.b10" ]; then
			exit 0
		else
			exit 1
		fi
	fi
done

dev=$(part_dev modem) || { log "modem 分区未找到，跳过"; exit 0; }
mnt=$(mktemp -d) || { log "无法建挂载点"; exit 0; }
if ! mount -o ro "$dev" "$mnt" 2>/dev/null; then
	log "modem($dev) 挂载失败，跳过"
	rmdir "$mnt" 2>/dev/null
	exit 0
fi

src="$mnt/image"
if [ ! -d "$src" ]; then
	log "$dev 里没有 /image/ 目录，跳过"
	umount "$mnt" 2>/dev/null
	rmdir "$mnt" 2>/dev/null
	exit 0
fi

mkdir -p "$DEST" 2>/dev/null
copied=0

# mba.mbn 与 modem.mdt 是入口文件；modem.b* 按模式取，不假设段号连续
for f in mba.mbn modem.mdt; do
	[ -s "$src/$f" ] || continue
	if ! cmp -s "$src/$f" "$DEST/$f"; then
		if cp -f "$src/$f" "$DEST/$f" 2>/dev/null; then
			log "已取 $f ($(stat -c%s "$src/$f" 2>/dev/null || stat -f%z "$src/$f") 字节)"
			copied=$((copied + 1))
		fi
	fi
done

for p in "$src"/modem.b*; do
	[ -f "$p" ] || continue
	f=$(basename "$p")
	if ! cmp -s "$p" "$DEST/$f"; then
		if cp -f "$p" "$DEST/$f" 2>/dev/null; then
			copied=$((copied + 1))
		fi
	fi
done

sync
umount "$mnt" 2>/dev/null
rmdir "$mnt" 2>/dev/null
log "完成，本次拷了 $copied 个文件 → /lib/firmware/$FIRM_DIR"

exit 0
