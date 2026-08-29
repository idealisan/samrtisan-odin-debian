# Smartisan ODIN（坚果 Pro / U2 Pro）主线内核移植补丁集

基于原厂线刷包 `SEKSA-mol%odin-rom-4.1.0-odin-user-20180523-005028-32g` 中的
`boot.img`（内含 odin 原厂 DTB）与 `emmc_appsboot.mbn`（面板选择表），为
msm8953-mainline 内核（Linux 6.19，github.com/msm8953-mainline/linux）编写的
屏幕 + USB 外接存储移植补丁。

> **本仓库只放源码与文档。** 刷机镜像、lk2nd 固件、编译好的 DTB 与内核模块等二进制
> 产物一律不进版本库，统一作为 **GitHub Release 资产**发布，到
> [Releases](../../releases) 页面下载。仓库里留下的是"能从零重建出这些东西的全部脚本"：
> 内核补丁 → DTB 构建 → rootfs 增量 → 镜像导出 → 真机刷入。

## 一、补丁清单（odin-port/patches/0001–0008）

| # | 补丁 | 内容 |
|---|------|------|
| 1 | dt-bindings: vendor-prefixes | 新增 `smartisan` 厂商前缀 |
| 2 | usb: typec: FUSB301 | Type-C CC 控制器驱动（I2C 0x25，中断 GPIO38），输出 typec class + usb role switch |
| 3 | regulator: SMBCHG OTG | PMI8950 充电器 OTG boost 5V 稳压器（bat-if 外设 0x1200 + 寄存器 0x42 BIT0），供 host 模式 VBUS |
| 4 | drm/panel: R69006 | R69006 1080p 面板，命令模式（原厂首选）+ 视频模式两个 compatible |
| 5 | drm/panel: FT8716 | FocalTech FT8716 TDDI 1080p 视频模式面板 + Sharp 模组变体 |
| 6 | drm/panel: NT36672 | Novatek NT36672 1080p 视频模式面板 |
| 7 | arm64: dts: qcom | `msm8953-smartisan-odin.dts` 设备树 |
| 8 | drm/panel: FT8716 | **修黑屏**：把初始化序列从 `.prepare` 挪到 `.enable`——DSI 主机未上电时 `dsi_host_transfer()` 会静默返回 `-EINVAL`，在 prepare 阶段发的命令一条都不生效 |
| 3' | msm8953: oem_panel | ODIN 面板 GPIO 检测（TLMM91/92 复刻原厂）+ `fastboot oem panel` 实时切换（见 reports/009） |

所有初始化序列逐字节取自原厂 DTB（用 msm8953-mainline 官方工具
linux-mdss-dsi-panel-driver-generator 从 boot.img 的 DTB 自动生成后合并）。

## 二、多面板自动选择机制

原厂支持 5 种面板（LK 与 DTB 双重确认）：R69006 cmd/video、FT8716、
Sharp FT8716、NT36672。本补丁全部实现，无需预知具体硬件批次。

**先说结论（reports/010 已推翻早先认知）：lk2nd 从不初始化 DSI 面板。**
lk2nd 在 msm8953 上的构建形态是 `cont-splash`（`project/lk2nd.mk` 的
`LK2ND_DISPLAY ?= cont-splash`），`target_display_init()` 只做一件事——
复用上一棒 bootloader 已经画好的帧缓冲，全程零 DSI 操作。面板的识别与初始化
**全部由原厂 aboot 完成**：

```
原厂 aboot：GPIO91/92 电平 strap 检测 → DSI 初始化 → 画 splash
          └─ cmdline 携带 mdss_mdp.panel=<名字>
               ↓ 跳转
lk2nd(cont-splash)：解析上一棒 cmdline → 取到 panel.name
   → 在 Linux DTB 中把占位 compatible "smartisan,odin-panel"
     （须与 lk2nd panel 节点第一个 compatible 一致）
     替换为对应子节点的真实 compatible（如 "smartisan,odin-nt36672"）
   → 内核中相应 panel 驱动绑定，DSI/背光/供电按该面板配置工作
```

