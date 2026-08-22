# 实施方案 006 — ODIN Debian 刷机包（方案B：极简 initramfs + 纯 Debian 用户空间）

| 项目 | 内容 |
|------|------|
| 文档编号 | ODIN-PLAN-006 |
| 日期 | 2026-08-22 |
| 目标 | 为 Smartisan ODIN 制作 Debian (bookworm) 用户空间刷机包，复用 pmOS 骨架（主线内核+lk2nd+嵌套GPT布局），默认 user/user + sudo + USB网(172.16.42.1) + SSH + telnet 后备 |
| 构建环境 | 本机 Docker(OrbStack, arm64 原生容器)，debootstrap 无需 qemu |
| 已获批准 | 方案B；bookworm；user:user；sudo；USB网络与PMOS一致 |

---

## 一、总体架构

```
构建侧(macOS+Docker arm64)                          设备侧(ODIN)
─────────────────────────                          ─────────────
linux-msm8953 树(已编译)
 ├ Image/Image.gz ─┐
 ├ msm8953-smartisan-odin.dtb ─→ boot子分区(ext4)
 └ modules(.ko收集+depmod)      │   vmlinuz initramfs dtbs/ extlinux.conf
                                │
debootstrap bookworm ─→ root 子分区(ext4, 2GB镜像内)
                                │
组装: odin-debian.img           │
 (嵌套GPT: p1 pmOS_boot 128M    │
            p2 pmOS_root 余量) ─┘── fastboot flash userdata ──► userdata 分区
lk2nd.img(odin-port已构建) ───── fastboot flash boot ─────► boot 分区(64M)

启动链: aboot → lk2nd → 解析userdata嵌套GPT → ext2挂载pmOS_boot
        → /extlinux/extlinux.conf → 加载vmlinuz+initramfs+dtb(qcom/msm8953-smartisan-odin.dtb)
        → lk2nd DEV_TREE_UPDATE替换面板compatible → 内核 → initramfs按LABEL=pmOS_root找根
        → switch_root → systemd → [usb-gadget.service + sshd] → USB网SSH可登录
```

## 二、组件与决策表

| 组件 | 决策 | 说明 |
|------|------|------|
| 内核 | linux-msm8953 树现成产物 | 补丁0001–0007已应用并编译; config见§四核对结论 |
| DTB | msm8953-smartisan-odin.dtb | 占位compatible已修复为"smartisan,odin-panel"(报告001) |
| 模块 | 从内核树收集 .ko 保持相对路径 + depmod | panel三驱动=m 必须在rootfs里 |
| lk2nd | odin-port/lk2nd/bin/lk2nd.img | 已含odin设备+5面板库(strings验证过) |
| 引导配置 | extlinux.conf | fdtdir=/dtbs → lk2nd自动选 qcom/msm8953-smartisan-odin.dtb |
| 用户空间 | debootstrap bookworm minbase+必要包 | systemd, openssh-server, sudo, dnsmasq-base, kmod, e2fsprogs, cloud-guest-utils(growpart), busybox-static, usbutils |
| 默认账户 | user:user + sudo NOPASSWD? → 普通sudo(需密码user) | 与pmOS习惯一致但简化 |
| USB网络 | configfs NCM gadget @172.16.42.1/24 + dnsmasq给主机发172.16.42.2 | PMOS惯例完全一致 |
| SSH | openssh-server 开机自启, 密码认证允许 | |
| 后备通道① | initramfs 内 busybox telnetd :23 (root shell) | switch_root前窗口期+启动失败常驻救援 |
| 后备通道② | console=ttyMSM0,115200 + serial-getty@ttyMSM0 | UART终极后备 |
| 自动扩容 | debian-rootfs-resize.service(oneshot): growpart userdata p2 + resize2fs, 成功后systemctl disable | 方案B, 替代pmOS initramfs扩容 |
| 镜像 | odin-debian.img ~2GB + odin-debian-sparse.img(img2simg) | sparse用于fastboot大文件分块传输 |

## 三、extlinux.conf 内容设计

```
default l0
menu title ODIN Debian (mainline)
timeout 30

label l0
    kernel /vmlinuz
    initrd /initramfs
    fdtdir /dtbs
    append console=ttyMSM0,115200n8 earlycon root=/dev/disk/by-label/pmOS_root rw rootwait
```
注意:
- `fdtdir /dtbs` → lk2nd 按 `<fdtdir>/qcom/msm8953-smartisan-odin.dtb` 查找(extlinux.c:417);
  同时把dtb也放 `/msm8953-smartisan-odin.dtb`(boot-deploy会去vendor目录的约定,双保险)
