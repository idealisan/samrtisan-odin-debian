# 037 — USB OTG 调研：角色切换为什么不动，要补什么

日期：2026-09-05　状态：**纯调研，未改任何代码**

目标（用户原话）：「自动识别 USB 接的东西，然后自动切换状态。如果 USB 接的是存储设备，
就自动切换到 OTG 模式；如果是接的电脑，就自动切换到 USB 网卡模式。」

也就是标准的 USB 双角色（Dual-Role）自动协商 —— **根据连上来的东西决定自己当 host 还是 device**。

---

## 一、结论速览

**已经具备的（不用改）**

| 组件 | 证据 |
|---|---|
| dwc3 双角色 | `CONFIG_USB_DWC3=y`、`CONFIG_USB_DWC3_QCOM=y`、`CONFIG_USB_DWC3_DUAL_ROLE=y`；设备树 `dr_mode = "otg"` |
| 角色切换框架 | `/sys/class/usb_role/7000000.usb-role-switch/role` 存在且**可读写**（当前 `device`） |
| xhci host 控制器 | `CONFIG_USB_XHCI_HCD=y`、`CONFIG_USB_XHCI_PLATFORM=y` |
| USB 存储 | `CONFIG_USB_STORAGE=y` |
| USB 以太网卡驱动 | 模块齐全：`usbnet` `ax88179_178a` `smsc95xx` `smsc75xx` `dm9601` `cdc_ether` 等 |
| 充电芯片驱动 | `CONFIG_CHARGER_QCOM_SMBCHG=y` 内建；`/sys/class/power_supply/qcom-smbchg-usb` 存在（probe 成功） |
| OTG 5V 输出 | 设备树 `&pmi8950_smbcharger { otg-vbus { regulator-name = "smbcharger-otg-vbus"; } }` |
| 角色切换的软件连线 | `&pmi8950_smbcharger { usb-role-switch = <&usb3>; }` |

**缺的 / 有风险的**

| 项 | 说明 |
|---|---|
| **FUSB301 驱动** | 主线内核**没有**这个驱动；设备树节点在（`1-0025`，modalias `fcs,fusb301`）但 `driver` 为空，没绑定 |
| **GPIO 33（USB 通路开关）** | 原厂私有属性 `qcom,usb_switch_asel`，主线没建模 |
| FUSB301 的 compatible 写法 | 原厂写 `fc,fusb301`，我们的设备树写 `fcs,fusb301` |
| 调试工具 | 没有 `lsusb`（usbutils）、`i2cdetect`（i2c-tools）、`gpiod` |

**最关键的空白：从来没人在真机上插过 OTG 设备，不知道硬件通路到底通不通。**

---

## 二、角色切换的三条路，两条走不通

### 路径 A：PMIC 的 Type-C 检测 —— **走不通**

主线有 `drivers/usb/typec/tcpm/qcom/qcom_pmic_typec.c`（`CONFIG_TYPEC_QCOM_PMIC=m`，
模块 `qcom_pmic_tcpm.ko` 已编出）。但它的兼容列表只有：

```c
{ .compatible = "qcom,pm8150b-typec", ... }
{ .compatible = "qcom,pmi632-typec",  ... }
/* 另有 pm6150 / pm7250b → pm8150b，pm4125 → pmi632 两种 fallback */
```

**我们的 PMIC 是 PMI8950，不在列表里。** 这条路没有可用的硬件抽象。

### 路径 B：FUSB301（板载 USB-C 控制器）—— **主线无驱动，要自己写**

原厂（安卓内核）有完整实现：

- 驱动源码：`ext/smartisan-kernel/drivers/misc/fusb301.c`（**1973 行**）
- 设备树：`ext/smartisan-kernel/arch/arm64/boot/dts/qcom/u3-p1-msm8953-charging.dtsi`

```dts
&i2c_6 {
        fusb301@25 {
                compatible = "fc,fusb301";          // 注意：原厂是 fc,
                reg = <0x25>;
                fusb301,int-gpio = <&tlmm 38 0>;
                fusb301,init-mode = /bits/ 8 <0x20>;
                fusb301,host-current = /bits/ 8 <1>;
                fusb301,use-try-snk-emulation;
                qcom,usb_switch_asel = <&tlmm 33 0>;   // ← USB 通路开关
                qcom,cdc_hsdet_l     = <&tlmm 25 0>;
                pinctrl-names = "default";
                pinctrl-0 = <&usbc_int_default &usb_switch_default &hs_det_default>;
        };
};
```

但它是**下游驱动**：包含 `<linux/usb/class-dual-role.h>`（主线已移除）、
用 `power_supply` 通知、`fusb301,xxx` 私有属性 —— **不能直接搬**，要按主线框架重写。

**主线有很合适的模板**：`drivers/usb/typec/wusb3801.c`（**435 行**）。WUSB3801 也是同类
的简单 CC 逻辑芯片，用的是主线 API：

