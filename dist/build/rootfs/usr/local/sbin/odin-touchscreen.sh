#!/bin/sh
# odin-touchscreen.sh —— 等面板起来之后重新 probe 触摸屏
#
# 为什么需要它
# ------------
# 本机的触摸是 **FocalTech FT8716**，与显示驱动集成在同一颗 **TDDI** 上：
# 面板没上电的时候，它根本不响应 I2C。而 `msm`(DRM) 与 `panel_ft8716` 都是
# 内核模块，靠 udev 冷插逐个加载 —— 实测这条链要到 48s 才跑完：
#
#   [33.776] ibb: disabling            ← 面板 probe 试了一次，推迟，释放负压轨
#   [43.152] edt_ft5x06 1-0038: supply vcc not found, using dummy regulator
#   [43.729] edt_ft5x06 1-0038: touchscreen probe failed      ← 触摸先到
#   [43.974] edt_ft5x06 1-0038: probe with driver edt_ft5x06 failed with error -5
#   [48.466] msm_dpu 1a01000.display-controller: bound 1a94000.dsi   ← 显示才起来
#   [48.962] [drm] fb0: msmdrmfb frame buffer device
#
# 触摸比面板早约 5 秒 ⇒ 拿 -5(EIO) 失败 ⇒ **整个会话都没有触摸设备**，
# 而 dmesg 里只有一句轻描淡写的 "probe failed"，不看时间戳根本发现不了。
#
# 面板起来之后再 probe 一次就正常（手工验证）：
#   input: generic ft5x06 (8d) as .../78b7000.i2c/i2c-1/1-0038/input/input6
#
# 为什么不在 DT 里解决
# --------------------
# 想过给触摸补 `vcc-supply`（vince 上就是这样，vcc + iovcc 都声明）。
# 但原厂 DTS（evidence/stock-rom-battery/odin-stock.dts:6367）里 focaltech@38
# **只声明了 vcc_i2c-supply**，没有独立主电 —— 说明主电就是跟显示共享的，
# 没有第二路轨可以指。所以从供电入手是猜，不如直接把时序理顺。
#
# 与 odin-venus-fw.sh 是同一个套路：依赖就绪后强制重新 probe。

set -u

say() { printf '[touch] %s\n' "$*"; }

touch_ready() {
	grep -qs ft5x06 /sys/class/input/*/device/name 2>/dev/null
}

if touch_ready; then
	say "触摸已注册，无需重载"
	exit 0
fi

say "等待显示就绪（/dev/dri/card0）"
i=0
while [ ! -e /dev/dri/card0 ] && [ "$i" -lt 30 ]; do
	sleep 1
	i=$((i + 1))
done
if [ ! -e /dev/dri/card0 ]; then
	say "❌ 等了 ${i}s 显示仍未就绪，放弃（触摸不会有）"
	exit 1
fi
say "显示已就绪（等了 ${i}s）"

say "重新 probe edt_ft5x06"
modprobe -r edt_ft5x06 2>/dev/null
sleep 1
modprobe edt_ft5x06 2>&1 | sed 's/^/  /'
sleep 2

if touch_ready; then
	say "✅ 触摸已注册"
	exit 0
fi
say "❌ 重新 probe 后仍未注册"
exit 1
