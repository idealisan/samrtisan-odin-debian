#!/bin/bash
# odin-swap.sh —— 用 zram 建压缩内存交换
#
#   用法： odin-swap.sh start | stop
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么**不是** swapfile（2026-09-05 实测，这条路在本机是死的）
#
#   根分区的 ext4 为了 lk2nd 能读 /extlinux/extlinux.conf，是用
#   `mke2fs -O ^extents` 建的（lk2nd 只有 ext2 驱动，读不了 extents）。
#   而 swapfile 走 iomap，**需要 extents**。对照实验：
#
#       loop 上挂一个带 extents 的 ext4，里面建 swapfile  → swapon 成功
#       根分区（无 extents）里建 swapfile                 → swapon: Invalid argument
#
#   而且失败时内核**不打任何日志**（既不走 iomap_swapfile_fail 的 pr_err，
#   也不走 pr_warn），只剩 util-linux 那句 "Invalid argument"，极难定位。
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么用 zram
#
#   内核 CONFIG_ZRAM=m 已在，实测 `swapon /dev/zram0` 成功。
#   zram 是**压缩的内存**交换：不写 eMMC，比 eMMC swap 快得多，也不磨损闪存 ——
#   安卓手机用的就是它。而且它不碰磁盘，所以不需要等 resize2fs，
#   顺便绕开了原来那个 systemd 依赖环（见 odin-swap.service 的注释）。
#
#   代价：zram 占的是内存（压缩后大约是逻辑容量的 1/3）。
#   默认 1 GiB 逻辑容量，塞满时实际约占 300 MiB。
#   想改：ODIN_ZRAM_SIZE=2G systemctl restart odin-swap.service
#
# 失败一律不致命 —— 最坏只是没有 swap，绝不能把启动搞挂。
set -u

SIZE=${ODIN_ZRAM_SIZE:-1G}
DEV=${ODIN_ZRAM_DEVICE:-/dev/zram0}
LOG=/var/log/odin-swap.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; echo "[odin-swap] $*" >&2; }

sysfs() {   # /dev/zram0 → /sys/block/zram0
	printf '/sys/block/%s' "$(basename "$DEV")"
}

do_stop() {
	if swapon --show 2>/dev/null | grep -q "^$DEV"; then
		say "swapoff $DEV"
		swapoff "$DEV" 2>/dev/null || say "  swapoff 失败，继续"
	else
		say "$DEV 不在用，无需 stop"
	fi
	local s; s=$(sysfs)
	[ -w "$s/reset" ] && echo 1 > "$s/reset" 2>/dev/null
	say "已停止"
}

do_start() {
	# 已经在用就什么都不做（幂等）
	if swapon --show 2>/dev/null | grep -q "^$DEV"; then
		say "$DEV 已在用，跳过"
		return 0
	fi

	say "加载 zram 模块"
	modprobe zram 2>/dev/null || say "  modprobe 失败，继续（可能已内建）"

	local s; s=$(sysfs)
	local i=0
	while [ ! -e "$s" ] && [ "$i" -lt 20 ]; do
		sleep 0.1; i=$((i + 1))
	done
	if [ ! -e "$s" ]; then
		say "等不到 $s，放弃（最坏只是没有 swap）"
		return 0
	fi
	say "  $s 就绪"

	# 压缩算法：这台机器的 zram 只编了 lzo-rle / lzo，用内核默认的即可。
	# （编了 lz4 / zstd 的机器上，可以取消下面两行的注释换更好的压缩率）
	# [ -w "$s/comp_algorithm" ] && grep -q lz4 "$s/comp_algorithm" \
	#	&& echo lz4 > "$s/comp_algorithm" 2>/dev/null

	say "设置 disksize = $SIZE"
	if ! echo "$SIZE" > "$s/disksize" 2>/dev/null; then
		say "  写 disksize 失败，先 reset 再试"
		echo 1 > "$s/reset" 2>/dev/null
		echo "$SIZE" > "$s/disksize" 2>/dev/null || { say "  仍失败，放弃"; return 0; }
	fi

	say "mkswap $DEV"
	mkswap "$DEV" >/dev/null 2>&1 || { say "  mkswap 失败，放弃"; return 0; }

	# zram 比任何磁盘 swap 都快，给高优先级；将来若再加 eMMC swap 会自然排在后面
	if swapon -p 100 "$DEV" 2>/dev/null; then
		say "swapon 成功（优先级 100）"
	else
		say "swapon 失败，放弃（最坏只是没有 swap）"
		return 0
	fi

	swapon --show 2>/dev/null | sed 's/^/    /' >> "$LOG" 2>/dev/null
}

case "${1:-start}" in
	start) do_start ;;
	stop)  do_stop  ;;
	*)     echo "用法: $0 start|stop" >&2; exit 2 ;;
esac
exit 0
