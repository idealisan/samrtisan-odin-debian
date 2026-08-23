#!/bin/bash
# 完整启动验证：同步initramfs后跑75秒并抓关键行
set -u
cd "$(dirname "$0")"
cp ../dist/stage/initramfs.cpio.gz initramfs.cpio.gz
rm -f usbdisk.img
./run.sh > /tmp/qboot3.log 2>&1 &
QP=$!
sleep 75
kill "$QP" 2>/dev/null
wait "$QP" 2>/dev/null
echo "===== 关键行 ====="
grep -aE "root found|switch_root FAILED|systemd\[1\]|Reached target|Multi-User|odin-firstboot|resize2fs|sda |sda:|EXT4-fs \(sda|FAILED|panic" /tmp/qboot3.log | head -n 30
echo "===== 尾部 ====="
tail -n 12 /tmp/qboot3.log
