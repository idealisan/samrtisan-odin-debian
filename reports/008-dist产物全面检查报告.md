# 008 — dist 刷机产物全面检查报告

日期：2026-08-22　对象：`odin-port/dist`（lk2nd.img / odin-debian.img / odin-debian-sparse.img / stage/*）
方法：bootimg 解析、DTB 反编译比对原厂、ext4 debugfs 深检、模块全量比对、sparse 解包比对。

## 总体结论

启动链路端到端自洽，未发现刷入后无法启动的致命缺陷。发现 1 个产物一致性问题与若干文档/细节问题。

## 已验证通过

1. **lk2nd.img**：Android bootimg 合法（kernel@0x80008000、tags@0x80000100、page2048）；
   内嵌 29 个设备 DTB；odin DTB 的 `msm-id=<0x125 0>`/`board-id=<0x0b 0x01>` 与原厂 boot.img
   反编译结果逐字一致；5 面板→主线 compatible 映射完整；含 ext4+extlinux(fdtdir) 支持。
2. **odin-debian.img**：bare-ext4 干净卷 `pmOS_root`；`/extlinux/extlinux.conf` 位于 lk2nd
   扫描路径；kernel/initrd/dtb 路径全部存在且 vmlinuz 为真 arm64 Image（magic ARMd64），
   版本 6.19.0-postmarketos-qcom-msm8953 与模块目录一致。
3. **启动关键驱动全部内建**：EXT4、SDHCI_MSM/MMC_BLOCK、PINCTRL/GCC8953、DEVTMPFS(+MOUNT)、
   INITRD+GZIP、DWC3_QCOM、CONFIGFS、F_NCM、LIBCOMPOSITE、TYPEC_FUSB301、SMBCHG_OTG。
4. **模块 517 个**：vermagic 一致；stage/ 与镜像内集合逐路径完全相同；depmod 元数据齐全；
   面板驱动 of_match 与 lk2nd 替换值一一对应（r69006×2、ft8716×2 含 sharp、nt36672×1）。
5. **initramfs**：aarch64 静态 busybox，所需 applet 齐（findfs/telnetd/ip/mdev/switch_root…）；
   init 逻辑健全；switch_root 目标存在。
6. **rootfs 服务链**：ssh/serial-getty@ttyMSM0/usb-gadget/firstboot-resize 均 enabled；
   SSH 主机密钥已生成；user 在 sudo 组；dnsmasq/cloud-guest-utils/e2fsprogs 等包齐备。
7. **DTS 关键节点**：otg-vbus reg=0x1200@5V；fusb301@25 IRQ=GPIO38；vddio=l6@1.8V、vdd=l17@2.85V；
   connector 端点接线正确。

## 问题清单

| # | 级别 | 问题 | 处置决定 |
|---|------|------|----------|
| P1 | 低 | raw 与 sparse 有 9 个 4K 块差异（superblock mnt 计数/mtime + jbd2 日志块），系 sparse 导出后 raw 又被 rw 挂载过 | 备案不改；重建镜像时自然消除 |
| P2 | 中 | README 宣称的 `fastboot oem panel` 与菜单切换面板在固件中均不存在；无自动识别 | 正解=实现 read-id 自动探测（原厂 LK 含 "Read ID cmd status failed"，具备 DSI RX 能力）；顺带补 `oem panel` 救援命令；文档更正 |
| P3 | 中 | extlinux.conf `earlycon=qcom_geni,0x78b0000` 驱动名/地址双错（实串口 uartdm@78af000） | 改为 `earlycon=msm_serial_dm,0x78af000` |
| P4 | 中 | initramfs 无 /dev/console、/dev/null → initramfs 阶段串口无回显 | 补节点重打包 |
| P5a | 低 | FLASH.md 救援示例用 blkid 但 busybox 未编译该 applet | 文档改 findfs |
| P5b | 中 | /lib/firmware 为空 → WiFi/BT（WCN36XX=m）无固件不可用（不影响启动，系统不崩） | 放入 wcnss.mdt+bXX 至 /lib/firmware/（驱动默认名 qcom_wcnss.c:35） |
| P5c | 低 | dnsmasq.service（系统实例）与 gadget dnsmasq 潜在抢绑 usb0 | 方案A：/etc/dnsmasq.d/zz-gadget-exclude.conf 写 except-interface=usb0 + bind-dynamic，双实例共存 |
| P5d | 信息 | lk2nd.img 尾部 dtb 区残留 potter/r04 无关 DTB（上游 mkbootimg 遗留，运行时不用） | 备案不动 |

## pmOS 原版对照（DNS 决策依据）

pmOS 无系统级 dnsmasq.service：gadget 默认 DHCP 用 unudhcpd，DNS 仅在 NM shared 模式按需拉起。
故本 Debian 镜像的 dnsmasq.service 属超出基线的额外物；方案 A 通过 except-interface 隔离保留两者能力。

## 工具

- `tools/parse_bootimg.py` — bootimg 头解析 + 内嵌 FDT 提取
- `tools/check_sparse.py` — sparse 解包并与 raw 全量比对（当前输出 9 块差异，见 P1）
