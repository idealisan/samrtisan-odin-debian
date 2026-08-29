#!/bin/bash
# odin-wlan-nv.sh —— 从 persist 分区取出 WCNSS 的板级校准数据
#
# wcn36xx 驱动要的 NV 文件是 /lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin
# （见内核 drivers/net/wireless/ath/wcn36xx/wcn36xx.h 的 WLAN_NV_FILE）。
# 它是**每台机器都不一样**的射频校准数据，原厂放在 persist 分区里，
# 既不在 Debian 的任何软件包中，也不该进版本库（二进制 + 设备相关）。
#
# 所以：刷机镜像里不带它，开机时从 persist 分区现取。persist 是我们唯一
# 没动过的原厂分区，只要没被清掉，这份数据就在。
#
# 失败一律不致命——最坏结果是没有 WiFi，不能因为取不到就把启动搞挂。
set -u

DEST=/lib/firmware/wlan/prima
LOG=/var/log/odin-wlan-nv.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

DEV=$(readlink -f /dev/disk/by-partlabel/persist 2>/dev/null)
if [ ! -b "$DEV" ]; then
  say "persist 分区不存在，跳过（WiFi 将不可用）"
  exit 0
fi

mkdir -p "$DEST"
TMP=$(mktemp -d) || exit 0
if ! mount -o ro "$DEV" "$TMP" 2>/dev/null; then
  say "persist 挂载失败，跳过"
  rmdir "$TMP" 2>/dev/null
  exit 0
fi

copied=0
for f in WCNSS_qcom_wlan_nv.bin WCNSS_wlan_dictionary.dat; do
  if [ -s "$TMP/$f" ]; then
    if ! cmp -s "$TMP/$f" "$DEST/$f"; then
      cp -f "$TMP/$f" "$DEST/$f" && { say "已取 $f ($(stat -c%s "$TMP/$f") 字节)"; copied=1; }
    fi
  fi
done
umount "$TMP" 2>/dev/null
rmdir "$TMP" 2>/dev/null

# 驱动如果已经先于我们加载过，那时是没有 NV 文件的，重新装一次让它读到。
# 判断条件收得很紧：确实刚拷了文件、且 wlan0 还不存在，才动模块。
if [ "$copied" = 1 ] && [ ! -d /sys/class/net/wlan0 ]; then
  say "重新加载 wcn36xx 以读取 NV 数据"
  modprobe -r wcn36xx 2>/dev/null
  modprobe wcn36xx 2>/dev/null
  say "重载完成，rc=$?"
fi

exit 0
