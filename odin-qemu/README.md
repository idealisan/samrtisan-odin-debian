# ODIN Debian rootfs — QEMU 本地调试版

与真机镜像**同一份 staging** 构建的 QEMU aarch64 调试变体，用于验证 rootfs 与
软件层启动链；不覆盖 msm8953 硬件链路（面板/GPIO/串口控制器/真机 UDC）。

## 文件

| 文件 | 说明 |
|---|---|
| `rootfs.img` | ext4 根文件系统（同真机保守特性集，卷标 pmOS_root） |
| `Image` | 同源 6.19 内核，arm64 defconfig + VIRTIO_NET/USB_UAS 内建 |
| `initramfs.cpio.gz` | 与真机完全相同的 initramfs |
| `run.sh` | 一键启动（自动生成 usbdisk.img 测试 U 盘） |
| `diag.exp` / `verify-boot.sh` | SSH 诊断脚本 / 启动冒烟脚本 |

## 使用

```sh
brew install qemu expect   # 如未安装
./run.sh                   # 前台运行，串口即本终端；Ctrl-A x 退出
# 另开终端：
../odin-qemu/diag.exp      # SSH 进 VM 跑诊断（端口 2222→22, user/user）
telnet localhost 2323      # initramfs 阶段救援 shell（仅启动早期窗口）
```

内核 cmdline 已带 `ip=10.0.2.15::...:eth0:off`（注意设备名必须是 eth0，
udev 改名前的内核名），slirp 网络下 hostfwd 提供 ssh/telnet。

## 与真机镜像的差异

1. 内核为 defconfig virt 变体（非 msm8953 配置）；模块树两套并存于
   `/usr/lib/modules/`
2. 串口 ttyAMA0（已 enable serial-getty@ttyAMA0；真机为 ttyMSM0）
3. `odin-usb-gadget.service` 被 mask（QEMU 无 UDC）
4. 其余（用户、dbus、dnsmasq、resize、标记文件、fstab 约定）与真机一致

## 已在本环境验证过的事项

- initramfs 全流程：findfs LABEL → ro 挂载 → switch_root（见 reports/012：
  此环节曾揪出两个真机同样会踩的 init 潜伏 bug）
- systemd 到达 multi-user/graphical，`--failed` 为 0
- SSH 登录（user/user）、sudo 可用
- **USB 外接存储软件栈**：qemu-xhci + usb-storage → sda 识别（QEMU HARDDISK
  64M, LABEL=ODINUSB）→ `mount -t vfat /dev/sda` 成功读写卸载
- dnsmasq conf-dir/exclude 配置在位；firstboot-resize 服务随盘存在

## 维护

修改 rootfs 后的重建配方（容器 odin-build 内）：

```sh
# staging: /mnt/debian-qemu （真机为 /mnt/debian）
truncate -s $((296572*4096)) qemu-rootfs.img
mke2fs -q -F -t ext4 -L pmOS_root \
  -O ^extents,^64bit,^metadata_csum,^huge_file,^dir_nlink,^extra_isize,^resize_inode \
  -I 256 -b 4096 -d /mnt/debian-qemu qemu-rootfs.img 296572
```

内核重编：容器内 `make O=/mnt/img/linux-build ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu- -j8`（源树 /mnt/img/linux-src）。
