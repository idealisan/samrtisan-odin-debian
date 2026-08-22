# 检查报告 002 — lk2nd / 主线内核按键映射与原厂 ROM 匹配性

| 项目 | 内容 |
|------|------|
| 报告编号 | ODIN-CHK-002 |
| 检查日期 | 2026-08-22 |
| 检查对象 | Smartisan ODIN（坚果 Pro / U2 Pro）音量键 / 电源键 / Home 键映射三方一致性 |
| 比对基准 | 原厂线刷包 boot.img 内置 DTB（权威硬件接线依据） |
| 检查方式 | 只读静态检查：原厂 boot.img FDT 提取反编译 + 主线 DTS 审阅 + lk2nd 源码/设备描述审阅 |
| 结论 | **音量+、电源键匹配；音量−不匹配（关键）；Home 键主线缺失** |

---

## 一、检查方法与证据来源

### 1.1 原厂 ROM（基准）
从原厂线刷包提取：
```
Pro_user_V4.2.5/SEKSA-mol%odin-rom-4.1.0-odin-user-20180523-005028-32g/boot.img
```
解析 Android boot 头（page_size=2048, kernel@0x800, size 9360878），在 kernel 尾部
`@0x8af448` 处 carve 出唯一 FDT blob（256422 字节），dtc 反编译后读取按键节点。

### 1.2 主线内核侧
- `linux-msm8953/arch/arm64/boot/dts/qcom/msm8953-smartisan-odin.dts`
- `linux-msm8953/arch/arm64/boot/dts/qcom/pm8953.dtsi`

### 1.3 lk2nd 侧
- 设备描述：`odin-port/lk2nd/msm8953-smartisan-odin.dts`（= 补丁 0002）
- 键位机制源码：`refs/lk2nd/lk2nd/device/keys.c`、`refs/lk2nd/target/msm8953/init.c`、
  `refs/lk2nd/dev/pmic/pm8x41/pm8x41.c`
- 预构建固件：`odin-port/lk2nd/bin/lk2nd.img`

---

## 二、原厂 ROM 权威按键接线（boot.img DTB 反编译）

### 2.1 gpio_keys 节点（tlmm = phandle 0xbe = pinctrl@1000000）

```dts
gpio_keys {
    compatible = "gpio-keys";
    vol_up {
        label = "volume_up";
        gpios = <&tlmm 0x55 0x01>;        /* GPIO 85, ACTIVE_LOW */
        linux,code = <0x73>;               /* 115 KEY_VOLUMEUP   */
        debounce-interval = <0x0f>;
    };
    vol_down {
        label = "volume_down";
        gpios = <&tlmm 0x56 0x01>;        /* GPIO 86, ACTIVE_LOW */
        linux,code = <0x72>;               /* 114 KEY_VOLUMEDOWN */
        debounce-interval = <0x0f>;
    };
    key_home {
        label = "key_home";
        gpios = <&tlmm 0x57 0x01>;        /* GPIO 87, ACTIVE_LOW */
        linux,code = <0x66>;               /* 102 KEY_HOME       */
        gpio-key,wakeup;
        debounce-interval = <0x0f>;
    };
};
/* 配套 pinctrl: gpio85/gpio86/gpio87, function=gpio,
   drive-strength=2, bias-pull-up（active/suspend 两态相同）*/
```

### 2.2 PON 节点（qpnp-power-on@800）

```dts
qcom,power-on@800 {
    interrupts = kpdpwr, resin, resin-bark, kpdpwr-resin-bark;
    qcom,pon_1 { qcom,pon-type = <0x00>; /* KPDPWR 电源键 */
                 linux,code = <0x74>; }  /* 116 KEY_POWER   */
    qcom,pon_2 { qcom,pon-type = <0x01>; /* RESIN           */
                 linux,code = <0x72>;
                 status = "disable"; }   /* ★ RESIN 输入被禁用 */
};
```

**原厂事实**：
1. 音量+ = GPIO85（低有效），音量− = **GPIO86**（低有效），Home = GPIO87（低有效，可唤醒）；
2. **PMIC RESIN 未用作音量−输入**（pon_2 显式 `status="disable"`）；
3. 电源键 = PON KPDPWR → KEY_POWER。

