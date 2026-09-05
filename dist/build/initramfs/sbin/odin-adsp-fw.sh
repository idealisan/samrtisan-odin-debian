#!/bin/sh
# odin-adsp-fw.sh —— 在 switch_root 之前，把 ADSP（音频 DSP）固件
#                    放进真正的根文件系统
#
# 用法:
#   odin-adsp-fw.sh <真实根的挂载点>            # 取出缺失的文件
#   odin-adsp-fw.sh <真实根的挂载点> --check    # 只检查是否齐全，不动盘
#
# 为什么必须在这里做（理由与 odin-wlan-fw.sh / odin-venus-fw.sh 完全同源）：
#   ADSP 由 drivers/remoteproc/qcom_q6v5_pas.c 加载，
#   qcom,msm8953-adsp-pil 的匹配数据是 msm8996_adsp_resource：
#       .firmware_name = "adsp.mdt"
#       .auto_boot     = true      ← 驱动起来就立刻 request_firmware
#       .pas_id        = 1
#   主线 msm8953 的整条音频链路（q6afe / q6adm / q6asm / q6routing）都跑在 ADSP 上，
#   没有这份固件就一个声卡都出不来（实测：/proc/asound/cards 是 "no soundcards"）。
#   auto_boot 意味着**没有第二次机会** —— 第一次请求失败就停在 offline，
#   之后补文件也不会自己重试。所以必须在 switch_root 之前备好。
#
# 固件来源：原厂 modem 分区的 /image/ 目录，与 wcnss.*、venus.* 同级
#   （实测本机有 adsp.mdt + adsp.b00~adsp.b13，共约 9.5 MB）。
#   不属于任何 Debian 软件包，也不该进版本库（二进制）。
#   modem 分区我们从没动过，只要没被清掉数据就在。
#
# 段文件数量随 ROM 版本可能变化，所以不写死列表，把分区里所有 adsp.* 都搬过去；
# 校验只认 adsp.mdt —— 段表就在 .mdt 里，qcom_mdt 会按表去取各段。
#
# 失败一律不致命 —— 最坏结果只是没有声音，绝不能因为取不到把启动搞挂。
set -u

MDT=adsp.mdt
SCRATCH=/tmp/odin-adsp-fw
LOGFILE=

log() {
	echo "[odin-adsp-fw] $*" >&2
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

# 固件是否已就位。
# 主判据只认 .mdt；但额外要求至少一个 adsp.b* 段文件 —— 否则"上次拷到一半被
# 断电"会留下只有 .mdt 的半套固件，而这个 check 会一直返回真、之后再也不补。
check() {
	root=$1
	[ -s "$root/lib/firmware/$MDT" ] || return 1
	ls "$root/lib/firmware"/adsp.b* >/dev/null 2>&1
}

ROOT=${1:-}
[ -n "$ROOT" ] || { log "用法: odin-adsp-fw.sh <真实根挂载点> [--check]"; exit 1; }
[ -d "$ROOT" ] || { log "真实根挂载点不存在: $ROOT"; exit 1; }
[ -d "$ROOT/var/log" ] && LOGFILE="$ROOT/var/log/odin-adsp-fw.log"

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
# 分区里的文件名大小写不定（FAT 目录项里是大写，挂载后小写也可用），
# 统一按小写落到 /lib/firmware。
for cand in "$mnt"/image/adsp.* "$mnt"/image/ADSP.* "$mnt"/adsp.* "$mnt"/ADSP.*; do
	[ -f "$cand" ] || continue
	base=${cand##*/}
	lower=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
	cmp -s "$cand" "$ROOT/lib/firmware/$lower" && continue
	if cp -f "$cand" "$ROOT/lib/firmware/$lower" 2>/dev/null; then
		log "已取 $lower ($(stat -c%s "$cand") 字节) ← modem"
		copied=$((copied + 1))
	fi
done
# 这里**不** sync：sync 是全局的，会把根分区所有脏页一起刷掉，而调用方
# （init）在几段固件都取完之后会统一 sync 一次。中途这几次纯属重复劳动 ——
# 2026-09-05 首启实测每段各卡 42~70s。拷出来的脏页在页缓存里不会丢，
# umount 的也只是只读挂载的源分区。
umount "$mnt" 2>/dev/null
rmdir "$mnt" 2>/dev/null

if check "$ROOT"; then
	log "ADSP 固件就位（本次新取 $copied 个文件）"
else
	log "未取到 $MDT，跳过（最坏结果只是没有声音）"
fi

exit 0