也就是说**自动识别是架构天然提供的**（aboot strap 检测 + cmdline 名字透传 + DT 替换），
三分批次（NT36672 / FT8716 / Sharp FT8716）全覆盖，移植侧不需要再写检测逻辑。

**lk2nd 侧已完整扩充**（`odin-port/lk2nd/`）：补丁 0001 的 GCDB 面板库与补丁 0003 的
GPIO 检测在 cont-splash 形态下均为**死代码**（`--gc-sections` 后不参与运行路径），
保留它们是为一/lk1st 形态（lk2nd 直刷 aboot 分区）部署时自动生效：

- `0001-msm8953-add-full-ODIN-panel-database.patch`：从原厂 DTB 生成的
  FT8716 / Sharp FT8716 / NT36672 GCDB 面板表（含完整 DCS 序列、14nm
  PHY 时序、reset 时序），并注册进 `target/msm8953/oem_panel.c`——
  加上原有的 R69006 cmd/video，5 种面板全部可用
- `0002-msm8953-add-Smartisan-ODIN-device.patch`：odin 设备描述，
  将 5 个 panel_node_id 映射到主线 compatible
- `bin/lk2nd.img` / `bin/emmc_appsboot.mbn`：已构建好的 lk2nd 固件
  （29 个 msm8953 设备 DTB，含 odin）

原厂 aboot 的检测规则（reports/009 反汇编实锤，TLMM 91/92 输入 strap）：

```
91=1 & 92=1 → NT36672
91=1 & 92=0 → FT8716
91=0        → Sharp FT8716（兜底）
```

r69006 的 cmd/video 两个变体**不在 aboot 的 strap 逻辑里**（原厂亦然）；若真存在这类
机器，原厂系统同样处理，透传出来的名字仍是 aboot 实际选择的面板名。

`fastboot oem panel <name>` 在 cont-splash 形态下只重绘帧缓冲，无法真正重初始化 DSI，
不具备救援意义。按 reports/010 §七 的定论：**信任 aboot 透传的面板名，不做任何人工
覆盖机制**（为不存在的场景设计机制，只会引入新的出错面）。

## 三、USB 外接存储链路

```
USB-C 插入 OTG/U盘 → FUSB301 CC 检测(IRQ) → role switch → HOST
  → dwc3-qcom 切 host → SMBCHG OTG boost 输出 5V VBUS
  → xHCI 枚举 → usb-storage/UAS → /dev/sda1
```

内核侧已齐备：`usb-storage=y`、`UAS=y`、`NTFS3=y`、`exfat=m`（模块，镜像内已有
`exfat.ko`，挂载时自动加载）、`vfat=y`。

**用户态已落地自动挂载（不用 udisks2）**：

```
U 盘插入 → udev(99-odin-automount.rules) → odin-automount.sh
        → odin-mount-opts.sh 按 fstype 分流选项 → systemd-mount --options=...
        → /run/media/<设备名>（systemd .mount 单元，--collect 在拔盘时自动回收）
```

> **实测教训**：bookworm 的 systemd 252 里 PID 1 **不读**任何 `SYSTEMD_MOUNT_*`
> 属性，`systemd-mount` 也**不读** `SYSTEMD_MOUNT_OPTIONS` 环境变量——
> 只认 `--options=`。所以光写 `TAG+="systemd"` 不会挂载，且选项必须走命令行。
> 详见 `reports/017` 与 `WORKLOG.md`。

关于 FAT32 中文：内核未编 `CONFIG_NLS_UTF8`（不为它重编内核模块），FAT32 默认按
`iso8859-1` 解释文件名 ⇒ **中文名会乱码**。exFAT / NTFS3 走内核内建 UTF-16 转换
（`fs/exfat/super.c:691-697`，不走 `load_nls`），中文正常。**需要中文名的盘请用
exFAT 或 NTFS。**

## 四、刷机包与用户态组件

刷机包在 `dist/`，**单一文件系统**镜像（只有 `pmOS_root`，`/boot` 与 `/extlinux`
都在根分区里，不是 pmOS 那种 pmOS_boot+pmOS_root 双分区）。刷入后 `/extlinux/extlinux.conf`
就在系统内，改完重启即可切换 —— 这一条让"双 label 救援"变得很便宜。