---

## 三、主线内核侧现状

### 3.1 msm8953-smartisan-odin.dts

```dts
gpio-keys {
    key-volume-up { gpios = <&tlmm 85 GPIO_ACTIVE_LOW>; linux,code = <KEY_VOLUMEUP>; };
    /* 仅此一个按键 */
};
...
&pm8953_resin { linux,code = <KEY_VOLUMEDOWN>; status = "okay"; };
```

### 3.2 pm8953.dtsi（公共部分）

- `pwrkey`：KEY_POWER，EDGE_BOTH，pull-up ✅（与原厂 pon_1 一致）
- `resin`：默认 `status = "disabled"`，被 odin.dts 打开并映射为 VOLUMEDOWN

---

## 四、lk2nd 侧现状

### 4.1 设备描述（odin-port/lk2nd/msm8953-smartisan-odin.dts）
**未定义 `gpio-keys` 覆盖节点** → `lk2nd/device/keys.c` 回退到 msm8953 目标硬编码默认：

| 键 | lk2nd 硬编码来源 | 实际检测对象 |
|----|------------------|--------------|
| KEY_VOLUMEUP | `target/msm8953/init.c:76` `TLMM_VOL_UP_BTN_GPIO 85`（上拉输入，按下读低电平） | GPIO85 ✅ |
| KEY_VOLUMEDOWN | `init.c:324–329` → `pm8x41_resin_status()` | **PMIC RESIN** ❌ |
| KEY_POWER | `keys.c:27–34` → `pm8x41_get_pwrkey_is_pressed()`（PON KPDPWR 实时状态） | 电源键 ✅ |

### 4.2 键的用途（与匹配性相关的行为）
- 开机组合（aboot.c:5584–5598）：VOLUP 单独按 → recovery；VOLDOWN/HOME/BACK → fastboot；
  VOLUP+VOLDOWN → EDL（9008）。
- lk2nd 屏幕菜单导航：VOLUP/DOWN 移动选择、POWER 确认（menu.c:262–283）。
- 电源键开机原因判定 `target_is_pwrkey_pon_reason()`（KPDPWR_N cold boot）与原厂 LK 同逻辑 ✅。
- lk2nd 的 DT 键位覆盖只作用于其自身固件（keys.c 解析自己设备 DTB 的 `gpio-keys` +
  `lk2nd,code`），不会改写传给 Linux 的 DTB——Linux 侧按键完全由主线 DTS 决定。

---

## 五、三方比对结果

| 按键 | 原厂 boot.img DTB | 主线 odin.dts | lk2nd 当前 odin 描述 | 匹配判定 |
|------|-------------------|---------------|----------------------|----------|
| 音量+ | GPIO85 低有效 → KEY_VOLUMEUP，debounce 15ms | GPIO85 低有效 → VOLUMEUP（无 debounce） | 硬编码 TLMM85 → VOLUMEUP | ✅ 匹配 |
| 电源 | PON KPDPWR → KEY_POWER | pwrkey → KEY_POWER | KPDPWR 实时状态 | ✅ 匹配 |
| 音量− | **GPIO86 低有效** → VOLUMEDOWN；RESIN 输入禁用 | **PMIC RESIN** → VOLUMEDOWN（enabled） | 硬编码 **RESIN** → VOLUMEDOWN | ❌ **不匹配** |
| Home | GPIO87 低有效 → KEY_HOME + wakeup | 缺失 | 缺失 | ❌ 主线缺失 |

---

## 六、问题分析

### 🔴 问题 1【严重】音量−挂错引脚（主线与 lk2nd 双双失配）
- 原厂硬件将音量−接到 **TLMM GPIO86**，且在 PON 里显式禁用了 RESIN 输入——说明该机
  RESIN 引脚未被音量−驱动（悬空或仅作硬复位用途）。
- **主线后果**：`pm8953_resin` 被启用为 VOLUMEDOWN 但物理上永不触发 → **系统中音量−键无响应**；
  GPIO86 无人注册 → 该键彻底失效。
