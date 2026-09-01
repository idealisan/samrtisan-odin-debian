#!/bin/sh
# odin-venus-fw.sh —— 在 switch_root 之前，把 venus（视频硬编解码）固件
#                     放进真正的根文件系统
#
# 用法:
#   odin-venus-fw.sh <真实根的挂载点>            # 取出缺失的文件
#   odin-venus-fw.sh <真实根的挂载点> --check    # 只检查是否齐全，不动盘
#
# 为什么必须在这里做（理由与 odin-wlan-fw.sh 完全同源，见该文件头部）：
#   qcom-venus 是 platform 驱动，开机早期就会被 udev 加载并立刻
#   request_firmware("venus.mdt")。放到 systemd 的 late service 里做就晚了：
#   驱动那次请求失败后不会再自己重试，venus 就永远停在 probe 失败。
#   固件必须在 switch_root **之前**、也就是驱动第一次请求之前就位。
#
# 固件来源：原厂 modem 分区的 /image/ 目录（venus 的 PIL 映像就放在这里，
#   与 wcnss.* 同级）。它不属于任何 Debian 软件包，也不该进版本库（二进制）。
#   modem 分区我们从没动过，只要没被清掉数据就在。
#
# 段文件数量随 ROM 版本可能变化（本机是 .b00~.b04，别的版本可能不同），
# 所以这里不写死列表，而是把分区里所有 venus.* 都搬过去；校验只认
# venus.mdt —— 段表就在 .mdt 里，qcom_mdt 会按表去取各段。
#
# 失败一律不致命 —— 最坏结果只是没有硬件编解码，绝不能因为取不到把启动搞挂。
set -u

MDT=venus.mdt
SCRATCH=/tmp/odin-venus-fw
LOGFILE=

log() {
	echo "[odin-venus-fw] $*" >&2
	[ -n "$LOGFILE" ] && echo "$(date '+%F %T') $*" >> "$LOGFILE" 2>/dev/null
	return 0
}

# 按 GPT 分区名找设备节点（initramfs 里没有 udev，靠 sysfs 的 uevent）
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

# 固件是否已就位（只认 .mdt：段表在里面，段文件由 qcom_mdt 按需取）
check() {
	root=$1
	[ -s "$root/lib/firmware/$MDT" ]
}

ROOT=${1:-}
[ -n "$ROOT" ] || { log "用法: odin-venus-fw.sh <真实根挂载点> [--check]"; exit 1; }
[ -d "$ROOT" ] || { log "真实根挂载点不存在: $ROOT"; exit 1; }
[ -d "$ROOT/var/log" ] && LOGFILE="$ROOT/var/log/odin-venus-fw.log"

for a in "$@"; do
	if [ "$a" = "--check" ]; then
		if check "$ROOT"; then exit 0; else exit 1; fi
	fi
done

dev=$(part_dev modem) || { log "modem 分区未找到，跳过"; exit 0; }
mnt=$SCRATCH/modem
mkdir -p "$mnt" 2>/dev/null || { log "无法建挂载点 $mnt"; exit 0; }
if ! mount -o ro "$dev" "$mnt" 2>/dev/null; then
	log "modem($dev) 挂载失败，跳过"
	rmdir "$mnt" 2>/dev/null
	exit 0
fi

mkdir -p "$ROOT/lib/firmware" 2>/dev/null
copied=0
# 分区里的文件名大小写不定（实测同一份映像在 FAT 目录项里是大写，
# 而挂载后的查找又是小写可用的），所以统一按小写落到 /lib/firmware。
for cand in "$mnt"/image/venus.* "$mnt"/image/VENUS.* "$mnt"/venus.* "$mnt"/VENUS.*; do
	[ -f "$cand" ] || continue
	base=${cand##*/}
	lower=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
	cmp -s "$cand" "$ROOT/lib/firmware/$lower" && continue
	if cp -f "$cand" "$ROOT/lib/firmware/$lower" 2>/dev/null; then
		log "已取 $lower ($(stat -c%s "$cand") 字节) ← modem"
		copied=$((copied + 1))
	fi
done
sync
umount "$mnt" 2>/dev/null
rmdir "$mnt" 2>/dev/null

if check "$ROOT"; then
	log "venus 固件就位（本次新取 $copied 个文件）"
else
	log "未取到 $MDT，跳过（最坏结果只是没有硬件编解码）"
fi

exit 0
