#!/bin/sh
# odin-hotkey-wait.sh —— 等电源键设备出现，再让 thd 启动
#
# 为什么不直接 After=systemd-udev-settle.service：
#   那玩意儿实测要 21.6 秒（用户态总共才 1min35s 时它占了大头），而且它并不是
#   为"等某个具体设备"设计的。
#
# 为什么要等：
#   thd 的 --deviceglob 只在**启动时展开一次**。它在开机很早就跑起来了，那时
#   pm8941_pwrkey 还没注册 —— 结果 thd 只打开了 event1(gpio-keys)，压根没拿到
#   event2(pwrkey)，表现就是"按电源键没反应"（2026-09-08 实测）。
#
# 退出码：永远 0。等到了最好；等不到也让 thd 照常启动（最坏只是电源键不生效），
# 绝不能因为等不到就把开机卡住。

set -u

WANT=pm8941_pwrkey
MAX=60
i=0

while [ "$i" -lt "$MAX" ]; do
	for d in /sys/class/input/event*; do
		if [ -r "$d/device/name" ] && grep -qs "$WANT" "$d/device/name" 2>/dev/null; then
			echo "[odin-hotkey] 等到 $WANT（${i}s）"
			exit 0
		fi
	done
	i=$((i + 1))
	sleep 1
done

echo "[odin-hotkey] 等了 ${MAX}s 也没等到 $WANT，照常启动（电源键可能不生效）" >&2
exit 0
