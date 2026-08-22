# Smartisan ODIN（坚果 Pro / U2 Pro）主线内核移植补丁集

基于原厂线刷包 `SEKSA-mol%odin-rom-4.1.0-odin-user-20180523-005028-32g` 中的
`boot.img`（内含 odin 原厂 DTB）与 `emmc_appsboot.mbn`（面板选择表），为
msm8953-mainline 内核（Linux 6.19，github.com/msm8953-mainline/linux）编写的
屏幕 + USB 外接存储移植补丁。

## 一、补丁清单（odin-port/patches/0001–0007）

| # | 补丁 | 内容 |
|---|------|------|
| 1 | dt-bindings: vendor-prefixes | 新增 `smartisan` 厂商前缀 |
| 2 | usb: typec: FUSB301 | Type-C CC 控制器驱动（I2C 0x25，中断 GPIO38），输出 typec class + usb role switch |
| 3 | regulator: SMBCHG OTG | PMI8950 充电器 OTG boost 5V 稳压器（bat-if 外设 0x1200 + 寄存器 0x42 BIT0），供 host 模式 VBUS |
| 4 | drm/panel: R69006 | R69006 1080p 面板，命令模式（原厂首选）+ 视频模式两个 compatible |
| 5 | drm/panel: FT8716 | FocalTech FT8716 TDDI 1080p 视频模式面板 + Sharp 模组变体 |
| 6 | drm/panel: NT36672 | Novatek NT36672 1080p 视频模式面板 |
| 7 | arm64: dts: qcom | `msm8953-smartisan-odin.dts` 设备树 |

所有初始化序列逐字节取自原厂 DTB（用 msm8953-mainline 官方工具
linux-mdss-dsi-panel-driver-generator 从 boot.img 的 DTB 自动生成后合并）。

## 二、多面板自动选择机制

原厂支持 5 种面板（LK 与 DTB 双重确认）：R69006 cmd/video、FT8716、
Sharp FT8716、NT36672。本补丁全部实现，无需预知具体硬件批次：

```
lk2nd 启动 → 用原厂 LK 同款面板表初始化显示并得到 panel_node_id
          （如 "qcom,mdss_dsi_r69006_1080p_cmd"）
          → 在 Linux DTB 中把占位 compatible "smartisan,odin-panel"
            （须与 lk2nd panel 节点第一个 compatible 一致）
           替换为对应子节点的真实 compatible
         → 内核中相应 panel 驱动绑定，DSI/背光/供电按该面板配置工作
```

**lk2nd 侧已完整扩充**（`odin-port/lk2nd/`）：

- `0001-msm8953-add-full-ODIN-panel-database.patch`：从原厂 DTB 生成的
  FT8716 / Sharp FT8716 / NT36672 GCDB 面板表（含完整 DCS 序列、14nm
  PHY 时序、reset 时序），并注册进 `target/msm8953/oem_panel.c`——
  加上原有的 R69006 cmd/video，5 种面板全部可用
- `0002-msm8953-add-Smartisan-ODIN-device.patch`：odin 设备描述，
  将 5 个 panel_node_id 映射到主线 compatible
- `bin/lk2nd.img` / `bin/emmc_appsboot.mbn`：已构建好的 lk2nd 固件
  （29 个 msm8953 设备 DTB，含 odin）

默认面板 = 原厂首选 R69006 cmd（与原厂 LK 行为一致）；其他批次可经
lk2nd 菜单或 `fastboot oem panel <name>` 切换（如
`fastboot oem panel ft8716_1080p_video`）。

## 三、USB 外接存储链路

```
USB-C 插入 OTG/U盘 → FUSB301 CC 检测(IRQ) → role switch → HOST
  → dwc3-qcom 切 host → SMBCHG OTG boost 输出 5V VBUS
  → xHCI 枚举 → usb-storage/UAS → /dev/sda1
```

内核侧已齐备：usb-storage=y、UAS=y、NTFS3=y（本次配置新增）、
exFAT/vfat/ext4 原有。用户态建议安装 udisks2 实现自动挂载
（console UI 默认没有）。

## 四、已验证内容

- 全量构建通过：Image（30MB）、modules、全部 DTBs（Docker arm64 本机构建）
- 新驱动 W=1 零警告；DTB 通过 dtc schema 校验（无 error/warning）
- odin DTB 反编译复核：panel@0 占位节点、fusb301@25、otg-vbus 稳压器、
  connector 图形端点接线均正确

## 五、刷入与测试步骤（概要）

1. **备份**：当前可启动的 boot 分区与 postmarketOS `/boot`。
2. **编译 lk2nd**（含 odin dts）刷入 boot 分区；postmarketOS 安装时选
   lk2nd 引导链。
3. 用打上补丁的内核替换 `linux-postmarketos-qcom-msm8953`
   （pmaports 配置片段已更新：`config-postmarketos-qcom-msm8953.aarch64`
   见本目录，新增 7 个 CONFIG）。
4. 将 `msm8953-smartisan-odin.dtb` 放入 `/boot/dtbs/qcom/`，
   extlinux/lk2nd 会自动选中（不再落到 markw）。
5. 屏幕观察顺序：panel driver 绑定 → DRM connector → fb0 → 背光；
   USB 观察顺序：CC attach → role=host → VBUS 5V → 枚举 → sdX。
6. 首次 USB host 测试建议使用带独立供电的 hub（若 OTG boost 行为
   与预期不符，可先排除 VBUS 供电因素）。

## 六、已知限制 / 后续工作

- 触摸屏（FocalTech FTS @ i2c_3, reset GPIO64/IRQ65）未包含——主线无
  FTS 驱动，属独立移植任务。
- QMP SuperSpeed PHY 主线无 msm8953 支持，先以 USB2 HighSpeed 工作
  （480Mbps 对 U 盘足够）。
- lk2nd 的面板选择沿用原厂 LK 逻辑：默认 R69006 cmd，不做 DSI ID
  自动探测（原厂 LK 同样不探测）；非默认批次用菜单/fastboot 切换。
- 面板 AVDD 取 pm8953_l17@2.85V、IO 取 l6@1.8V，系按原厂电压与同类
  机型推断；如首屏异常优先核对这两路。
