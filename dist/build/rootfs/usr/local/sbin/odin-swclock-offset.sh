#!/bin/sh
# 系统时间 = RTC + 偏差（偏差存在文件里）
#
# 为什么需要它：本机的 RTC 能读、不能写。
#   rtc-pm8xxx 的 set_time 有两条路（drivers/rtc/rtc-pm8xxx.c）：
#       allow_set_time ? 真写 RTC 时间寄存器 : pm8xxx_rtc_update_offset()
#   后者把"偏差"存进设备树里名为 offset 的 nvmem cell 来模拟，而本机没提供这个
#   cell ⇒ 函数开头就 return -ENODEV ⇒ 任何写 RTC 的尝试都失败：
#       hwclock --systohc → ioctl(RTC_SET_TIME) failed: No such device
#       内核的 CONFIG_RTC_SYSTOHC 11 分钟回写 → 同样失败
#
# postmarketOS 是怎么做的（这就是本文件的来历）：
#   msm8953 的 SoC 包 device/community/soc-qcom-msm8953 的 APKBUILD 里写着
#       depends="$pkgname-ucm swclock-offset"
#   即官方也认定这一整系 SoC 的 RTC 不可写，于是用 swclock-offset 这个包：
#   关机时把「系统时间 − RTC」写进文件，开机时 RTC + 偏差还原系统时间。
#   参考实现：https://gitlab.postmarketos.org/postmarketOS/swclock-offset
#
# 与参考实现的两处不同（都是补它的短板）：
#   1. 参考实现发现 /sys/class/rtc/rtc0 不存在就**静默跳过** —— 而 rtc-pm8xxx
#      是模块（CONFIG_RTC_DRV_PM8XXX=m，与 pmOS 官方配置一致），sysinit 早期
#      它往往还没装载，于是等于白装一次。这里先 modprobe 再等最多 5 秒。
#   2. 只在关机保存，一掉电/长按电源硬复位就丢。故另配一个 10 分钟的定时器
#      重复保存（odin-swclock-offset-save.timer），把最坏误差压到 10 分钟。
#
# 用法：odin-swclock-offset.sh boot|save

set -u

RTC_NODE=/sys/class/rtc/rtc0/since_epoch
OFFSET_DIR=/var/lib/odin-swclock-offset
OFFSET_FILE="$OFFSET_DIR/offset"

log() { echo "[swclock-offset] $*"; }

is_int() {
	case "$1" in
		'' | *[!0-9-]*) return 1 ;;
	esac
	return 0
}

# rtc-pm8xxx 是模块，且可能还没被 udev 装载。自己装一次（已装载则无害），
# 再等节点出现。SPMI 总线本身是内置的（CONFIG_SPMI=y），不依赖别的模块。
wait_rtc() {
	modprobe rtc-pm8xxx 2>/dev/null || true
	i=0
	while [ ! -f "$RTC_NODE" ]; do
		i=$((i + 1))
		if [ "$i" -ge 20 ]; then
			return 1
		fi
		sleep 0.25
	done
	return 0
}

do_boot() {
	if ! wait_rtc; then
		log "rtc0 迟迟没出现，跳过（偏差文件保持原样，等 NTP 校正）"
		return 0
	fi
	if [ ! -f "$OFFSET_FILE" ]; then
		log "无偏差文件（首次开机），跳过 —— 时间靠 NTP 校正"
		return 0
	fi
	rtc=$(cat "$RTC_NODE" 2>/dev/null)
	off=$(cat "$OFFSET_FILE" 2>/dev/null)
	if ! is_int "$rtc" || ! is_int "$off"; then
		log "读到非数值（rtc=$rtc offset=$off），跳过"
		return 0
	fi
	date -u -s "@$((rtc + off))" >/dev/null 2>&1
	log "系统时间 = RTC($rtc) + 偏差($off) = $(date -u '+%F %T') UTC"
}

do_save() {
	if ! wait_rtc; then
		log "rtc0 不存在，跳过保存"
		return 0
	fi
	rtc=$(cat "$RTC_NODE" 2>/dev/null)
	if ! is_int "$rtc"; then
		log "RTC 读到非数值，跳过保存"
		return 0
	fi
	now=$(date -u +%s)
	mkdir -p "$OFFSET_DIR"
	printf '%s\n' "$((now - rtc))" > "$OFFSET_FILE"
	sync
	log "已保存偏差 $((now - rtc))（= 现在 $now − RTC $rtc）"
}

case "${1:-}" in
	boot) do_boot ;;
	save) do_save ;;
	*)
		echo "用法: $0 boot|save" >&2
		exit 64
		;;
esac
