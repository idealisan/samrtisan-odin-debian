#!/bin/bash
# odin-modem-fw.sh —— 取 modem（mpss）固件，并把 modem 拉起来
#
# 为什么要它：
#   **GPS 挂在 modem 上** —— 主线给 msm8953 留的 gps_mem 只是给 memshare 用的，
#   真正的定位是 modem 通过 QMI 的 LOC 服务提供（走 QRTR/SMD）。
#   modem 不起来，GPS 就无从谈起（顺带也没有蜂窝数据/短信）。
#
# 固件：mba.mbn + modem.mdt + modem.bXX，就在原厂 modem 分区的 /image/ 里，
#   与 wcnss.* / venus.* / adsp.* 同级 —— 同样不属于任何 Debian 包，
#   也不该进版本库（二进制）。
#
# 时序：qcom,msm8953-mss-pil 是 remoteproc，跟 ADSP 一样**可以在用户态重启**，
#   不需要回到内核 probe 阶段。所以这里（用户态）取固件 + start 就行，
#   不依赖 initramfs 重建（那层有 staging 缓存，见 odin-adsp-fw.sh 的说明）。
#
# 失败一律不致命 —— 最坏结果只是没有 modem / GPS，绝不能把启动拖住或搞挂。
set -u

FW=modem.mdt
MBA=mba.mbn
DEST=/lib/firmware
LOG=/var/log/odin-modem-fw.log
PROC=/sys/class/remoteproc
# 等 modem 这个 remoteproc 出现的最长时间（秒）。
# mss 的 probe 依赖 smp2p_modem / rpmpd / 一批时钟，出现得比 adsp 还晚，给 60 秒。
WAIT_MAX=60

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; echo "[odin-modem-fw] $*" >&2; }

# 找到 modem 那个 remoteproc。
# 名字不好写死：mss 驱动用的是 pdev->name（DT 节点名，形如 4080000.remoteproc），
# 不同内核版本可能不同。所以三个判据取或：
#   1) sysfs 的 firmware 属性等于 modem.mdt
#   2) 名字里含 4080000（mss 在 msm8953 上的基址）
#   3) 名字里含 modem / mpss
rp_modem() {
	local d
	for d in "$PROC"/remoteproc*; do
		[ -d "$d" ] || continue
		local nm fw
		nm=$(cat "$d/name" 2>/dev/null)
		fw=$(cat "$d/firmware" 2>/dev/null)
		case "$fw$nm" in
			*modem.mdt*) echo "$d"; return 0 ;;
			*4080000*)   echo "$d"; return 0 ;;
			*modem*|*mpss*) echo "$d"; return 0 ;;
		esac
	done
	return 1
}

have_fw() {
	# 三个都得在：.mdt 是段表，.b* 是段本体，mba.mbn 是 MBA 加载器
	[ -s "$DEST/$FW" ] || return 1
	[ -s "$DEST/$MBA" ] || return 1
	ls "$DEST"/modem.b* >/dev/null 2>&1
}

start_modem() {
	local rp=$1
	local st
	st=$(cat "$rp/state" 2>/dev/null)
	say "remoteproc 当前状态: ${st:-未知}"
	case "$st" in
		running) say "已在 running，不再重复启动"; return 0 ;;
	esac
	echo start > "$rp/state" 2>/dev/null
	local i
	for i in $(seq 1 30); do
		sleep 1
		st=$(cat "$rp/state" 2>/dev/null)
		[ "$st" = "running" ] && { say "modem 已 running（等了 ${i}s）"; return 0; }
		case "$st" in
			*failed*|*crashed*) say "modem 启动失败: $st"; return 1 ;;
		esac
	done
	say "等了 30s 仍未 running（当前 $st），放弃"
	return 1
}

# 按 GPT 分区名找设备节点（与 initramfs 里那套是同一份逻辑）
part_dev() {
	local name=$1 d
	for d in /sys/class/block/*; do
		[ -f "$d/uevent" ] || continue
		if grep -q "^PARTNAME=$name$" "$d/uevent" 2>/dev/null; then
			sed -n 's/^DEVNAME=//p' "$d/uevent" 2>/dev/null | head -1 | sed 's|^|/dev/|'
			return 0
		fi
	done
	return 1
}

say "=== 开始 ==="

# 1) 等 remoteproc 出现
rp=
for i in $(seq 1 "$WAIT_MAX"); do
	if rp=$(rp_modem); then
		say "找到 modem remoteproc: $rp (name=$(cat "$rp/name" 2>/dev/null), fw=$(cat "$rp/firmware" 2>/dev/null))"
		break
	fi
	sleep 1
done
if [ -z "$rp" ]; then
	say "等了 ${WAIT_MAX}s 也没找到 modem remoteproc —— DTB 里 &mpss 没开？跳过"
	exit 0
fi

# 2) 固件不在位就从原厂 modem 分区取
if have_fw; then
	say "固件已在位，跳过取固件"
else
	say "固件不全，从原厂 modem 分区取"
	if dev=$(part_dev modem); then
		tmp=$(mktemp -d /tmp/odin-modem-fw-XXXXXX 2>/dev/null)
		if [ -n "${tmp:-}" ] && mount -o ro "$dev" "$tmp" 2>/dev/null; then
			mkdir -p "$DEST"
			for cand in "$tmp"/image/mba.mbn "$tmp"/image/MBA.MBN \
			            "$tmp"/image/modem.* "$tmp"/image/MODEM.*; do
				[ -f "$cand" ] || continue
				base=${cand##*/}
				lower=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
				cmp -s "$cand" "$DEST/$lower" && continue
				if cp -f "$cand" "$DEST/$lower" 2>/dev/null; then
					say "已取 $lower ($(stat -c%s "$cand") 字节) ← modem"
				fi
			done
			umount "$tmp" 2>/dev/null
			rmdir "$tmp" 2>/dev/null
		else
			say "modem 分区挂载失败，跳过取固件"
			rmdir "${tmp:-}" 2>/dev/null
		fi
	else
		say "找不到 modem 分区，跳过取固件"
	fi
fi

# 3) 固件齐了就把 modem 拉起来
if have_fw; then
	say "固件就位"
	start_modem "$rp" && say "modem 已 running" || say "modem 启动失败（详见 dmesg）"
else
	say "仍未取到 $FW / $MBA，跳过（最坏结果只是没有 modem 与 GPS）"
fi

exit 0
