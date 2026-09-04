# 033 — 音频通路：从原厂 system 镜像解出 `mixer_paths_mtp.xml`

> 目的：拿到安卓自己怎么定义每条音频通路，用来校准主线的 DAPM 接线。
> 材料：`tmp/Pro_user_V4.2.5/SEKSA-mol%odin-rom-4.1.0-.../system_*.img`（36 个分片，2.9 GB）。

---

## 0. 怎么解出来的

本机没有 `debugfs` / `simg2img` / `7z`，macOS 也挂不了 ext4。但 Android 的
system 分区是**未压缩的 ext4**，所以直接在原始字节里找即可：

```sh
# 确认是 ext4：超级块在偏移 1024
python3 -c "f=open('system_1.img','rb'); f.seek(1024); print(f.read(8).hex(' '))"
# -> 80 f5 02 00 0b d0 0b 00

# 36 个分片直接 cat 成一个流，流式搜字符串
cat system_*.img | grep -abo 'mixer_paths'
```

关键偏移（拼合后的流）：

| 内容 | 偏移 |
|---|---|
| 音频 HAL 的「声卡名 → mixer_paths 文件」映射表 | 155,147,000 附近 |
| `mixer_paths_mtp.xml` 的 `<path name="speaker">` | **2,629,099,140** |

解出的片段已存 `evidence/audio/mixer_paths_mtp-excerpt.txt`。

---

## 1. 下游声卡名

音频 HAL 的映射表里，msm8953 相关的是 **`msm8953-snd-card-mtp`**，对应
`/system/etc/mixer_paths_mtp.xml`。

（表里还有 `msm8953-sku3-tasha-snd-card` → `mixer_paths_qrd_sku3.xml`、
`msm8952-skum-snd-card` → `mixer_paths_qrd_skum.xml` 等，但本机的 DTB 走的是
`mtp` 这一支，与 `u3-p1-msm8953-special-odin-audio.dtsi` 用 `&int_codec`
（内置 codec）而非外挂 tasha/wsa 一致。）

---

## 2. 三条关键通路（原文）

### 扬声器

```xml
<path name="speaker">
    <ctl name="RX3 MIX1 INP1" value="RX1" />
    <ctl name="SPK" value="Switch" />
</path>
```

**用的是 RX3 → SPK**，不是 RX1。

另有 `wsa-speaker` 走 `LINE_OUT` + `SpkrMono WSA_RDAC`，那是 WSA881x 智能功放
专用的，**本机不用**（官方 DTS 里那 4 个 wsa881x 节点全是 `status = "disabled"`）。

### 听筒（下游叫 `handset`，不叫 earpiece）

```xml
<path name="handset">
    <ctl name="RX1 MIX1 INP1" value="RX1" />
    <ctl name="RDAC2 MUX" value="RX1" />
    <ctl name="RX1 Digital Volume" value="84" />
    <ctl name="EAR PA Gain" value="POS_6_DB" />
    <ctl name="EAR_S" value="Switch" />
</path>
```

走 **RX1 + EAR_S**，与扬声器完全分开。

### 麦克风

```xml
<path name="adc1">
    <ctl name="ADC1 Volume" value="6" />
    <ctl name="DEC1 MUX" value="ADC1" />
</path>

<path name="adc2">
    <ctl name="ADC2 Volume" value="6" />
    <ctl name="DEC1 MUX" value="ADC2" />
</path>

<path name="adc3">
    <ctl name="ADC3 Volume" value="6" />
    <ctl name="DEC1 MUX" value="ADC2" />
    <ctl name="ADC2 MUX" value="INP3" />      ← 主麦
</path>

<path name="handset-mic">
    <path name="adc1" />
    <ctl name="IIR1 INP1 MUX" value="DEC1" />
</path>

<path name="headset-mic">
    <path name="adc2" />
    <ctl name="ADC2 MUX" value="INP2" />      ← 耳机麦
    <ctl name="IIR1 INP1 MUX" value="DEC1" />
</path>

<path name="speaker-mic">
    <path name="adc1" />
    <ctl name="IIR1 INP1 MUX" value="DEC1" />
</path>
```

**主麦是 INP3（经 ADC2 / DEC1）** —— 这与 09-01 那轮纯靠试错得到的
"INP3 主麦能录到说话声、INP2 几乎无声"**完全吻合**。这次是从原厂配置里读到的，
不再是猜的。

### 耳机

```xml
<path name="headphones">
    <ctl name="MI2S_RX Channels" value="Two" />
    <ctl name="RX1 MIX1 INP1" value="RX1" />
    <ctl name="RX2 MIX1 INP1" value="RX2" />
    <ctl name="RX HPH Mode" value="HD2" />
    <ctl name="COMP0 RX1" value="1" />
    <ctl name="COMP0 RX2" value="1" />
    <ctl name="RDAC2 MUX" value="RX2" />
    <ctl name="HPHL" value="Switch" />
    <ctl name="HPHR" value="Switch" />
</path>
```

---

## 3. 对主线接线的校验

| 通路 | 下游 | 主线（`msm8916-wcd-analog.c` 的 widget） | 我们的 DTS | 结论 |
|---|---|---|---|---|
| 扬声器 | RX3 → `SPK` | `SPK_OUT` | `"Speaker Amp INL", "SPK_OUT"` → DRV → Ext Spk | ✅ 对应正确 |
| 听筒 | RX1 → `EAR_S` | `EAR` | `"Earpiece", "EAR"` | ✅ 对应正确 |
| 主麦 | `INP3` / ADC2 / DEC1 | `AMIC3` + `MIC BIAS External1` | 沿用 dtsi 默认 | ✅ 一致 |
| 耳机 | RX1/RX2 → `HPHL`/`HPHR` | `HPH_L` / `HPH_R` | 未接 | ⚠️ 待加 |

**结论：主线的 `SPK_OUT` / `EAR` 两个 widget 名与下游的 `SPK` / `EAR_S` 是对应的，
我们现在的 routing 方向没错。** 之前扬声器不响的原因是功放 GPIO（96 → 132）抄错，
不是通路选错 —— 这两件事现在都各自有了独立证据。

---

## 4. 还可以补的：耳机通路

主线有 `HPH_L` / `HPH_R`，下游确认耳机走这两个开关。可以在 `&sound_card` 的
`audio-routing` 里加：

```
"Headphone Jack", "HPH_L",
"Headphone Jack", "HPH_R",
```

但耳机插拔检测（MBHC）需要先解决：`qcom,hphl-jack-type-normally-open` 的极性
**在这份 XML 里查不到**（那是硬件特性，不在 mixer 配置里）。仍待实测。

---

## 5. 待办

1. 加耳机通路到 `audio-routing`（HPH_L / HPH_R）。
2. 耳机插拔检测：等真机实测确定 `qcom,hphl-jack-type-normally-open` 的极性。
3. 外置功放的 `VCC` 供电轨：XML 里没有（那是硬件供电，不在 mixer 配置里），
   仍需查原理图或实测。
4. 这份 XML 还有大量 `speaker-protected`、`vi-feedback`、speaker 保护（VI 反馈）
   相关通路，**主线都不需要**（那是安卓的扬声器保护算法），已确认可忽略。
