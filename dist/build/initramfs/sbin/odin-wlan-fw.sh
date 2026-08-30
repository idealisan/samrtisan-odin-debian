#!/bin/sh
# odin-wlan-fw.sh —— 在 switch_root 之前，把 WiFi（WCNSS）要用的固件与校准数据
#                    放进真正的根文件系统
#
# 用法:
#   odin-wlan-fw.sh <真实根的挂载点>            # 取出缺失的文件
#   odin-wlan-fw.sh <真实根的挂载点> --check    # 只检查是否齐全，不动盘
#
# 为什么必须在 initramfs 里做（这是本脚本存在的全部理由）：
#   内核的 qcom_wcnss_pil（remoteproc）在开机约 10s 就会 request_firmware("wcnss.mdt")。
#   而 systemd 的 late service 要到 25s 之后才跑（实测：persist 分区在 25.9s 才被挂载）
#   —— 晚了 15 秒。remoteproc 那次加载失败后就停在 offline，之后再怎么补文件都不会
#   自己重试，只能靠重载模块去"补救"。
#   放到 initramfs 里、在 switch_root 之前备好，驱动的第一次请求就直接成功，
#   不需要任何补救动作。这才是正常的 Linux 固件供给时序。
#
# 要取两样东西。它们都不在任何 Debian 软件包里，也不该进版本库
# （都是二进制；NV 那份还带机器相关的射频校准信息）：
#
#   1. WCNSS 无线固件  wcnss.mdt + wcnss.b00/b01/...  ← modem 分区的 /image/
#      内核按 firmware-name 默认找 wcnss.mbn，qcom_mdt 会回退到 wcnss.mdt，
#      再按 .mdt 里的表去加载各 .bXX 段。
#
#   2. 板级射频校准数据 WCNSS_qcom_wlan_nv.bin 等      ← persist 分区根目录
#      路径由内核 drivers/net/wireless/ath/wcn36xx/wcn36xx.h 的 WLAN_NV_FILE
#      定死为 wlan/prima/WCNSS_qcom_wlan_nv.bin。
#
# modem 与 persist 都是我们从没动过的原厂分区，只要没被清掉，数据就在。
# 实测核对过：modem:/image/wcnss.* 与此前手工预置的十个文件 md5 全部一致、
# 且无多余文件，所以"开机现取"与"预置"完全等价。
#
# 失败一律不致命 —— 最坏结果只是没有 WiFi，绝不能因为取不到把启动搞挂。
set -u

FIRM_FILES="wcnss.mdt wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06 wcnss.b09 wcnss.b10 wcnss.b11 wcnss.b12"
NV_FILES="WCNSS_qcom_wlan_nv.bin WCNSS_wlan_dictionary.dat"
SCRATCH=/tmp/odin-wlan-fw
LOGFILE=

# 打到控制台（initramfs 阶段这是唯一可靠的去处），真实根可写时再顺带落一份日志
log() {
	echo "[odin-wlan-fw] $*" >&2
	[ -n "$LOGFILE" ] && echo "$(date '+%F %T') $*" >> "$LOGFILE" 2>/dev/null
	return 0
}

# 按 GPT 分区名找设备节点。
# initramfs 里没有 udev，/dev/disk/by-partlabel/ 那套符号链接不存在，
# 但 sysfs 每个块设备的 uevent 里就有 DEVNAME 与 PARTNAME，够用了 ——
# 也比依赖 udev 更早可用。
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

# 固件与校准数据是否都已就位
check() {
	root=$1
	for f in $FIRM_FILES; do
		[ -s "$root/lib/firmware/$f" ] || return 1
	done
	for f in $NV_FILES; do
		[ -s "$root/lib/firmware/wlan/prima/$f" ] || return 1
	done
	return 0
}

copy_from() { # copy_from <分区名> <分区内目录> <目标目录> <文件...>
	label=$1 subdir=$2 dest=$3
	shift 3

	dev=$(part_dev "$label") || { log "$label 分区未找到，跳过"; return 1; }
	mnt=$SCRATCH/$label
	mkdir -p "$mnt" 2>/dev/null || { log "无法建挂载点 $mnt"; return 1; }
	if ! mount -o ro "$dev" "$mnt" 2>/dev/null; then
		log "$label($dev) 挂载失败，跳过"
		rmdir "$mnt" 2>/dev/null
		return 1
	fi

	mkdir -p "$dest" 2>/dev/null
	copied=0
	for f in "$@"; do
		[ -s "$mnt/$subdir/$f" ] || continue
		# 已经一样的就别再写一遍（b06 那一段 3.2MB，没必要每次开机都重写闪存）
		cmp -s "$mnt/$subdir/$f" "$dest/$f" && continue
		if cp -f "$mnt/$subdir/$f" "$dest/$f" 2>/dev/null; then
			log "已取 $f ← $label"
			copied=$((copied + 1))
		fi
	done
	sync
	umount "$mnt" 2>/dev/null
	rmdir "$mnt" 2>/dev/null
	[ "$copied" -gt 0 ]
}

# ---------------------------------------------------------------- 入口
ROOT=${1:-}
[ -n "$ROOT" ] || { log "用法: odin-wlan-fw.sh <真实根挂载点> [--check]"; exit 1; }
[ -d "$ROOT" ] || { log "真实根挂载点不存在: $ROOT"; exit 1; }
# 只在真实根确实有 /var/log 时才落日志；否则 shell 的重定向报错会盖住正常输出
# （那类报错来自 shell 本身，命令上的 2>/dev/null 管不到）
[ -d "$ROOT/var/log" ] && LOGFILE="$ROOT/var/log/odin-wlan-fw.log"

for a in "$@"; do
	if [ "$a" = "--check" ]; then
		if check "$ROOT"; then
			exit 0
		else
			exit 1
		fi
	fi
done

copy_from modem image "$ROOT/lib/firmware" $FIRM_FILES
copy_from persist . "$ROOT/lib/firmware/wlan/prima" $NV_FILES

exit 0
