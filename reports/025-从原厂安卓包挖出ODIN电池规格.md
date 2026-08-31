# 025 — 从原厂安卓包挖出 ODIN 的电池规格（兼答 reports/024 的两个未确认项）

调研日期：2026-08-31
来源：`/Volumes/caseSensitiveBar/Pro_user_V4.2.5/SEKSA-mol%odin-rom-4.1.0-odin-user-20180523-005028-32g`
（ODIN 原厂安卓 7.1.1，`ro.product.device=odin`、`ro.product.board=msm8953`、
`ro.smartisan.version=4.2.5-201805230045-user-od`）

**结论：拿到了。`reports/024` §7 里两条"未确认"现在都确认了。**

---

## 1. 挖取方法（可复现）

原厂包里没有电池规格文档，参数全在**下游内核的设备树**里，而 DTB 藏在 `boot.img` 的 kernel 段尾部。

```
boot.img（header_version=0，dt_size=0 ⇒ DTB 不是独立字段）
  → 全文件搜 DTB 魔数 0xd00dfeed  →  偏移 9106504，tot_size=256422（正好填到 kernel 段末尾 9362926）
  → 抽出 → dtc -I dtb -O dts  →  model = "Qualcomm Technologies, Inc. MSM8953 ODIN"
                                 compatible 含 "qcom,odin", "qcom,odin-p1"
                                 qcom,msm-id = <0x125 0x00>；qcom,board-id = <0x0b 0x01>
```

产物已归档（防止重复挖取，也防止 ROM 不在时数据丢失）：
- `evidence/stock-rom-battery/odin-stock.dtb`（256,422 字节）
- `evidence/stock-rom-battery/odin-stock.dts`（反编译，378,559 字节，约为原厂配置全集）

> 坑记录：第一次 `dtc ... | head -20` 把管道掐断（SIGPIPE）导致 dtc 被杀、输出文件没生成，
> 误以为反编译失败。**不要给 dtc 管道接 head**。

---

## 2. ODIN 电池规格（原厂标称值）

原厂 DT 里有**两块电池**（两个供应商），靠电池 ID 电阻区分，`qcom,batt-id-range-pct = <15>`（±15%）：

| 项 | ATL（10 kΩ） | SCUD（100 kΩ） | 十六进制 |
|---|---|---|---|
| `battery-type` | `smartisan_atl_3500mAh` | `smartisan_scud_3500mAh` | |
| **标称容量** | **3500 mAh** | **3500 mAh** | `0xdac` |
| **最高电压** | **4.400 V** | **4.400 V** | `0x432380` µV |
| 电池 ID 电阻 | 10 kΩ | 100 kΩ | `0x0a` / `0x64` |
| NTC B 值 | 3435 | 3380 | `0xd6b` / `0xd34` |
| thermal-coefficients | `c2 86 bb 50 cf 37` | `da 86 f0 50 08 3c` | |
| 低温快充补偿 | 700 mA | 900 mA | `0x2bc` / `0x384` |
| rslow 补偿 c1/c2 / rs-to-rslow / thr | 见 DT | 见 DT | |
| checksum | `0x2903` | `0xcaad` | |
| 标定工具 | `PMI8950GUI - 2.0.0.16` | 同 | |

**关键简化：两块电池在 simple-battery 层面完全等价** —— 容量、满电电压、放电截止都一样，
只有 NTC B 值差 55（3435 vs 3380），而主线用的是固定 `SCALE_PMI_CHG_TEMP`（见 §5），
**所以主线只需要填一组参数，不必做电池识别**。

---

## 3. 充电器参数（`qcom,qpnp-smbcharger`，PMI8950 基址 0x1000）