- kernel 用未压缩 Image(lk2nd choose_addrs 依赖arm64 Image头部text_offset;
  gzip包虽支持但Image最稳); 若Image.gz存在优先gz减小读取量 — 以实际产物定

## 四、实施前核对结论(已完成)

1. **面板序列 vs 原厂DTB**: r69006 cmd 的 on-command 全部31条指令、off-command、
   sleep-out(120ms)/display-on(20ms)延迟、reset序列(10/10/10)、时序
   (1080×1920, HTOTAL1282 VTOTAL1947, burst, 4lane, RGB888)逐字节一致 ✓
   (ft8716/nt36672同管线生成,抽查机制相同,标注为低风险待实机验证)
2. **内核config关键项**: EXT4_FS=y, USB_CONFIGFS=y, USB_CONFIGFS_NCM=y, USB_F_NCM=y,
   DEVTMPFS_MOUNT=y, RD_GZIP=y, MMC_SDHCI_MSM=y ✓ (gadget/RNDIS/ECM也齐)
3. **引导链标识符**: 
   - lk2nd设备描述 `lk2nd,dtb-files="msm8953-smartisan-odin"` ↔ 内核dtb文件名同名 ✓
   - lk2nd.img含smartisan,odin-panel占位符与修复后dtb匹配 ✓ (001报告)
   - 分区标签pmOS_boot/pmOS_root ↔ initramfs查找逻辑 ✓ (005报告)
   - ODIN原厂GPT: boot=64M(够放lk2nd), userdata≈27G(远大于2G镜像) ✓ (005报告)

## 五、已知注意事项/风险清单

| # | 风险 | 缓解 |
|---|------|------|
| 1 | 内核补丁未经真机验证,屏幕可能不亮 | SSH-first策略: 显示失败不影响登录;串口日志兜底 |
| 2 | fastboot 对 >max-download-size 大镜像传输失败 | 提供 img2simg 稀疏版; fastboot自动分块流式传输sparse |
| 3 | lk2nd菜单音量-/电源确认问题(003报告) | 不依赖菜单: 刷入用PC端fastboot即可; 单键模式可后续加 |
| 4 | FTS触摸屏未移植 | 初期靠SSH/串口操作 |
| 5 | WLED背光参数为推断值(001报告§六) | 屏幕亮但无背光时改dts重编 |
| 6 | initramfs blkid找根依赖busybox版本 | 自带静态busybox,不依赖目标rootfs |
| 7 | OrbStack loop device权限 | 容器--privileged; 失败则回退sgdisk离线构造 |
| 8 | 首次启动扩容服务失败空间仍2G | 可SSH后手动growpart; 服务幂等可重跑 |
| 9 | telnetd无密码仅存在于switch_root前窗口 | 文档明示安全边界;系统内不开telnet |
| 10 | modem/WiFi/BT未启用 | 本阶段范围外,SSH可用即达标 |

## 六、产物清单(预期)

```
dist/
├── lk2nd.img                    ← flash boot
├── odin-debian.img              ← flash userdata (raw)
├── odin-debian-sparse.img       ← 推荐(raw过大时分块流式)
└── FLASH.md                     ← 刷入指南(007)
```

---
*方案结束 — 批准后按 §一 流程执行*

---

## 七、实施期修订:布局简化(Layout C,最终采用)

原§一嵌套GPT方案实施中简化为**单ext4直刷userdata**:

```
boot分区    ← lk2nd.img                    (不变)
userdata    ← odin-debian-rootfs.ext4      (整盘一个ext4, LABEL=pmOS_root)
              ├── /extlinux/extlinux.conf   ← lk2nd直接在此fs根找引导配置
              ├── /boot/vmlinuz|initramfs|dtbs/qcom/*.dtb
              └── /(Debian rootfs本体)
```

理由:
1. Linux不自动解析"分区里的分区表",嵌套方案需initramfs带kpartx/dmsetup+dm线性映射,复杂且易错;
2. 单ext4下lk2nd_scan_devices直接挂载userdata找到/extlinux/extlinux.conf(extlinux.c路径约定),
   initramfs按LABEL=pmOS_root一步到位;
3. 自动扩容退化为一次性 `resize2fs <rootdev>`(分区即全盘,无growpart),systemd oneshot即可;
4. fastboot仅两条命令: flash boot lk2nd.img; flash userdata rootfs.ext4(sparse)。

风险控制: lk2nd的LK-ext2驱动读默认mkfs.ext4(metadata_csum/extents)已被pmOS全系设备验证。