```c
#include <linux/usb/typec.h>
...
wusb3801->port = typec_register_port(dev, &wusb3801->cap);
fwnode_property_read_string(connector, "typec-power-opmode", &cap_str);
```

设备树结构是 `芯片节点 { connector { ... } }`，跟我们现有 DTS 里的 `fusb301 { connector {...} }`
已经一致 —— **我们的设备树当时就是照这个模式写的**。

### 路径 C：extcon-usb-gpio 之类 —— **无硬件基础**

`CONFIG_EXTCON_USB_GPIO=y` 虽然编了，但它是给 **micro-USB 的 ID 脚**用的。
这台机器是 **USB-C**，靠 **CC 脚**协商，没有 ID 脚。

---

## 三、最可能卡住的地方：GPIO 33

原厂设备树里这行：

```dts
qcom,usb_switch_asel = <&tlmm 33 0>;
```

对照我们设备树（补丁 0007）里当时的注释：

> GPIO 33 是**物理的 USB 通路开关选择脚** —— 如果实测发现 OTG 仍然不通（比如 VBUS 出了但
> 数据不通），第一嫌疑就是这根脚没人拉，需要再加一个 gpio-hog 或 fixed-regulator 去控。

也就是说：**即使角色切换和 5V 供电都成了，数据线还得靠 GPIO 33 把物理通路扳到正确一侧。**
这是这个专题最可能踩的坑。

---

## 四、我们设备树里已有的相关设计（补丁 0007 的注释）

```
&i2c_6 { fusb301@25 { compatible = "fcs,fusb301"; ... connector { compatible = "usb-c-connector"; }; }; };
&pmi8950_smbcharger { usb-role-switch = <&usb3>; otg-vbus { ... }; };
```

注释里还留了两条当时的判断：

1. `ports/port@0` **故意不接 remote-endpoint** —— 因为 `msm8953-smartisan-odin-norolesw.dts`
   会对 `&usb3` 做 `/delete-node/ ports;`，若在共享基础 DTS 里引用 `usb_dwc3_hs`，安全版会
   **编不过**（已实测复现）。
2. 「⚠️ 待真机验证：FUSB301 与 pmi8950_smbcharger 都可能提供角色切换，需要确认最终生效的是
   哪一个。若角色切换异常，先试把 connector 上的 `usb-role-switch` 去掉（保留 smbchg → usb3 那条）。」

现在实测看到的是：`role` 停在 `device`，**两个都没生效真正触发切换**。

---

## 五、建议的推进顺序

**阶段 0（低风险，可先做）**
- rootfs 里加装调试工具：`usbutils`（lsusb）、`i2c-tools`、`gpiod`
- 顺手把 `lsmod | grep usb`、插拔前后的 dmesg 差异都留下来

**阶段 1（关键，必须先做）—— 手动切角色，看硬件通路通不通**
```
echo host > /sys/class/usb_role/7000000.usb-role-switch/role
```
然后逐项看：
- xhci 有没有起来（dmesg 里有没有 `xhci-hcd`）
- `lsusb` 能不能枚举到设备
- VBUS 有没有 5V
- **数据通不通**（这一步会暴露 GPIO 33 的问题）

> ⚠️ 这一步会占用 USB 口，usb0 网卡会消失、SSH 会断。要么先连上 WiFi 再测，
> 要么把命令和日志落盘、拔掉后回来看。（用户已决定：**WiFi 的事等这一轮调研完再说**。）

**阶段 2 —— 写主线版 FUSB301 驱动**
- 参考 `wusb3801.c`（435 行），用 `typec_register_port()` / `usb_role_switch` 主线 API
- 从原厂 `fusb301.c` 抄寄存器定义与状态机
- 同时把 GPIO 33 的通路开关接进去（pinctrl 或 gpio desc）
- 补设备树绑定文档

**阶段 3 —— 用户态自动化**
- U 盘：udev + systemd automount
- USB 网卡：NetworkManager 接管；角色由内核/驱动决定，用户态只管网络

---

## 六、调研过程中记下的几个坑

1. **设备树字符串带 NUL**：`cat /proc/device-tree/chosen/lk2nd,version` 输出 `23.1-odin\0`，
   会把后面 `echo` 的内容吞掉，表现为"命令没输出"。要用 `tr '\0' '\n' < 文件`。
2. **区分两种 fastboot 不能看 `version`/`product`/`kernel`**（lk2nd 复用 aboot 的 fastboot
   代码，这几个值一样）。要看 `partition-size:lk2nd`（lk2nd 自己的会导出 `0x80000`）。
3. `dmesg` 缓冲会被冲掉，看不到早期消息时用 `/proc/config.gz` 或查 sysfs 反推驱动 probe 状态
   （比如 `qcom-smbchg-usb` 这个 psy 存在 ⇒ smbchg 驱动 probe 成功）。