| 属性 | 值 | 十六进制 | 说明 |
|---|---|---|---|
| `qcom,float-voltage-mv` | **4400 mV** | `0x1130` | 充电截止（恒压）电压 |
| `qcom,iterm-ma` | **100 mA** | `0x64` | 充电终止电流 |
| `qcom,fastchg-current-ma` | 3500 mA | `0xdac` | **见下面警告** |
| `qcom,resume-delta-mv` | 200 mV | `0xc8` | 复充阈值 |
| `qcom,rparasitic-uohm` | 100000 µΩ | `0x186a0` | 寄生电阻 |
| `qcom,thermal-mitigation` | 3000/2300/2000/1500/1200/800/800/0 mA | | 8 级温降流 |
| `qcom,fastchg-current-comp` | 1200 mA | `0x4b0` | |
| `qcom,float-voltage-comp` | 16 mV | `0x10` | |
| `qcom,override-usb-current` | 有 | | |
| OTG regulator | `smbcharger_charger_otg` | | 对应我们的 `qcom-smbchg-otg.ko` |

⚠️ **3.5 A 不是单靠 PMI8950 拿到的** —— 原厂还有一颗 **SMB1351 并联充电器**：

```dts
smb1351-charger@1d {              /* i2c@78b6000 */
	compatible = "qcom,smb1351-charger";
	qcom,parallel-charger;
	qcom,float-voltage-mv = <4400>;
	qcom,recharge-mv = <100>;
	qcom,parallel-en-pin-polarity = <1>;
};
```
配合 `qcom,parallel-usb-min-current-ma = <1400>`、`qcom,parallel-usb-9v-min-current-ma = <900>`、
`qcom,parallel-allowed-lowering-ma = <500>`。

**主线 6.19 的 `drivers/power/supply/` 下没有 smb1351 驱动**（只有 `qcom-smbchg.c`、
`qcom_smbb.c`、`qcom_smbx.c`、`qcom_battmgr.c`、`smb347-charger.c`）。
⇒ **并联快充在主线上不可用，`fastchg-current-ma=3500` 不能直接抄**。

---

## 4. 电量计参数（`qcom,qpnp-fg`，基址 0x4000）

| 属性 | 值 | 十六进制 |
|---|---|---|
| `qcom,fg-cutoff-voltage-mv` | **3400 mV** | `0xd48` |
| `qcom,fg-cc-cv-threshold-mv` | 4390 mV | `0x1126` |
| `qcom,fg-iterm-ma` | 180 mA | `0xb4` |
| `qcom,fg-chg-iterm-ma` | 150 mA | `0x96` |
| `qcom,resume-soc` / `-raw` | 95 / 254 | `0x5f` / `0xfe` |
| JEITA：cold / cool / warm / hot | 0 / 15.0 / 45.0 / 60.0 °C | `0` / `0x96` / `0x1c2` / `0x258` |
| `qcom,bcl-lm/mh-threshold-ma` | 127 / 405 mA | `0x7f` / `0x195` |
| `qcom,vbat-estimate-diff-mv` | 200 mV | `0xc8` |
| 开关 | `qcom,ext-sense-type`（外部检流）、`cycle-counter-en`、`capacity-learning-on`、`hold-soc-while-full`、`bad-battery-detection-enable` | |

子块：`fg-soc@4000`、`fg-batt@4100`、`fg-memif@4400`、`revid-tp-rev@1f1`；另有 `bcl@4200`（`qcom,msm-bcl`）。

**原厂 DT 里没有 `qpnp-vm-bms` 节点**（`qcom,bms-psy-name = "bms"` 只是个未被满足的引用）。
⇒ 印证 reports/024 的判断：**ODIN 走 FG，不用 VM-BMS**，与主线 `pmi8994_fg` 路线一致。

---

## 5. 回答 reports/024 §7 的两个"未确认"

### §7-1 ODIN 电池参数 —— **已确认**

```
charge-full-design-microamp-hours = <3500000>     /* 3500 mAh，两供应商一致 */
voltage-min-design-microvolt     = <3400000>      /* fg-cutoff-voltage-mv      */
voltage-max-design-microvolt     = <4400000>      /* max-voltage-uv / float-mv */
constant-charge-current-max-microamp = ?          /* 见下，不能抄 3500 mA */
charge-term-current-microamp     = <100000>       /* smbcharger iterm-ma 100 mA */
```

