#!/bin/bash
# odin-swap.sh —— 准备 5 GiB 的 swapfile（首次开机时执行，幂等）
#
# 为什么要有 swap：本机内存 3.5 GiB。作为家用设备（跑 GUI、浏览器、若干后台）
# 3.5 GiB 偏紧，没有 swap 时一紧张就 OOM kill。5 GiB swap 换来的是"卡一点"
# 而不是"进程被杀"。
#
# 为什么是 swapfile 而不是分区：分区要动 GPT、且每台机器大小不一；
# swapfile 放在根文件系统里，随镜像走，尺寸可以按需要改。
#
# ⚠ fallocate 在这里**不可用**：镜像的 ext4 关掉了 extents
# （tools/build-image.sh 里 mke2fs -O ^extents，为的是让 lk2nd 的 ext2 驱动
#  能读它）。所以下面先试 fallocate，失败就用 dd。
#
# 失败一律不致命 —— 最坏只是没有 swap，绝不能把启动搞挂。
set -u

SIZE=${ODIN_SWAP_SIZE:-5G}
FILE=${ODIN_SWAP_FILE:-/swapfile}
LOG=/var/log/odin-swap.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; echo "[odin-swap] $*" >&2; }

# 已经挂上了就什么都不做（幂等）
if swapon --show 2>/dev/null | grep -q "^$FILE"; then
	[ -e "$LOG" ] && say "$FILE 已在用，跳过"
	exit 0
fi

WANT_BYTES=$((5120 * 1024 * 1024))     # 5 GiB；改 SIZE 时这里要同步

if [ -f "$FILE" ]; then
	have=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
	# ⚠️ 不能只看"文件存在"。2026-09-04 实踩：本服务跑在 resize2fs 之前，
	#    dd 在没扩容的文件系统上写出 231MB 就 ENOSPC 失败，留下一个**半截**的
	#    /swapfile；此后每次开机都因为"文件存在"而跳过创建、直接 swapon，
	#    于是 swap 永远起不来，而服务仍 exit 0 假装成功。
	#    所以这里按大小判定：不够就删掉重建。
	if [ "$have" -ge "$WANT_BYTES" ]; then
		say "$FILE 已存在且大小足够（$have 字节），跳过创建"
	else
		say "$FILE 不完整（$have < $WANT_BYTES 字节），删掉重建"
		rm -f "$FILE"
	fi
fi

if [ ! -f "$FILE" ]; then
	say "创建 $FILE（$SIZE）"
	if ! fallocate -l "$SIZE" "$FILE" 2>/dev/null; then
		say "  fallocate 不可用（ext4 关了 extents），改用 dd"
		# 5120 个 1M 块 ≈ 5 GiB；SIZE 改了这里要同步
		dd if=/dev/zero of="$FILE" bs=1M count=5120 status=none || { say "dd 失败，放弃"; exit 0; }
	fi
	chmod 600 "$FILE" 2>/dev/null
	mkswap "$FILE" >/dev/null 2>&1 || { say "mkswap 失败，放弃"; rm -f "$FILE"; exit 0; }
	say "  已建好"
fi

if ! swapon "$FILE" 2>/dev/null; then
	say "swapon 失败；删掉 $FILE 后重试一次"
	# 上一轮可能留了个 mkswap 过但格式不对的文件，清掉重来比留着强
	swapoff "$FILE" 2>/dev/null
	rm -f "$FILE"
	if dd if=/dev/zero of="$FILE" bs=1M count=5120 status=none 2>/dev/null \
	   && chmod 600 "$FILE" 2>/dev/null \
	   && mkswap "$FILE" >/dev/null 2>&1 \
	   && swapon "$FILE" 2>/dev/null; then
		say "重试后 swapon 成功"
	else
		say "重试后仍失败，放弃（最坏结果只是没有 swap）"
		rm -f "$FILE"
		exit 0
	fi
else
	say "swapon 成功"
fi

# 写进 fstab，下次开机自动挂（先备份原文件，符合可逆改动的约定）
if [ -f /etc/fstab ] && ! grep -q "^$FILE" /etc/fstab; then
	[ -f /etc/fstab.odin-bak ] || cp -a /etc/fstab /etc/fstab.odin-bak 2>/dev/null
	echo "$FILE none swap sw 0 0" >> /etc/fstab
	say "已写入 /etc/fstab"
fi
