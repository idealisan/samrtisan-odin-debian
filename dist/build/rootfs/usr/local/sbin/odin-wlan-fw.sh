#!/bin/bash
# odin-wlan-fw.sh —— 从原厂分区取出 WiFi（WCNSS）所需的全部数据
#
# wcn36xx 要两样东西，Debian 的任何软件包都不提供，也不该进版本库
# （都是二进制、且带机器相关信息的固件/校准数据）：
#
#   1. WCNSS 无线固件  wcnss.mdt + wcnss.b00/b01/...
#      内核按 firmware-name 默认找 wcnss.mbn，qcom_mdt 会回退到 wcnss.mdt，
#      再按 .mdt 里的表去加载各 .bXX 段。
#      来源：**modem 分区**（/dev/disk/by-partlabel/modem）的 /image/ 目录。
#
#   2. 板级射频校准数据 WCNSS_qcom_wlan_nv.bin
#      路径由内核 drivers/net/wireless/ath/wcn36xx/wcn36xx.h 的 WLAN_NV_FILE
#      定死为 wlan/prima/WCNSS_qcom_wlan_nv.bin。
#      来源：**persist 分区**（/dev/disk/by-partlabel/persist）根目录。
#
# modem 与 persist 都是我们从没动过的原厂分区，只要没被清掉，数据就在。
# 实测核对过：modem:/image/wcnss.* 与此前手工放进镜像的 /lib/firmware/wcnss.*
# 十个文件 md5 全部一致、且无多余文件，所以"开机现取"与"预置"完全等价。
#
# 失败一律不致命——最坏结果只是没有 WiFi，绝不能因为取不到把启动搞挂。
set -u

DEST=/lib/firmware
NV_DEST=$DEST/wlan/prima
LOG=/var/log/odin-wlan-fw.log

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

copy_from() { # copy_from <分区标签> <分区内目录> <目标目录> <文件...>
  local label=$1 subdir=$2 dest=$3; shift 3
  local dev tmp copied=0 f
  dev=$(readlink -f "/dev/disk/by-partlabel/$label" 2>/dev/null)
  if [ ! -b "$dev" ]; then
    say "$label 分区不存在，跳过"
    return 0
  fi
  tmp=$(mktemp -d) || return 0
  if ! mount -o ro "$dev" "$tmp" 2>/dev/null; then
    say "$label 挂载失败，跳过"
    rmdir "$tmp" 2>/dev/null
    return 0
  fi
  mkdir -p "$dest"
  for f in "$@"; do
    if [ -s "$tmp/$subdir/$f" ]; then
      if ! cmp -s "$tmp/$subdir/$f" "$dest/$f"; then
        cp -f "$tmp/$subdir/$f" "$dest/$f" \
          && { say "已取 $f ($(stat -c%s "$tmp/$subdir/$f") 字节) ← $label"; copied=1; }
      fi
    fi
  done
  umount "$tmp" 2>/dev/null
  rmdir "$tmp" 2>/dev/null
  return $((1 - copied))   # 拷到了就 0，没拷到就 1
}

# ---- 1) WCNSS 固件 ← modem 分区的 /image/
# 段文件列表按该机型实测所得；用通配符一次性收齐，免得哪天段号变了漏掉
FIRM_COPIED=0
copy_from modem image "$DEST" \
  wcnss.mdt wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06 \
  wcnss.b09 wcnss.b10 wcnss.b11 wcnss.b12 && FIRM_COPIED=1

# ---- 2) 板级校准数据 ← persist 分区
NV_COPIED=0
copy_from persist . "$NV_DEST" \
  WCNSS_qcom_wlan_nv.bin WCNSS_wlan_dictionary.dat && NV_COPIED=1

# ---- 3) 驱动若已先于我们加载过，那时是读不到这些文件的，重装一次让它读到。
# 判断条件收得很紧：确实刚拷了东西、且 wlan0 还不存在，才动模块。
if { [ "$FIRM_COPIED" = 1 ] || [ "$NV_COPIED" = 1 ]; } && [ ! -d /sys/class/net/wlan0 ]; then
  say "重新加载 wcn36xx 以便读取固件与 NV 数据"
  modprobe -r wcn36xx 2>/dev/null
  modprobe wcn36xx 2>/dev/null
  say "重载完成，rc=$?"
fi

exit 0