**双 label 引导**（两个 label 只有 DTB 不同，内核与 initrd 相同）

| label | DTB | 用途 |
|---|---|---|
| `l0-safe`（首刷默认） | `msm8953-smartisan-odin-ft8716-norolesw.dtb` | USB 固定 device，UDC 恒在，SSH 不依赖 Type-C 判定；代价：无 OTG |
| `l0` | `msm8953-smartisan-odin-ft8716.dtb` | 完整版：Type-C 角色切换 + OTG host |

用的是**面板写死 FT8716** 的那一对 DTB（`*-ft8716*`），不是自动识别版：写死之后面板
是否点亮与 lk2nd 选中哪个 QCDT 条目无关，排障面小很多。自动识别的一对也随镜像发布，
换屏后把 `fdt` 改回去即可。

```sh
sudo sed -i 's/^default .*/default l0/' /extlinux/extlinux.conf && sudo reboot
```

> `append` 行末尾的 `console=tty0` 不能删 —— 它是控制台上屏的开关。少了它屏幕只有
> 背光、没有登录提示，看起来跟"屏没点亮"一模一样。

**用户态组件的源码在 `dist/build/rootfs/`**（改这里，不要直接改 staging / 镜像内文件，
否则下次重建会丢），由 `dist/build/apply-staging-fixes.sh` 幂等部署：

| 文件 | 作用 |
|---|---|
| `etc/udev/rules.d/99-odin-automount.rules` | U 盘插入即触发自动挂载 |
| `usr/local/sbin/odin-automount.sh` | 取 fstype → 算选项 → 调 systemd-mount，任何分支 exit 0 |
| `usr/local/sbin/odin-mount-opts.sh` | 按 fstype 分流挂载选项（vfat/exfat/ntfs/POSIX 各不相同） |
| `usr/local/sbin/odin-usb-role.sh` | USB 角色切换唯一入口：幂等、先空后名、exit 0、支持 `--dry-run` |
| `etc/udev/rules.d/99-odin-usb-role.rules` | 监听 UDC add/remove 与 Type-C change |
| `etc/systemd/system/odin-usb-gadget.{service,timer}` | oneshot 服务 + 30s 自愈看门狗 |
| `extlinux/extlinux.conf` | 双 label 引导配置 |

设备树源码与构建脚本在 `dts/`：`build-dtb.sh` 一次性编出完整版与安全版两个 DTB，
并已用两个 dtc 版本（1.6.1 / 1.7.2）交叉验证过能**逐字节复现**既有产物。

## 五、已验证内容

**构建侧**
- 全量构建通过：Image（30MB）、modules、全部 DTBs（Docker arm64 本机构建）
- 新驱动 W=1 零警告；DTB 通过 dtc schema 校验（无 error/warning）
- odin DTB 反编译复核：panel@0 占位节点、fusb301@25、otg-vbus 稳压器、
  connector 图形端点接线均正确
- 安全版 DTB 自检：`usb-role-switch`=0、`usb-c-connector`=0、`dr_mode="peripheral"`

**QEMU 回归**（`odin-qemu/test-automount.sh`，见 `reports/017`）
- vfat / NTFS / ext4 三种 U 盘**自动挂载成功**，挂载选项生效，user 身份可直接写
- `systemctl --failed` = 0；两个 DTB 与双 label 配置正确落到镜像内
- ⚠️ exFAT 无法在 QEMU 验证：QEMU 用的 `odin-qemu/Image` 是另一个内核，无 exfat 支持。
  **镜像内核也跑不了 QEMU**（`.config` 无 `VIRTIO_PCI`/`VIRTIO_MMIO`）⇒ QEMU 只能验用户态

**真机（已跑起来，`reports/016`/`017`、`evidence/device-probe/STATE-DISPLAY-OK.txt`）**

- 硬件规格与 lk2nd 之后的完整启动链已摸清（9 跳）
- **屏幕点亮**：`Failed to initialize panel` = 0；DSI connector `enabled/connected`；
  背光 4095/4095；fb0 1080x1920；`console=tty0` 后控制台上屏
