#!/bin/bash
# ODIN — QEMU 自动挂载回归测试
#
# 用法: odin-qemu/test-automount.sh
#
# 启动一个带 4 个 USB 存储设备（vfat / exfat / ntfs / ext4）的 QEMU 实例，
# 经 hostfwd 的 2222 端口登录执行诊断，判定：
#   1. udev 是否为这些设备打上 ID_BUS=usb
#   2. 自动挂载规则是否生效（/run/media 下出现挂载点）
#   3. 各文件系统能否读写，挂载选项是否符合 odin-mount-opts.sh 的分流
#   4. systemd 有无 failed 单元
#
# 说明：测试盘是 superfloppy（无分区表），因此同时验证了"无分区表的 U 盘"这一
# 真实场景。成品规则对有分区表的盘同样适用（ID_FS_USAGE=filesystem 的分区）。
set -uo pipefail
cd "$(dirname "$0")"

QEMU_LOG=/tmp/odin-qemu-automount.log
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

for f in test-vfat.img test-exfat.img test-ntfs.img test-ext4.img; do
	[ -f "$f" ] || { echo "缺少测试盘 $f，先跑 test-automount.sh 的造盘步骤"; exit 1; }
done

echo "[*] 启动 QEMU（4 个 USB 盘），控制台 -> $QEMU_LOG"
qemu-system-aarch64 \
	-M virt -cpu cortex-a57 -smp 2 -m 1024 \
	-nographic \
	-kernel Image \
	-initrd initramfs.cpio.gz \
	-append "console=ttyAMA0 earlycon=pl011,0x9000000 root=/dev/disk/by-label/pmOS_root rootwait rw ip=10.0.2.15::10.0.2.2:255.255.255.0::eth0:off net.ifnames=0" \
	-drive file=rootfs.img,format=raw,if=virtio \
	-device qemu-xhci,id=xhci,p2=8,p3=8 \
	-device usb-storage,bus=xhci.0,drive=d0 \
	-device usb-storage,bus=xhci.0,drive=d1 \
	-device usb-storage,bus=xhci.0,drive=d2 \
	-device usb-storage,bus=xhci.0,drive=d3 \
	-drive if=none,id=d0,file=test-vfat.img,format=raw \
	-drive if=none,id=d1,file=test-exfat.img,format=raw \
	-drive if=none,id=d2,file=test-ntfs.img,format=raw \
	-drive if=none,id=d3,file=test-ext4.img,format=raw \
	-netdev user,id=n0,hostfwd=tcp::2222-:22 \
	-device virtio-net-pci,netdev=n0 \
	-accel hvf > "$QEMU_LOG" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null; wait $QPID 2>/dev/null' EXIT

echo "[*] 等待 SSH（最长 180s）"
for i in $(seq 1 90); do
	if sshpass -p user ssh $SSH_OPTS -p 2222 user@127.0.0.1 'true' 2>/dev/null; then
		echo "[*] SSH 就绪（${i}0 秒内）"
		break
	fi
	sleep 2
done

sshpass -p user ssh $SSH_OPTS -p 2222 user@127.0.0.1 'true' 2>/dev/null || {
	echo "[ERR] SSH 连不上，控制台尾部："; tail -30 "$QEMU_LOG"; exit 1
}

echo
echo "=================== 诊断输出 ==================="
sshpass -p user ssh $SSH_OPTS -p 2222 user@127.0.0.1 'bash -s' <<'EOS' 2>&1
echo "--- 1. 块设备 ---"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null

echo
echo "--- 2. udev 属性（每个 sd* 的 ID_BUS / ID_FS_TYPE / ID_FS_USAGE / 分区号）---"
for d in /dev/sd*; do
  case "$d" in *[0-9]) continue;; esac   # 只看整盘
  [ -b "$d" ] || continue
  printf "%-10s " "$d"
  udevadm info -q property -n "$d" 2>/dev/null \
    | grep -E "^(ID_BUS|ID_FS_TYPE|ID_FS_USAGE|ID_PART_ENTRY_NUMBER)=" \
    | tr '\n' ' '
  echo
