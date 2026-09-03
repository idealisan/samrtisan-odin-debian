#!/bin/bash
# odin-venus-fw.sh —— 从原厂 modem 分区取出 venus（视频硬编解码）固件，
#                     并确保 venus 设备真的起来了
#
# 存在理由有两条：
#
#   1. 兜底。正确时序是在 initramfs 里、switch_root 之前备好（见
#      dist/build/initramfs/sbin/odin-venus-fw.sh 的头部说明）——
#      驱动第一次 request_firmware() 就直接成功，不需要任何补救。
#      但**已经刷好的机器**里那个 initramfs 还没有这段，而 venus 是模块，
#      可以重建 probe 补救，所以这里留一条用户态兜底路径。
#
#   2. 可运维。取没取到、取了哪些、重建结果，都留在日志里，
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
VENUS_LIB=/usr/local/lib/odin/venus-devs.sh
# "重建 venus probe" 的已重试标记 —— 保证只重试一次，不每开机都撞（见文末 §2）
RETRIED=/var/lib/odin-venus-retried

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

# venus 设备判据（为什么不能用 /dev/video* 见该文件头部的说明）
if [ -r "$VENUS_LIB" ]; then
	# shellcheck source=/dev/null
	. "$VENUS_LIB"
else
	# 库缺失时退化成"没有 venus"，宁可不重试也不要用错判据误报成功
	odin_venus_devs() { :; }
	odin_venus_dev() { return 1; }
	say "WARN: 缺 $VENUS_LIB，无法判定 venus 设备"
fi

venus_up() { odin_venus_devs | grep -q .; }

# 只认 .mdt：段表在里面，段文件由内核的 qcom_mdt 按需去取
have_fw() { [ -s "$DEST/venus.mdt" ]; }

# 重建 venus 的 probe。
#
# 优先走 **platform driver 的 unbind + bind**，刻意不用 rmmod/insmod：
# 真机上踩过 —— insmod 卡在不可中断的 D 状态（core->lock 被死掉的 IRQ 线程
# 握着），sudo reboot 都被它挡住没能完成，设备停在"网络在（ping 通）、
# SSH 已停、救援端口也没开"的半关机状态，只能长按电源键（reports/029 §7）。
# unbind/bind 不卸载模块，venus_core 的 struct module 全程没动，没有这个坑：
# 重新走一遍 venus_probe()，devm 分配的资源会先全部释放再重来。
#
# 注意 bind 的目标要从 /sys/bus/platform/devices 里找，不能从
# .../drivers/qcom-venus/ 里找：probe 失败时驱动核心已经把设备解绑了，
# 驱动目录下是空的，但 platform 设备本身还在。
venus_reload() {
	local dev="" D=/sys/bus/platform/drivers/qcom-venus

	for d in /sys/bus/platform/devices/*; do
		case "${d##*/}" in
			*.venus) dev=${d##*/}; break ;;
		esac
	done

	if [ -n "$dev" ] && [ -d "$D" ]; then
		say "重建 $dev 的 probe（unbind + bind，不动模块）"
		echo "$dev" > "$D/unbind" 2>/dev/null
		echo "$dev" > "$D/bind" 2>/dev/null
		say "bind rc=$?"
		return 0
	fi

	# 退化路径：模块还没加载（比如本服务跑得比 udev 早）
	say "venus platform 设备/驱动不可用，退化为 modprobe 重载"
	for m in venus-dec venus-enc; do
		modprobe -r "$m" 2>/dev/null
	done
	modprobe -r venus-core 2>/dev/null
	modprobe venus-core 2>/dev/null
	say "modprobe venus-core rc=$?"
}

# ---------------------------------------------------------------- 1. 取固件
have_fw || {
	dev=$(readlink -f /dev/disk/by-partlabel/modem 2>/dev/null)
	if [ ! -b "${dev:-}" ]; then
		say "modem 分区不存在，跳过取固件"
	else
		tmp=$(mktemp -d) || tmp=
		if [ -n "${tmp:-}" ] && mount -o ro "$dev" "$tmp" 2>/dev/null; then
			mkdir -p "$DEST"
			for cand in "$tmp"/image/venus.* "$tmp"/image/VENUS.* \
			            "$tmp"/venus.* "$tmp"/VENUS.*; do
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
			say "modem 挂载失败，跳过取固件"
			rmdir "${tmp:-}" 2>/dev/null
		fi
	fi
}

# ------------------------------------------------- 2. 确保 venus 真的起来了
# 驱动若早已因缺固件而 probe 失败，它不会自己重试 —— 重建一次让它再来。
# 这一步与"这次有没有新拷到固件"无关：固件早就齐全、但 probe 一直失败的机器
# 同样需要它（那正是本服务存在的意义）。
#
# ⚠️ 但**只重试一次**（靠 $RETRIED 标记），不能每次开机都重试：
#   重建 probe 就是让 venus 固件重新 boot 一次，而"venus 相关操作卡在不可中断
#   状态、连 reboot 都被挡住、设备停在'网络在、SSH 已停'的半关机状态"在本机
#   有实锤记录（reports/029 §7）。每次开机都去撞一次，等于把一个小概率的
#   启动失败放大成每开机必赌一次。重试一次拿不到，就交给人工 —— 日志里会
#   写明怎么再给它一次机会。
if venus_up; then
	say "venus 已就绪：$(odin_venus_devs | tr '\n' ' ')"
	# 起来了就清掉标记：将来万一又坏了，还能再自动重试一次
	rm -f "$RETRIED" 2>/dev/null
	exit 0
fi

if [ ! -s "$DEST/venus.mdt" ]; then
	say "venus 未就绪，且固件也不在位 —— 重建 probe 只会再失败一次，跳过"
	exit 0
fi

if [ -e "$RETRIED" ]; then
	say "venus 未就绪，但已重试过一次（标记 $RETRIED）—— 不再每开机都撞一次"
	say "要再试一次：sudo rm -f $RETRIED && sudo systemctl restart odin-venus-fw"
	exit 0
fi

say "venus 未就绪且固件在位 —— 重建一次 probe"
mkdir -p /var/lib 2>/dev/null
: > "$RETRIED" 2>/dev/null
venus_reload

# 编解码两个子模块绑定 venus 注册的 video-decoder/video-encoder 平台设备，
# 靠 udev 自动加载；这里显式排一遍，免得依赖时序
for m in venus-dec venus-enc; do
	modprobe "$m" 2>/dev/null
done

if venus_up; then
	say "venus 已就绪：$(odin_venus_devs | tr '\n' ' ')"
else
	say "venus 仍未就绪（详见 dmesg）"
fi

exit 0