`constant-charge-current-max-microamp` 的建议：原厂 3500 mA 是 **SMBC + SMB1351 并联**的总能力，
主线只有 SMBC。参照 pmOS markw（同为 msm8953）取 1000 mA，**建议先取 1500000（1.5 A）做保守起步**，
真机测充电温升与 `thermal-mitigation` 表现后再往上调。
注意这条路走不通的后果：`qcom,smbchg` 的绑定要求 `constant-charge-current-max-microamp` 与
`voltage-max-design-microvolt` **必须**设置，否则 probe 失败、整个 charger psy 都出不来。

### §7-2 FG SRAM profile 是谁写的 —— **已确认：下游 qpnp-fg 驱动从设备树写进去的**

原厂 DT 里每块电池都带一段 `qcom,fg-profile-data`（32 个 word，由 `PMI8950GUI 2.0.0.16` 标定生成），
下游 `qpnp-fg` 驱动在 probe 时经 MEM_IF 把它写进 FG 的 SRAM。这就是主线 `pmi8994_fg.c`
里"为什么不写 OCV/容量"却仍然能算出 SOC 的答案 —— **硬件里已经有一份原厂标定好的 profile**。

原始值（留档，防止电池彻底断电后 SRAM 丢失）：

```
ATL  (smartisan_atl_3500mAh, checksum 0x2903):
qcom,fg-profile-data = <0xde83c07c 0xc812877 0x5883a265 0x5e836a8e 0x7d82cc92
  0x6fb4cbbb 0x52160588 0xea7dcf81 0x3a7c5183 0xa36a7678 0xfb854c82 0xb099fbbc
  0xecc9590d 0x8e0d1d59 0x147050fd 0xaa360844 0x77390000 0x35463430 0xfe120000
  0x00 0x00 0x6e70336b 0xd712289 0xae741768 0x8c5e5979 0xb76ebd60 0x8b765ba3
  0x1d6c6817 0x66a0710c 0x2800ff36 0xf0113003 0x0c>;

SCUD (smartisan_scud_3500mAh, checksum 0xcaad):
qcom,fg-profile-data = <0xec83387d 0x5581aa77 0x5483de59 0x6801287 0x1e828c9a
  0xd7bd17cb 0x5a0eed83 0xc57ce180 0x9f765783 0x8e636080 0x148d4c82 0xc59918bd
  0x13ca540d 0xa80d2b59 0x147050fd 0xa63eb13e 0x7390000 0x9645b039 0xfd360000
  0x00 0x00 0xb46aa069 0x9f6b5088 0x12751869 0x906b6f82 0x5e6fe362 0x947cb1a1
  0x1a5161d2 0x5da0710c 0x2800ff36 0xf0113003 0x0c>;
```

**推论与风险**：主线驱动不会重写这段 profile，只会沿用 SRAM 里现有的那份。
pmOS 6.17 那次实测读到 `CAPACITY=99`，说明当时 SRAM 里的 profile 还在。
**风险仍在**：电池彻底耗尽 / 长时间拆电池后 SRAM 若掉电，profile 可能丢失且主线无法恢复。
⇒ 真机验证时建议加一条观察项：充满→放空，看 SOC 是否线性。

---

## 6. 附带确认的两件事

1. **主线电池温度通道已内建，不用自己标 NTC**。
   主线 `drivers/iio/adc/qcom-spmi-vadc.c:574`：
   `VADC_CHAN_TEMP(SPARE2, 0, SCALE_PMI_CHG_TEMP)`，而 `VADC_SPARE2 = 0x0d`
   —— 与原厂 `chan@d { reg = <0x0d>; label = "chg_temp"; scale-function = <0x10>; }` 是同一个通道。
   原厂靠 `qcom,battery-beta`（3435/3380）做精确换算，主线用固定的 `SCALE_PMI_CHG_TEMP`，
   **读数会有偏差但不至于失效**。这解释了 pmOS 实测的 27.5 °C 为什么合理。