done

echo
echo "--- 3. /run/media 挂载情况 ---"
ls -l /run/media/ 2>&1
echo "--- mount 表里带 media 的 ---"
mount | grep -E "media" || echo "  (无)"

echo
echo "--- 4. odin-mount-opts.sh 分流自检（纯选项字符串）---"
for t in vfat exfat ntfs3 ntfs ext4 btrfs xfs f2fs; do
  printf "  %-6s -> %s\n" "$t" "$(/usr/local/sbin/odin-mount-opts.sh $t)"
done

echo
echo "--- 4b. 自动挂载日志 ---"
cat /var/log/odin-automount.log 2>/dev/null | tail -10 || echo "  (无日志)"

echo
echo "--- 4c. 用户可写性验证（uid/gid 选项是否真的生效）---"
for m in /run/media/sd*; do
  [ -d "$m" ] || continue
  printf "  %-18s " "$m"
  if touch "$m/.odin-write-test" 2>/dev/null; then
    owner=$(stat -c "%u:%g" "$m/.odin-write-test" 2>/dev/null)
    rm -f "$m/.odin-write-test" 2>/dev/null
    echo "可写 (文件属主 uid:gid=$owner)"
  else
    echo "不可写（需 sudo，POSIX 文件系统预期如此）"
  fi
done

echo
echo "--- 5. 手工补齐（若某盘未自动挂载，用 root 复现）---"
for d in /dev/sd*; do
  case "$d" in *[0-9]) continue;; esac
  [ -b "$d" ] || continue
  bus=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_BUS=//p')
  usage=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_FS_USAGE=//p')
  fstype=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_FS_TYPE=//p')
  [ "$bus" = "usb" ] && [ "$usage" = "filesystem" ] || continue
  name=$(basename "$d")
  mountpoint -q "/run/media/$name" && { echo "  $d 已挂载，跳过"; continue; }
  OPTS=$(/usr/local/sbin/odin-mount-opts.sh "$fstype")
  echo "  [root] systemd-mount $d -> /run/media/$name  [opts=$OPTS]"
  echo user | sudo -S /usr/local/sbin/odin-automount.sh "$d" "$name" 2>&1 | sed 's/^/    /'
done
sleep 4
echo "  --- 复现后 ---"
mount | grep media || echo "  (仍无挂载)"

echo
echo "--- 6. exfat / ntfs 内核模块状态 ---"
lsmod | grep -iE "exfat|ntfs|nls" || echo "  (无 exfat/ntfs/nls 模块加载)"
echo "  内核是否内建 exfat: $(grep -qw exfat /proc/filesystems && echo yes || echo no)"
echo "  内核是否内建 ntfs3: $(grep -qw ntfs3 /proc/filesystems && echo yes || echo no)"

echo
echo "--- 7. failed 单元 ---"
systemctl --no-pager --failed 2>&1 | tail -5

echo
echo "--- 9. 引导配置与角色脚本 ---"
echo "  extlinux.conf 有效行："
grep -vE "^#|^$" /extlinux/extlinux.conf 2>/dev/null | sed 's/^/    /'
echo "  DTB 文件："
ls -l /boot/dtbs/qcom/*.dtb 2>/dev/null | awk '{print "    "$5, $9}'
echo "  角色脚本（无 UDC / 无 typec 时应秒退）："
/usr/bin/time -f "    耗时 %es" /usr/local/sbin/odin-usb-role.sh 2>&1 | tail -2
echo "  角色脚本日志："
tail -2 /var/log/odin-usb-role.log 2>/dev/null | sed 's/^/    /' || echo "    (无日志)"
echo
echo "--- 10. usb0 / NM 状态 ---"
ip -4 addr show usb0 2>&1 | head -3 || echo "  无 usb0"
nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | head -5
EOS

echo "================================================"
echo "[*] QEMU PID=$QPID (脚本结束自动终止)"
