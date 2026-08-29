#!/bin/bash
# 临时调试：查清 SYSTEMD_MOUNT_OPTIONS 为何没被 systemd-mount 读取
set -uo pipefail
cd "$(dirname "$0")/.."
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

qemu-system-aarch64 \
	-M virt -cpu cortex-a57 -smp 2 -m 1024 -nographic \
	-kernel odin-qemu/Image -initrd odin-qemu/initramfs.cpio.gz \
	-append "console=ttyAMA0 earlycon=pl011,0x9000000 root=/dev/disk/by-label/pmOS_root rootwait rw ip=10.0.2.15::10.0.2.2:255.255.255.0::eth0:off net.ifnames=0" \
	-drive file=odin-qemu/rootfs.img,format=raw,if=virtio \
	-device qemu-xhci,id=xhci,p2=8,p3=8 \
	-device usb-storage,bus=xhci.0,drive=d0 \
	-drive if=none,id=d0,file=odin-qemu/test-vfat.img,format=raw \
	-netdev user,id=n0,hostfwd=tcp::2222-:22 \
	-device virtio-net-pci,netdev=n0 -accel hvf > /tmp/odin-debug.log 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

for i in $(seq 1 60); do
	sshpass -p user ssh $SSH_OPTS -p 2222 user@127.0.0.1 'true' 2>/dev/null && break
	sleep 2
done

sshpass -p user ssh $SSH_OPTS -p 2222 user@127.0.0.1 'bash -s' <<'EOS' 2>&1
D=/dev/sda
echo "=== A. udev 属性里有没有 SYSTEMD_MOUNT_OPTIONS ==="
udevadm info -q property -n $D 2>/dev/null | grep -iE "SYSTEMD|ID_BUS|ID_FS_TYPE" || echo "  (无 SYSTEMD_* 属性)"

echo
echo "=== B. 脚本直接执行的输出 ==="
/usr/local/sbin/odin-mount-opts.sh vfat

echo
echo "=== C. udevadm test（规则干跑，看 IMPORT 与 RUN）==="
udevadm test /sys/block/sda 2>&1 | grep -iE "odin-mount-opts|SYSTEMD_MOUNT|systemd-mount|99-odin-automount|IMPORT|RUN" | head -20

echo
echo "=== D. 用 env 显式传入再挂一次，验证 systemd-mount 是否读环境 ==="
echo user | sudo -S umount /run/media/sda 2>/dev/null
sleep 1
echo user | sudo -S env SYSTEMD_MOUNT_OPTIONS=noatime,uid=1000,gid=1000,fmask=0133,dmask=0022 \
    /usr/bin/systemd-mount --no-block --collect $D /run/media/sda 2>&1 | sed 's/^/  /'
sleep 4
mount | grep sda

echo
echo "=== E. 用 --options 显式传入再挂一次 ==="
echo user | sudo -S umount /run/media/sda 2>/dev/null
sleep 1
echo user | sudo -S /usr/bin/systemd-mount --no-block --collect \
    --options=noatime,uid=1000,gid=1000,fmask=0133,dmask=0022 $D /run/media/sda 2>&1 | sed 's/^/  /'
sleep 4
mount | grep sda

echo
echo "=== F. systemd-mount --help 里关于环境变量的说明 ==="
systemd-mount --help 2>&1 | grep -iE "SYSTEMD_MOUNT|environment" | head -10
EOS