2. **原厂 SoC 热管理与主线不是一套**。原厂用 `qcom,msm-thermal`：
   limit-temp 60 °C、core-limit 80 °C、hotplug 105 °C、freq-mitigation 105 °C、
   therm-reset 115 °C、vdd 限制 1.0368 GHz。
   主线走 `thermal-zones` + step_wise governor（CPU/GPU 80 °C passive / 100 °C critical）。
   **两套数值口径不同，主线那套不用改**，只是降频触发点比原厂晚。

---

## 7. 原厂包里其他值得参考的资产（顺带清点）

| 文件 / 分区 | 大小 | 对当前工作的参考价值 |
|---|---|---|
| `boot.img` 里的 DTB | 256 KB | **电池之外**，还含 pinmux、regulator 全表、panel、触摸、传感器、相机、音频的完整配置 —— 后续任何硬件适配都可以回这里查事实 |
| `NON-HLOS.bin` → `modem` 分区 | 96 MB | 对应 `reports/020` 蜂窝网络调研 |
| `adspso.bin` → `dsp` 分区 | 16 MB | ADSP 固件 |
| `persist_1.img` → `persist` | 4.6 MB | 含 WiFi/蓝牙 MAC 与校准，改它要极慎重 |
| `factory_image_normal.img` / `_fac.img` → `factory` | 32 MB | 出厂校准数据 |
| `splash.img` | 160 KB | 开机 logo |
| `emmc_appsboot.mbn` → `aboot` | 664 KB | 原厂 bootloader（我们已用 lk2nd 取代，别动） |
| `devcfg.mbn` / `sbl1.mbn` / `rpm.mbn` / `tz.mbn` | — | 信任链与安全相关，**只读研究，切勿刷写** |

分区表（`rawprogram_unsparse.xml`）里还有 `fsg`/`fsg1..5`、`mcfg`、`fsg` 等 modem 配置分区，
与 `reports/020` 相关；`oem`、`alterable`、`limits`、`devinfo`、`dip`、`dpo`、`keystore` 等
在 rawprogram 里 **没有对应 img 文件**（只有空占位），说明原厂包不含这些分区的内容。

---

## 8. 对 reports/024 §8 行动清单的修订

1. 内核配置开 `CONFIG_BATTERY_PMI8994_FG=y` —— 不变。
2. odin.dts 补三节点，`simple-battery` **直接填 §5 的真值**（3500 mAh / 3.4 V / 4.4 V），
   `constant-charge-current-max-microamp` 先取 **1500000**（不抄 3500，见 §3 警告），
   `charge-term-current-microamp = <100000>`。
3. rootfs 装 `upower` + `policykit-1` —— 不变。
4. 真机验证增加两条观察项：
   - 充电时读 `qcom-smbchg-usb` 的 `input_current_limit` / `constant_charge_current`，
     比对壁充的实际电流，判断 1.5 A 是否偏保守；
   - 充满→放空全程记录 `capacity`，验证 FG SRAM profile 是否还在（§5 风险）。
5. **新增**：把 `evidence/stock-rom-battery/odin-stock.dts` 当作硬件事实库，
   后续适配器（面板/触摸/传感器/相机/音频）优先查它，而不是猜。

## 9. 仍未确认

- FG SRAM profile 的**持久化机制**（是否由 always-on 域维持、掉电能否保住）—— 只能实测。
- `qcom,ext-sense-type` 对应的外部检流电阻阻值原厂没写在 DT 里（驱动默认值），
  若发现 `current_now` 读数偏大/偏小，这是第一个要查的地方。
- 主线 `SCALE_PMI_CHG_TEMP` 与原厂 `battery-beta` 的温差有多大 —— 需与红外/环境温度对比实测。
