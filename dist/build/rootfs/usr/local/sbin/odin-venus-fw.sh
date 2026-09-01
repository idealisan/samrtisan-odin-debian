#!/bin/bash
# odin-venus-fw.sh —— 从原厂 modem 分区取出 venus（视频硬编解码）固件
#
# 存在理由有两条：
#
#   1. 兜底。正确时序是在 initramfs 里、switch_root 之前备好（见
#      dist/build/initramfs/sbin/odin-venus-fw.sh 的头部说明）——
#      驱动第一次 request_firmware() 就直接成功，不需要任何补救。
#      但**已经刷好的机器**里那个 initramfs 还没有这段，而 venus 是模块，
#      可以 modprobe -r / modprobe 补救，所以这里留一条用户态兜底路径。
#
#   2. 可运维。取没取到、取了哪些、模块重载结果，都留在日志里，
#      不用为了看一眼去解 initramfs。
#
# 固件：venus.mdt + venus.b00...（段表在 .mdt 里，qcom_mdt 按表取段）
#   来源：原厂 modem 分区（/dev/disk/by-partlabel/modem）的 /image/ 目录。
#   不属于任何 Debian 软件包，也不该进版本库（二进制）。
#
# 段文件数量随 ROM 版本可能变化，所以不写死列表，把分区里所有 venus.* 都搬过去。
#
# 失败一律不致命 —— 最坏结果只是没有硬件编解码，绝不能因为取不到把启动搞挂。
set -u

DEST=/lib/firmware
LOG=/var/log/odin-venus-fw.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

# 只认 .mdt：段表在里面，段文件由内核的 qcom_mdt 按需去取
have_fw() { [ -s "$DEST/venus.mdt" ]; }

have_fw && { say "venus 固件已在位，无需动作"; exit 0; }

dev=$(readlink -f /dev/disk/by-partlabel/modem 2>/dev/null)
if [ ! -b "$dev" ]; then
	say "modem 分区不存在，跳过"
	exit 0
fi

tmp=$(mktemp -d) || exit 0
if ! mount -o ro "$dev" "$tmp" 2>/dev/null; then
	say "modem 挂载失败，跳过"
	rmdir "$tmp" 2>/dev/null
	exit 0
fi

mkdir -p "$DEST"
copied=0
for cand in "$tmp"/image/venus.* "$tmp"/image/VENUS.* "$tmp"/venus.* "$tmp"/VENUS.*; do
	[ -f "$cand" ] || continue
	base=${cand##*/}
	lower=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
	cmp -s "$cand" "$DEST/$lower" && continue
	if cp -f "$cand" "$DEST/$lower" 2>/dev/null; then
		say "已取 $lower ($(stat -c%s "$cand") 字节) ← modem"
		copied=$((copied + 1))
	fi
done
umount "$tmp" 2>/dev/null
rmdir "$tmp" 2>/dev/null

# 驱动若早已因缺固件而 probe 失败，它不会自己重试 —— 重载让它再来一次。
# 收得很紧：确实刚拷到东西、且 /dev/video* 还没出来，才动模块。
if [ "$copied" -gt 0 ] && ! compgen -G '/dev/video*' > /dev/null; then
	say "重新加载 venus 模块以便读取固件"
	for m in venus_enc venus_dec venus_core; do
		modprobe -r "$m" 2>/dev/null
	done
	modprobe venus_core 2>/dev/null
	say "重载完成，rc=$?"
	# 编解码两个子模块绑定 venus 注册的 video-decoder/video-encoder 平台设备，
	# 靠 udev 自动加载；这里显式排一遍，免得依赖时序
	for m in venus_dec venus_enc; do
		modprobe "$m" 2>/dev/null
	done
	if compgen -G '/dev/video*' > /dev/null; then
		say "venus 已就绪: $(ls /dev/video*)"
	else
		say "venus 仍未就绪（详见 dmesg）"
	fi
fi

exit 0
