#!/bin/bash
# ODIN Debian rootfs — QEMU aarch64 本地调试启动脚本
#
# 用途：在本地验证 rootfs 与启动链路（initramfs→findfs→switch_root→systemd），
#       以及 USB 存储软件栈（qemu-xhci + usb-storage 模拟 U 盘）。
# 不覆盖：msm8953 硬件链路（面板/GPIO/串口控制器/真机 UDC）。
#
# 端口映射：
#   ssh  localhost:2222 -> VM:22   (user/user)
#   telnet localhost:2323 -> VM:23 (initramfs 救援 shell，仅启动早期)
#
# 控制台即本终端（ttyAMA0）；退出 QEMU：Ctrl-A x
set -euo pipefail
cd "$(dirname "$0")"

DISK="${1:-rootfs.img}"

# 模拟的外挂 USB 存储设备（首次运行自动生成 64MB vfat 测试盘）
if [ ! -f usbdisk.img ]; then
    echo "[*] 生成测试用 USB 盘 usbdisk.img (64MB, FAT12/16)"
    dd if=/dev/zero of=usbdisk.img bs=1m count=64 2>/dev/null
    newfs_msdos -F 16 -v ODINUSB ./usbdisk.img >/dev/null
fi

exec qemu-system-aarch64 \
    -M virt -cpu cortex-a57 -smp 2 -m 1024 \
    -nographic \
    -kernel Image \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0 earlycon=pl011,0x9000000 root=/dev/disk/by-label/pmOS_root rootwait rw ip=10.0.2.15::10.0.2.2:255.255.255.0::eth0:off" \
    -drive file="$DISK",format=raw,if=virtio \
    -device qemu-xhci,id=xhci \
    -device usb-storage,bus=xhci.0,drive=ud0 \
    -drive if=none,id=ud0,file=usbdisk.img,format=raw \
    -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::2323-:23 \
    -device virtio-net-pci,netdev=n0 \
    -accel hvf
