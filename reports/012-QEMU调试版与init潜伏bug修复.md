# 012 — QEMU 本地调试版与 initramfs 两个潜伏 bug 的发现修复

日期：2026-08-23　对象：`odin-qemu/`（新增）与 `dist/`（真机镜像同步修复）

## 一、交付

QEMU aarch64 调试变体（详见 `odin-qemu/README.md`）：
- 同源 staging 构建的 rootfs.img（保守 ext4 特性集）+ arm64 defconfig 内核
  （VIRTIO_NET/USB_UAS/USB_XHCI_PCI 内建，IP_PNP=y 支持 ip= 参数）
- 复用与真机完全相同的 initramfs
- run.sh：virtio-blk + qemu-xhci + usb-storage(64M FAT) + slirp hostfwd(2222→ssh,
  2323→telnet)；串口 ttyAMA0

## 二、验证结果（全部通过）

| 项 | 结果 |
|---|---|
| initramfs 找根/挂载/switch_root | ✅（修复后） |
| systemd → multi-user/graphical | ✅ |
| systemctl --failed | ✅ 0 failed |
| SSH 登录 user/user、sudo | ✅ |
| dnsmasq conf-dir/exclude 在位 | ✅ |
| **USB 外接存储软件栈** | ✅ qemu-xhci+usb-storage → sda(QEMU HARDDISK 64M,
ODINUSB vfat) → mount/ls/umount 成功 |

## 三、QEMU 揪出的两个真机级潜伏 bug（均已修复并三处同步）

1. **绝对符号链接判定失效**：init 用 `[ -x /mnt/sbin/init ]` 判根，而
   `/sbin/init → /lib/systemd/systemd` 是绝对路径链接，在 initramfs 环境解析到
   initramfs 自身 ⇒ 永远失败。改为判定 `/mnt/usr/lib/systemd/systemd`。
2. **成功路径误卸载**：找到根后仍无条件执行 `umount /mnt` 再 switch_root，
   导致 switch_root 收到非挂载点而 usage 报错 + PID1 panic。已删除该行。
3. 连带修正：fallback 扫描加入 `/dev/vd[a-z]`；补 enable systemd-udev* 四单元
   （此前 udev 未使能导致 dev-xxx.device 超时）；补装 dbus（用户级 systemctl 可用）；
   修 /etc/hosts 缺失 `127.0.1.1 odin` 行的 setup-rootfs.sh sed 短路问题。

## 四、方法论记录

- 宿主网络不稳定 ⇒ 所有长任务一律容器内 detached（`docker exec -d`）+ 日志轮询；
  QEMU 用 `-daemonize -serial file:` 或 chardev socket 脱离会话运行。
- 交互式取证优先级：rdinit=/bin/sh 受 stdin 时序限制不可靠；
  `init=/bin/sh`(rootfs) 与 socket-chardev 串口为可靠手段。
- Docker 提供方为 **OrbStack**（docker context orbstack），异常时重启 OrbStack 即可。

## 五、对刷机的意义

两个 init bug 若未在此阶段发现，真机首刷将卡死在 initramfs（无任何登录通道，
仅 telnet 短窗口）。当前 dist/ 三件（lk2nd.img 不变、odin-debian.raw/sparse 含全部
修复）已具备实机刷写条件；剩余不确定项仅剩 lk2nd↔userdata ext4 兼容性的最终实证。
