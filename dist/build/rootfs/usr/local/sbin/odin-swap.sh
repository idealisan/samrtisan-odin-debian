#!/bin/bash
# odin-swap.sh —— 建交换空间：基于文件的 swap 为主，zram 打底
#
#   用法： odin-swap.sh start | stop
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么**基于文件的 swap 是主力**
#
#   本机可用内存只有 3.46 GiB（4 GiB 物理，被 bootloader 和 modem/ADSP 等保留
#   区吃掉一截，见 reports/035）。zram 也是从这块内存里划的，压缩比再好也只是
#   "把 3.46 GiB 变出 4 GiB 的体感"，**内存峰值来了照样顶不住**。
#   要的是"峰值时系统还能跑"，那就得有真正落在 eMMC 上的 swap。
#   这台机器是旧手机，闪存磨损不是首要顾虑；换来的是不 OOM。
#
#   所以：
#     swapfile  4 GiB，优先级 10   ← 主力，撑峰值
#     zram    512 MiB，优先级 100  ← 打底，接住"温"页，少写 eMMC、响应更快
#   内核会先用优先级高的 zram，撑不住再落到 swapfile。想只要 swapfile，
#   把 ODIN_ZRAM_SIZE 设成 0 即可。
#
# ─────────────────────────────────────────────────────────────────────────
# 这段反复折腾的历史（别再走回头路）
#
#   1. 最早想建 5 GiB swapfile，但根分区的 ext4 为了迁就 lk2nd 关了 extents
#      （lk2nd 要读 /extlinux/extlinux.conf，它的 ext2 驱动不认识 extents），
#      而 swapfile 走 iomap **需要 extents** ⇒ swapon: Invalid argument，
#      且内核不打任何日志。2026-09-05 给 lk2nd 打了补丁 0005（只读 extents
#      支持），根分区这才开得起 extents（reports/036）。
#
#   2. 中间一度整个换成 zram —— 那是因为问题 1 没解，不是因为 zram 更合适。
#
#   3. 更早还有一次：服务跑在 resize2fs **之前**，dd 写 231 MB 就 ENOSPC，
#      留下一个半截的 swapfile；之后每次开机都因"文件存在"而跳过重建，
#      swap 永远起不来，服务却 exit 0 假装成功。所以下面按**大小**判定，
#      不够就删掉重建，且这一步必须排在扩容之后。
#
#   4. 还有一次：unit 被 systemd 静默丢弃 —— `Before=sysinit.target` 却
#      `After` 了一个属于 multi-user.target 的单元，成环。现在挂在
#      multi-user.target 上，不再 Before sysinit.target（见 service 文件）。
#
# 失败一律不致命 —— 最坏只是没有 swap，绝不能把启动搞挂。
set -u

SWAPFILE=${ODIN_SWAP_FILE:-/swapfile}
SIZE=${ODIN_SWAP_SIZE:-4G}
# 4 GiB；改成别的值时 WANT_BYTES 会自动跟着算，不用手动同步
WANT_BYTES=$((4 * 1024 * 1024 * 1024))
case "$SIZE" in
	*G) WANT_BYTES=$(( ${SIZE%G} * 1024 * 1024 * 1024 )) ;;
	*M) WANT_BYTES=$(( ${SIZE%M} * 1024 * 1024 )) ;;
	*K) WANT_BYTES=$(( ${SIZE%K} * 1024 )) ;;
esac

ZRAM_SIZE=${ODIN_ZRAM_SIZE:-512M}
ZRAM_DEV=${ODIN_ZRAM_DEVICE:-/dev/zram0}
LOG=/var/log/odin-swap.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; echo "[odin-swap] $*" >&2; }

zram_sysfs() { printf '/sys/block/%s' "$(basename "$ZRAM_DEV")"; }