- **lk2nd 后果**：`pm8x41_resin_status()` 永不为真 → 无法用「音量−」进入 fastboot /
  recovery 组合；屏幕菜单无法向下移动（只能向上循环绕行）。
- 附注：RESIN 在 Qualcomm 平台仍承担长按硬复位（resin-bark）等 PON 功能，
  主线将其 enabled 为输入设备本身无害，只是语义错误、占位无效。

### 🟡 问题 2【中等】Home 键（GPIO87）主线缺失
- 原厂有独立 Home 键输入（可唤醒）。主线 DTS 未定义 → 系统内 Home 键无功能
  （坚果 Pro 正面实体 Home 键）。lk2nd 侧无碍（菜单导航不需要它）。

### 🟢 问题 3【提示】细节差异
1. 主线 gpio-keys 未设 `debounce-interval`（原厂 15ms）；
2. 原厂三键共用一组 pinctrl（85/86/87 pull-up），主线仅有 gpio85 的
   `gpio_key_default`——新增 86/87 时需一并补充 pinctrl；
3. 原厂 LK（emmc_appsboot.mbn）对音量−的实际检测逻辑无法从二进制静态确认：
   CAF 基线同样读 RESIN，若原厂未修改，则原厂 LK 的音量−组合键检测同样无效
   （Smartisan 的 recovery 入口走系统内重启，故平时不可见）。此点建议实机验证，
   不影响上述以原厂内核 DTB 为准的硬件接线结论。

---

## 七、修复建议（本次仅检查，未做任何改动）

1. **主线 odin.dts**：
   - `gpio-keys` 增加 `volume-down`（`<&tlmm 86 GPIO_ACTIVE_LOW>`）与 `key_home`
     （`<&tlmm 87 GPIO_ACTIVE_LOW>`，可选 `gpio-key,wakeup`），均设
     `debounce-interval = <15>`；
   - 补充 86/87 的 pinctrl（pull-up、drive-strength 2）；
   - `&pm8953_resin` 恢复 `status = "disabled"`（或删除 linux,code 覆盖）。
2. **lk2nd 设备描述**（odin-port/lk2nd/msm8953-smartisan-odin.dts + 补丁 0002）：
   ```dts
   gpio-keys {
       compatible = "gpio-keys";
       volume-up   { lk2nd,code = <KEY_VOLUMEUP>;   gpios = <&tlmm 85 (GPIO_ACTIVE_LOW|GPIO_PULL_UP)>; };
       volume-down { lk2nd,code = <KEY_VOLUMEDOWN>; gpios = <&tlmm 86 (GPIO_ACTIVE_LOW|GPIO_PULL_UP)>; };
       home        { lk2nd,code = <KEY_HOME>;       gpios = <&tlmm 87 (GPIO_ACTIVE_LOW|GPIO_PULL_UP)>; };
   };
   ```
   参照上游同类写法（如 sdm450-mtp.dts:23–34）。改后需重新构建 lk2nd 固件。
3. 实机回归项：音量±在系统内的响应、电源键开机、lk2nd 菜单上下导航、
   VOLUP→recovery、VOLUP+VOLDOWN→EDL。

---

## 八、验证方法备注

- 原厂 FDT 提取：自写 carve 脚本扫描 `\xd0\x0d\xfe\xed` 魔数（boot.img @0x8af448，256422 字节），dtc 反编译。
- 键值核对：0x73=115 KEY_VOLUMEUP、0x72=114 KEY_VOLUMEDOWN、0x66=102 KEY_HOME、0x74=116 KEY_POWER（include/dt-bindings/input/linux-event-codes.h）。
- phandle 0xbe 核对：stock.dts 第 306–315 行 = pinctrl@1000000（tlmm）。
- lk2nd 回退链：`LK2ND_DEVICE_INIT("gpio-keys", ...)`（keys.c:133）→ 无 DT 节点时
  `lk2nd_keys_pressed()` 调 `target_volume_down/up()`（init.c:307–329）。

---

*报告结束 — odin-port 检查报告系列 №002（只读检查，未做代码改动）*