- **USB 网络稳定**：PC 侧自动拿到 172.16.42.2（dnsmasq 单地址池），SSH 可登录
- 面板驱动移植经逐条比对原厂 ROM 确认无误（125 条命令，前 123 条与 stock 完全一致，
  余下 2 条是 `0x11`/`0x29`，用标准 DCS API 实现）
- ⚠️ 实测 `find /sys -name role` 为空 ⇒ `echo device > /sys/class/usb_role/*/role`
  这条手动回退手段在当前内核上**不可用**

## 六、刷入与测试步骤

1. **备份**：当前可启动的 boot 分区与 postmarketOS `/boot`。
2. 刷 `lk2nd.img` → boot 分区（64M）；刷 `odin-debian-sparse.img` → userdata。
   顺序不能反（lk2nd 负责挂载 userdata 找到 `/extlinux/extlinux.conf`）。
3. **首刷默认进 `l0-safe`**：无 OTG，但 UDC 恒在，SSH 一定能拿到。
4. 拿到 SSH 后确认整机（扩容、WiFi、基带、音频、振动、按键），再把 default 改成
   `l0` 重启，验证 Type-C 角色切换与 OTG。
5. 屏幕观察顺序：panel driver 绑定 → DRM connector → fb0 → 背光。
   **屏幕能否点亮取决于 lk2nd 是否选中 odin 条目**（见 §七 已知限制第 1 条）。
6. USB 观察顺序：CC attach → role=host → VBUS 5V → 枚举 → `/run/media/sdX`。
7. 首次 USB host 测试建议用带独立供电的 hub（排除 VBUS 供电因素）。

## 七、已知限制 / 后续工作

- **【已解决】lk2nd 的 DTB 选择**：QCDT 表里 `msm8953-smartisan-odin` 的
  board-id 是 `<0x0b 0x01>`，`msm8953-xiaomi-markw` 是 `<0x1000b 0x01>`；
  `VARIANT_MASK=0xff` ⇒ 两者 **variant_id 都是 0x0b**，高位 0x10 只是 major，
  所以未精简的 lk2nd 很可能把票投给 markw。解法有两条，本包同时采用：
  - **DTB 侧**：用面板写死的 `*-ft8716*` DTB，面板是否点亮不再依赖 lk2nd 选中谁。
  - **lk2nd 侧**：发布精简版 lk2nd（去掉 markw 条目），强制命中 odin。
  - 两个 label 都用**显式 `fdt`**，绝不能用 `fdtdir`：选中 markw 时会去找镜像里
    不存在的 `msm8953-xiaomi-markw.dtb` 而启动失败。
- **面板名透传未实锤**：实测当前 pmOS 的 `/proc/cmdline` **没有** `mdss_mdp.panel=`，
  但那台机器跑的是 pmOS 的 lk2nd（无 odin 条目），不能直接推断原厂 aboot 的行为。
  需在刷入本包后查 `/proc/cmdline` 或 `fastboot getvar lk2nd:panel`。
- **USB 角色手动回退缺口**：`/sys/class/usb_role/*/role` 实测不存在（6.17.7）。
  本包的 6.19 内核上是否可用未验证；回退请优先改 `extlinux.conf` 的 default 或用 UART。
- 触摸屏（FocalTech FTS @ i2c_3, reset GPIO64/IRQ65）未包含——主线无
  FTS 驱动，属独立移植任务。
- QMP SuperSpeed PHY 主线无 msm8953 支持，先以 USB2 HighSpeed 工作
  （480Mbps 对 U 盘足够）。
- 面板 AVDD 取 pm8953_l17@2.85V、IO 取 l6@1.8V，系按原厂电压与同类
  机型推断；如首屏异常优先核对这两路。
- 内核缺 `CONFIG_FB_SIMPLE`：真机（markw DTB）上因 `90001000.framebuffer` 无驱动
  而卡住 `gcc-msm8953` 的 `sync_state()`。odin DTB 没有 `chosen/framebuffer` 节点，
  所以本包不受影响；但将来若要接 cont-splash，必须同步开这个选项。

## 八、本次已锁定的决策（用户拍板）

