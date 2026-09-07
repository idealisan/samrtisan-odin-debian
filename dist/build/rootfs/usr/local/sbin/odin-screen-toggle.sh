#!/bin/sh
# odin-screen-toggle.sh —— 电源键：开关屏幕（不是关机）
#
# 为什么是"开关屏"而不是"关机"
# ----------------------------
# 99-odin-powerkey.conf 里已经把 logind 对所有按键的电源动作全部设成 ignore：
# 手机放兜里极易误触，一关机就只剩 USB 网络这一条生命线，救援很被动。
#
# 但有了触屏键盘之后又需要"让屏幕别误触" —— 所以把电源键改造成开关屏：
# 关屏时**顺手停掉 buffyboard**，这样误触不会打出字来，也省掉每秒一次的重绘。
#
# 按键怎么接进来的
# ----------------
# udev 只在设备插拔时触发，监听不到按键，所以不能写 udev 规则。
# 这里用 triggerhappy（Debian 自带的热键守护进程），配置见
# /etc/triggerhappy/triggers.d/odin-screen.conf。
#
# 真正的开关动作
# --------------
# /sys/class/graphics/fb0/blank：0 = 亮，1 = 灭。走的是内核 fbcon/DRM 的
# blank 通路（真机实测 0↔1 切换有效，背光 bl_power 跟着变）。

set -u

BLANK=/sys/class/graphics/fb0/blank

if [ ! -e "$BLANK" ]; then
	echo "[screen] 找不到 $BLANK，放弃" >&2
	exit 1
fi

if [ "$(cat "$BLANK" 2>/dev/null)" = "0" ]; then
	echo 1 > "$BLANK"
	# 关屏就别让键盘继续收触摸了：误触会打出字，而且每秒重绘是白烧 CPU
	systemctl stop buffyboard.service 2>/dev/null
	echo "[screen] 已关屏（buffyboard 已停）"
else
	echo 0 > "$BLANK"
	systemctl start buffyboard.service 2>/dev/null
	echo "[screen] 已开屏（buffyboard 已起）"
fi

exit 0
