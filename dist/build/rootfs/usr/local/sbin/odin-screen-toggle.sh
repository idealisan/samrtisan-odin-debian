#!/bin/sh
# odin-screen-toggle.sh —— 电源键：开关屏幕（不是关机）
#
# 为什么是"开关屏"而不是"关机"
# ----------------------------
# 99-odin-powerkey.conf 里已经把 logind 对所有按键的电源动作全部设成 ignore：
# 手机放兜里极易误触，一关机就只剩 USB 网络这一条生命线，救援很被动。
#
# 但装了触屏键盘之后屏幕常亮，误触会打出字来 —— 所以把电源键改造成开关屏。
# 关屏时**顺手停掉 buffyboard**：误触不会打出字，也省掉每秒一次的重绘。
#
# 按键怎么接进来的
# ----------------
# udev 只在设备插拔时触发，监听不到按键，所以不能写 udev 规则。
# 用 triggerhappy（Debian 热键守护进程），配置见
# /etc/triggerhappy/triggers.d/odin-screen.conf。
#
# 为什么用背光、而**不是** console blank
# --------------------------------------
# 第一版写的是 /sys/class/graphics/fb0/blank，真机表现为"灭了马上又亮"：
# console blank 会被**任意输入事件自动解除** —— 按下电源键的抬手、甚至一次
# 触摸，都算输入，于是刚灭就亮。
#
# 背光不会。/sys/class/backlight/*/bl_power：0 = 亮，1 = 灭。关的是 WLED 背光
# 本身，输入事件管不着它。没有背光设备的机器再退回 console blank（能灭总比不灭好）。

set -u

BL_DIR=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
LOG() { echo "[screen] $(date -Is) $*"; }

if [ -n "$BL_DIR" ] && [ -e "${BL_DIR}bl_power" ]; then
	LOG "调用一次（当前 bl_power=$(cat "${BL_DIR}bl_power" 2>/dev/null)）"
	if [ "$(cat "${BL_DIR}bl_power" 2>/dev/null)" = "0" ]; then
		echo 1 > "${BL_DIR}bl_power"
		systemctl stop buffyboard.service 2>/dev/null
		LOG "已关屏（背光 off，buffyboard 已停）"
	else
		echo 0 > "${BL_DIR}bl_power"
		systemctl start buffyboard.service 2>/dev/null
		LOG "已开屏（背光 on，buffyboard 已起）"
	fi
	exit 0
fi

# 没有背光设备的兜底
BLANK=/sys/class/graphics/fb0/blank
[ -e "$BLANK" ] || { LOG "既没有背光也没有 fb0 blank，放弃" >&2; exit 1; }
LOG "调用一次（兜底路径，当前 blank=$(cat "$BLANK" 2>/dev/null)）"
if [ "$(cat "$BLANK" 2>/dev/null)" = "0" ]; then
	echo 1 > "$BLANK"
	systemctl stop buffyboard.service 2>/dev/null
	LOG "已关屏（console blank，buffyboard 已停）"
else
	echo 0 > "$BLANK"
	systemctl start buffyboard.service 2>/dev/null
	LOG "已开屏（console blank，buffyboard 已起）"
fi
exit 0