| # | 决策 | 选择 |
|---|---|---|
| 1 | 阶段 2（UTF-8） | **放弃 FAT32 中文，不做 `nls_utf8`**；以 exFAT / NTFS 为主力 |
| 2 | 自动挂载方案 | **systemd mount unit**（不装 udisks2） |
| 3 | 首刷策略 | **接受首刷期间没有 OTG**，`l0-safe` 作为 default |

## 九、从头刷入（原生 fastboot → SSH 可用）

刷机流程在 `flash/flash-all.sh` 一个脚本里，分成带编号的阶段，**任何阶段失败都可以
`--from <阶段>` 单独重跑**，不必从头再来：

```sh
flash/flash-all.sh                 # 从头跑（00 → 90）
flash/flash-all.sh --from 40       # 从刷 userdata 那步继续
flash/flash-all.sh --dry-run       # 只打印将执行的动作，不真刷
```

| 阶段 | 做什么 |
|---|---|
| `00 precheck` | 本机依赖、镜像是否齐全、按 Release 清单校验 SHA256、判断设备当前状态 |
| `10 backup` | 经 SSH 全量备份真机根文件系统（手机本地打包 + HTTP 拉回，可断点续传） |
| `20 fastboot` | 进入原生 fastboot |
| `30 boot` | `fastboot flash boot lk2nd-nomarkw.img` |
| `40 data` | `fastboot flash userdata odin-debian-sparse.img`（失败自动回退 raw 版） |
| `50 reboot` | `fastboot reboot`，等 PC 上出现 USB NCM 网卡 |
| `60 usbnet` | 等 PC 拿到 172.16.42.2（DHCP 优先，超时用静态地址兜底） |
| `70 ssh` | 等 22 端口可达（首启含文件系统扩容，会比较慢） |
| `80 verify` | 跑验收项：hostname / 内核 / DSI 连接 / 背光 / 面板初始化失败数 / usb0 / wlan0 / 扩容 / sshd |

公共函数在 `flash/lib/common.sh`（日志、重试、超时、SSH/fastboot 封装）。状态机与
失败循环策略见 `reports/018-真机刷入循环操作手册.md`。

> **★ 20 阶段是怎么远程进 fastboot 的**（整条流程能无人值守的关键）
> 真机上没有 adbd，`/sys/kernel/reboot/mode` 又只收 cold/warm/hard，从系统内部
> 没法直接进 fastboot。但实测证实：**lk2nd 找不到 `/extlinux/extlinux.conf` 时会
> 自动停在 fastboot**。所以脚本把配置改个名再重启，就落到 fastboot 了；刷完之后
> 新系统自带 `/extlinux/extlinux.conf`，lk2nd 正常引导。
> 若这条不通（比如 lk2nd 本身坏了），脚本会提示人工按【音量减 + 电源键】，
> 然后 `--from 30` 继续。

> **两条实测教训，写在 `common.sh` 里了**：
> 1. 大批量数据别用 `ssh cat` 直传 —— 设备端 tar 边读边往外吐会让 USB NCM stall
>    （两次都在 ~110MB 处断、设备失联 30s；纯流量压测 400MB/20s 说明不是带宽问题）。
>    先在设备本地落盘，再顺序拷贝。
> 2. `/root` 是 0700，用 `user` 身份去读会得到空结果而不是报错 —— 差点把一份完好的
>    备份判成"截断"。涉及 `/root` 一律走 `odin_sudo*`。

## 十、仓库自身的可复现性

二进制产物不入库，是为了让仓库能安全公开、也让 `.git` 保持可读大小。生成公开副本的
流程固化在脚本里：

```sh
tools/prepare-public-repo.sh /tmp/odin-clean ~/.config/odin-port/replacements.txt
```

它会剔除全部二进制与超大 blob、按规则脱敏（文件内容**和提交信息**都换），
源仓库不动。脱敏规则文件刻意放在仓库**外面**——规则里必然写着要替换掉的原串，
一旦入库就等于把想藏的东西又写回公开仓库。

工作日志见 `WORKLOG.md`（每步时间戳 + 踩坑记录 + 待清理清单）。