# ------------------------------------------------------------------ zram
do_zram_start() {
	[ "$ZRAM_SIZE" = "0" ] && { say "zram 已按配置关闭（ODIN_ZRAM_SIZE=0）"; return 0; }

	if swapon --show 2>/dev/null | grep -q "^$ZRAM_DEV"; then
		say "zram $ZRAM_DEV 已在用，跳过"
		return 0
	fi

	modprobe zram 2>/dev/null || say "  modprobe zram 失败，继续"
	local s; s=$(zram_sysfs)
	local i=0
	while [ ! -e "$s" ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
	[ -e "$s" ] || { say "  等不到 $s，跳过 zram"; return 0; }

	echo "$ZRAM_SIZE" > "$s/disksize" 2>/dev/null || { echo 1 > "$s/reset" 2>/dev/null; echo "$ZRAM_SIZE" > "$s/disksize" 2>/dev/null; }
	mkswap "$ZRAM_DEV" >/dev/null 2>&1 || { say "  zram mkswap 失败，跳过"; return 0; }
	# 优先级高：让内核先把"温"页放进来，别一上来就写 eMMC
	if swapon -p 100 "$ZRAM_DEV" 2>/dev/null; then
		say "zram ${ZRAM_SIZE} 已启用（优先级 100）"
	else
		say "  zram swapon 失败，跳过"
	fi
}

do_zram_stop() {
	swapon --show 2>/dev/null | grep -q "^$ZRAM_DEV" && swapoff "$ZRAM_DEV" 2>/dev/null
	local s; s=$(zram_sysfs)
	[ -w "$s/reset" ] && echo 1 > "$s/reset" 2>/dev/null
}

# --------------------------------------------------------------- swapfile
do_file_start() {
	if swapon --show 2>/dev/null | grep -q "^$SWAPFILE"; then
		say "$SWAPFILE 已在用，跳过"
		return 0
	fi

	# ⚠️ 不能只看"文件存在"：曾经留下过 dd 写一半的半截文件，于是每次开机
	#    都跳过创建直接 swapon，swap 永远起不来。按**大小**判定。
	if [ -f "$SWAPFILE" ]; then
		have=$(stat -c%s "$SWAPFILE" 2>/dev/null || echo 0)
		if [ "$have" -ge "$WANT_BYTES" ]; then
			say "$SWAPFILE 已存在且大小足够（$have 字节），跳过创建"
		else
			say "$SWAPFILE 不完整（$have < $WANT_BYTES 字节），删掉重建"
			rm -f "$SWAPFILE"
		fi
	fi

	if [ ! -f "$SWAPFILE" ]; then
		say "创建 $SWAPFILE（$SIZE）"
		# 开了 extents 之后 fallocate 就能用了：秒级预留，比 dd 写满 4 GiB 快得多。
		# 万一不可用（比如哪天又开了什么奇怪的特性），退回 dd。
		if fallocate -l "$SIZE" "$SWAPFILE" 2>/dev/null; then
			say "  fallocate 成功"
		else
			say "  fallocate 不可用，改用 dd（会慢一些）"
			dd if=/dev/zero of="$SWAPFILE" bs=1M \
			   count=$((WANT_BYTES / 1048576)) status=none \
				|| { say "  dd 失败，放弃 swapfile"; rm -f "$SWAPFILE"; return 0; }
		fi
		chmod 600 "$SWAPFILE" 2>/dev/null
		mkswap "$SWAPFILE" >/dev/null 2>&1 || { say "  mkswap 失败，放弃"; rm -f "$SWAPFILE"; return 0; }
	fi

	# 优先级 10：低于 zram，作为zram 撑不住之后的第二级
	if swapon -p 10 "$SWAPFILE" 2>/dev/null; then
		say "swapfile $SWAPFILE 已启用（优先级 10）"
	else
		say "  swapon 失败，放弃（最坏只是没有 swapfile）"
		return 0
	fi
}

do_file_stop() {
	swapon --show 2>/dev/null | grep -q "^$SWAPFILE" && swapoff "$SWAPFILE" 2>/dev/null
}

# ------------------------------------------------------------------- main
case "${1:-start}" in
	start)
		say "=== 开始（swapfile=$SIZE 主力 / zram=$ZRAM_SIZE 打底）"
		do_zram_start
		do_file_start
		say "=== 结束，当前 swap："
		swapon --show 2>/dev/null | sed 's/^/    /' >> "$LOG" 2>/dev/null
		swapon --show 2>/dev/null | sed 's/^/  /' >&2
		;;
	stop)
		do_file_stop
		do_zram_stop
		say "已全部停止"
		;;
	*)
		echo "用法: $0 start|stop" >&2
		exit 2
		;;
esac
exit 0
