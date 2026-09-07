#!/bin/sh
# odin-buffyboard-redraw.sh —— 让 BuffyBoard 全量重绘一次自己的画面
#
# 为什么要这个
# ------------
# BuffyBoard 的设计是"盖在标准 Linux 控制台之上"的：它自己画键盘，控制台画
# 文本，两者共用一块屏幕。真机上这会打架 —— 登录、exit、任何一次控制台整屏
# 更新，内核的 fbdev/DRM 就会把自己那份 buffer 翻上去，把 BuffyBoard 画好的
# 键盘顶掉。现象是：
#
#   · 键盘区域突然整块变黑；
#   · 但还能触摸，手指按到的那一小块会重新显形，其余仍是黑的
#     （LVGL 只把被触摸的那一小块标记为 dirty 重画了，其余没重画）。
#
# 这跟用 fbdev 还是 drm 后端无关 —— 两种都试过，症状一样。本质是两个东西
# 抢同一个 CRTC。
#
# 怎么办
# ------
# 上游其实已经给了重绘接口：SIGUSR1。收到后 main.c 会走 on_new_terminal()，
# 最终 `lv_obj_invalidate(keyboard)` —— 也就是把**整块键盘**标脏、全量重画。
# getty 那个 drop-in（getty@.service.d/buffyboard.conf）用的就是它。
#
# 所以这里不发什么私有信号，只是把上游这个"重绘"动作**周期性地**做一次：
# 控制台每次整屏刷新之后，最多 1 秒键盘就会自己补回来。
#
# 代价：一次全量重绘在 Cortex-A53 上软件渲染 1080×N 的键盘区域，量级是毫秒
# 级；1Hz 下 CPU 占用可忽略。比整块键盘黑着不能用划算得多。

set -u

for pid in $(pgrep -x buffyboard 2>/dev/null); do
	kill -s USR1 "$pid" 2>/dev/null
done

exit 0
