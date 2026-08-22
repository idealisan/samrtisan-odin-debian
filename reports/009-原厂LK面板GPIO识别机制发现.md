# 009 — 原厂 LK 面板识别机制逆向发现与移植方案修正

日期：2026-08-22　状态：**已实锤，方案修正待实施（#7 改向）**
证据：`evidence/lk-re/report.md`（完整反汇编记录）、`evidence/lk-re/signatures.txt`

## 一、发现详情

对原厂 `emmc_appsboot.mbn`（ELF，基址 0x8F600000）的静态反汇编确认：

### 1. 面板自动识别 = TLMM GPIO 电平三分，非 DSI read-id

选择函数（~0x8F601BF0–0x8F602570）在无名字覆盖时执行：

```
r8 = gpio_get(92);            // helper @0x8F603F10
r0 = gpio_get(91);
if (g91==1 && g92==1)      → nt36672_1080p_video        (panel_id=7)
else if (g91==1)           → ft8716_1080p_video         (panel_id=5)
else                       → sharp_ft8716_1080p_video   (panel_id=6, 兜底)
```

GPIO 读实现：地址 `gpio*0x1000 + 0x1000000`，取 `[reg+4]&1`——msm TLMM v4
pin-region 布局的 IN 寄存器 bit0，与 Linux pinctrl-msm 一致。

### 2. DSI 签名探测从未启用

全部 8 处 `mipi->signature` 赋值均为 **0xFFFF**（禁用哨兵）：
0x8F601E9C / 01FD0 / 02114 / 021E4 / 022B0 / 02378 / 02464 / 025560。
⇒ "从原厂固件提取各面板 DCS read-id 签名值"**不可行：数据不存在**。
此前误判依据的字符串 `"Read ID cmd status failed"` 属 qpic_nand.c（NAND），已排除。

### 3. R69006 不参与自动检测

r69006_cmd/video 仅能经 `panel_name_to_id` 名字覆盖路径到达
（表@0x8F670F70 共 8 项；跳转表 7 分支）。无任何 fastboot 设置命令。

## 二、既有文档/实现的错误修正项

| 项 | 错误内容 | 修正 |
|---|---|---|
| README §五 | "默认面板=原厂首选 R69006 cmd（与原厂 LK 行为一致）" | 原厂默认是 GPIO 三选一、sharp_ft8716 兜底 |
| lk2nd 补丁 0001 | odin 默认固定 R69006 cmd，signature 全 0xFFFF 照抄 | 默认改为复刻 GPIO 检测 |
| README §二 | 暗示 r69006 为首选批次 | r69006 降级为显式指定项 + 最后回退 |

## 三、修正后的 #7 实施方案

lk2nd odin `oem_panel_select`：

```
if (panel_name)  → panel_name_to_id 覆盖（保留，救援通道）
g91 = gpio_get(91); g92 = gpio_get(92);     // 输入态读取
if (g91 && g92)       → NT36672
else if (g91 && !g92) → FT8716
else                  → SHARP_FT8716（兜底）
```

- 与出厂行为逐位一致；两脚异常时回落 sharp，不劣于现状
- ft8716 vs sharp-ft8716 这对"同 IC 不同模组"由 GPIO 区分（read-id 方案本无法区分）
- 配套 #8 `oem panel <name>` 救援命令另行实施

## 四、遗留不确定点

- 选择函数 hw_id 门控细节未完全展开（不影响主结论与复刻方案）
- GPIO 91/92 编号按 TLMM 标准 n*0x1000 布局推得（置信度高）；若实机验证发现
  反相/偏移，仅需调整映射表
