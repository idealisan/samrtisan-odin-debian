# 032 — 音频：启用 ADSP 与主线声卡链路

> 目标：让 ODIN 出声、能录。
> 参考：原厂安卓 ROM 的 DTB、pmOS 给 msm8953 系列（mido / tissot / mido 等）的移植、
> 主线 `msm8953.dtsi` 的音频拓扑。

---

## 0. 结论速览

| 项 | 状态 |
|---|---|
| 启用前的状态 | **完全没有音频**：`/proc/asound/cards` = `--- no soundcards ---`，`audio-codec@f000 status=disabled`，只有 wcnss 一个 remoteproc |
| 根因 | `patches/0007` 从未启用音频；`&lpass`/`&wcd_codec`/`&sound_card` 在主线 dtsi 里**默认全是 disabled** |
| 本次改动 | 启用这三个节点 + 由 initramfs 供 ADSP 固件 + 加装 alsa 工具 |
| 还没解决 | **外置扬声器功放**没接（见 §4），所以扬声器大概率仍不响 |

---

## 1. 材料在哪（这份清单下次直接查）

| 材料 | 位置 | 说明 |
|---|---|---|
| 原厂安卓 ROM 的 DTB | `tmp/stock-rom/stock.dts`、`evidence/stock-rom-battery/odin-stock.dts` | 从 boot.img 解出的下游设备树 |
| ⚠️ 完整安卓 ROM | **仓库里没有**，`system` 分区**也是空的** | 无 `system.img`、无 `mixer_paths.xml`、无音频 HAL |
| pmOS 的 msm8953 参考 | `tmp/pmos-refs/pmaports/device/community/device-xiaomi-markw/` | 只有 `deviceinfo` + `modules-initfs`，**没有 markw 的 DTS** |
| pmOS 内核树（含一批 msm8953 设备的 DTS） | `tmp/pmos-refs/linux-markw/arch/arm64/boot/dts/qcom/` | mido / tissot / vince / daisy / potter / rimob |
| 主线内核树（CI 基线 770e10fa） | `tmp/linux-msm8953`、`tmp/linux-kernel`、`tmp/linux-dtb` | `msm8953.dtsi`、`pm8953.dtsi` 都在这里 |
| 上一轮音频调试产物 | `tmp/audio-test/`（约 20 个脚本） | 09-01 那轮的 DAPM 试错记录，用的是实验性 DTB，**没进 patches/0007** |
| 设备上的 modem 分区 | `/dev/mmcblk0p52`，挂载后 `/image/` | `adsp.*`、`wcnss.*`、`venus.*`、`cmnlib*.` 都在这 |

> 原厂 `system` 分区实测已空（挂载成功但只有 `lost+found`），
> 所以**拿不到 `mixer_paths.xml`** —— 通路只能照主线 + pmOS 同类设备推。
> 好在主线 msm8953 的音频走 ADSP，DAPM 由内核的 machine driver 自己定义，
> 不依赖安卓那套 mixer 配置。

---

## 2. 主线 msm8953 的音频拓扑（读代码所得）

音频**不是**"驱动直接喂 codec"，而是整条链路跑在 **ADSP（Hexagon 音频 DSP）** 上，
AP 侧通过 APR 与它通信：

```
&lpass (remoteproc, qcom,msm8953-adsp-pil, msm8953.dtsi:3076)
   └─ 加载 adsp.mdt，把 ADSP 拉起来
      └─ q6afe / q6adm / q6asm / q6routing / q6voicedai（ADSP 上的服务，DTS 里不用写）
&lpass_codec   数字部分 qcom,msm8916-wcd-digital-codec（msm8953.dtsi:3065）
&wcd_codec     模拟部分 qcom,pm8916-wcd-analog-codec —— **在 pm8953.dtsi:141，不是 msm8953.dtsi**
&sound_card    machine driver qcom,msm8953-qdsp6-sndcard（msm8953.dtsi:2982）
   ├─ primary-mi2s-dai-link   回放，codec 侧 <lpass_codec 0>, <wcd_codec 0>
   └─ tertiary-mi2s-dai-link  录音，codec 侧 <lpass_codec 1>, <wcd_codec 1>
```

默认的 `audio-routing` 已覆盖 AMIC1 / AMIC2 / AMIC3（挂 MIC BIAS External1/2/1）。

三个节点在主线 dtsi 里**默认全是 `status = "disabled"`**，必须逐个显式打开。

内核配置（`config-postmarketos-qcom-msm8953.aarch64`）本来就齐：
`CONFIG_QCOM_APR=m`、`CONFIG_QCOM_Q6V5_PAS=m`、`CONFIG_REMOTEPROC=y`、
QDSP6 全套（AFE / ADM / ASM / ROUTING / PRM / Q6VOICE）、
`CONFIG_SND_SOC_MSM8916_WCD_ANALOG=m`。**不需要改配置。**

---

## 3. 本次改动

### 3.1 `patches/0007`：启用三个节点

```dts
&lpass      { status = "okay"; };   /* ADSP */
&wcd_codec  { status = "okay"; };   /* PMIC 里的模拟 codec */
&sound_card { status = "okay"; };   /* machine driver */
```

（已用 `git apply --check` 在干净树上验证通过；hunk 行计数同步为 565。）

### 3.2 新增 `dist/build/initramfs/sbin/odin-adsp-fw.sh`

**为什么必须在 initramfs（switch_root 之前）**：
`qcom,msm8953-adsp-pil` 的匹配数据是 `msm8996_adsp_resource`
（`drivers/remoteproc/qcom_q6v5_pas.c:921`）：

```c
.firmware_name = "adsp.mdt",
.auto_boot     = true,
.pas_id        = 1,
```

`auto_boot = true` 意味着**驱动一 probe 就立刻 request_firmware，失败不会自己重试**。
固件不到位 = 整台机器没有声音，之后补文件也没用。与 `wcnss.*`、`venus.*` 同理，
按 `reports/021` 的规矩放到 initramfs。

固件来源：原厂 modem 分区的 `/image/`，实测有 `adsp.mdt` + `adsp.b00`~`adsp.b13`
（共约 9.5 MB）。脚本不写死段列表（段数随 ROM 版本变），只认 `.mdt` + 至少一个 `.b*`。

### 3.3 `dist/build/initramfs/init`：加钩子

与 wlan / venus 同构，缺文件时才临时把根 remount 成 rw，取完 sync 再挂回 ro。

### 3.4 用户态工具

基础包加 `alsa-utils`（`aplay` / `amixer`）与 `alsa-ucm-conf`（UCM profile）。
之前这三个命令一个都没有。

---

## 4. 外置扬声器功放：GPIO 132（官方源码实锤）

### 4.1 依据

官方开源内核 **SmartisanOS_Kernel_Source 的 `U2ProKernel` 分支**（Linux 3.18.31）里的
`arch/arm/boot/dts/qcom/u3-p1-msm8953-special-odin-audio.dtsi`：

```dts
&pm8953_diangu_analog { status = "ok"; };

&int_codec {
	status = "ok";
	qcom,msm-mbhc-hphl-swh = <1>;
	qcom,msm-hs-micbias-type = "external";
	qcom,cdc-us-euro-gpios = <&tlmm 128 0>;
	qcom,msm-micbias2-ext-cap;
};

&pm8953_diangu_dig {
	status = "ok";
	qcom,cdc-micbias-cfilt-mv = <2700000>;
	qcom,ext-pa-enable = <&tlmm 132 0>;   ← 外置功放使能 = GPIO 132
	qcom,speaker-id    = <&tlmm 93  0>;   ← 扬声器 ID 检测（输入）
};
```

下游驱动 `sound/soc/codecs/msm8x16-wcd.c`：

```c
SND_SOC_DAPM_SPK("Ext Spk", msm8x16_wcd_codec_enable_spk_ext_pa);
gpio_request_one(pdata->ext_pa_en_gpio, GPIOF_OUT_INIT_LOW, ...);  /* 默认关 */
gpio_set_value_cansleep(pdata->ext_pa_en_gpio, 1);                 /* 高 = 开 */
```

**用的是 PMIC 内置 codec**（`pm8953_diangu_analog` / `pm8953_diangu_dig`）——
对应主线的 `wcd_codec`（`qcom,pm8916-wcd-analog-codec`）与
`lpass_codec`（`qcom,msm8916-wcd-digital-codec`）。外置的只有一颗功放。

### 4.2 ⚠️ 关键更正：GPIO 是 132，不是 96

| 来源 | GPIO | 结论 |
|---|---|---|
| pmOS 的 mido（红米 Note 4，`awinic,aw8738`） | 96 | ❌ 09-01 照抄了这个，扬声器一直不响 |
| **ODIN 官方 DTS** | **132** | ✅ 本次采用 |

09-01 那轮把 mido 的 AW8738 + GPIO 96 当成通用模板抄过来，是扬声器无解的直接原因。

### 4.3 主线怎么接

主线没有 aw8738 驱动，也不需要 —— 这颗功放只有一根使能脚。用主线自带的
**`simple-audio-amplifier`**（`sound/soc/codecs/simple-amplifier.c`）即可：
它的 DAPM 是 `INL/INR → DRV → OUTL/OUTR`，`DRV` 的 POST_PMU/PRE_PMD 事件
正好去拉 `enable-gpios`，等价于下游那个 `"Ext Spk"` widget。

主线 WCD codec 的输出名（`msm8916-wcd-analog.c`）：
`EAR`（听筒）、`HPH_L`/`HPH_R`（耳机）、`SPK_OUT`（扬声器）、`LINEOUT_OUT`。

声卡驱动走的是公共解析器 `qcom_snd_parse_of()`（`sound/soc/qcom/common.c`），
支持 `widgets` / `audio-routing` / `pin-switches` / **`aux-devs`** —— 所以功放
可以作为 aux device 挂进去。

### 4.4 已落地的 DTS

```dts
/ {
	speaker_amp: audio-amplifier {
		compatible = "simple-audio-amplifier";
		enable-gpios = <&tlmm 132 GPIO_ACTIVE_HIGH>;
		sound-name-prefix = "Speaker Amp";
	};
};

&sound_card {
	status = "okay";
	widgets = "Speaker", "Ext Spk",
		  "Earpiece", "Earpiece";
	audio-routing =
		"AMIC1", "MIC BIAS External1",
		"AMIC2", "MIC BIAS External2",
		"AMIC3", "MIC BIAS External1",
		"Speaker Amp INL", "SPK_OUT",
		"Ext Spk", "Speaker Amp DRV",
		"Earpiece", "EAR";
	pin-switches = "Ext Spk", "Earpiece";
	aux-devs = <&speaker_amp>;
};
```

两处刻意的取舍：

1. 从 **DRV** 取信号而不是 OUTL/OUTR —— 后者还串着 simple-amp 的
   `VCC` regulator supply，而本机功放的供电轨没查到证据，接错反而点不亮。
2. 不建模 `qcom,speaker-id`（GPIO 93）—— 那是给安卓 HAL 选功放型号用的输入引脚，
   主线不需要。

> `speaker_amp` 节点必须包在 `/ { }` 里。这个项目踩过：顶层节点在 dtc 1.6.1 下
> 直接报 `syntax error`（见 `setup-rootfs.sh` 里 battery 节点的注释）。

**待验证**：GPIO 132 的极性（下游是 `GPIOF_OUT_INIT_LOW` + 置 1 开启，
所以 `GPIO_ACTIVE_HIGH` 应当正确）、simple-amp 的 DRV 事件能否正常触发。
刷入后若扬声器仍不响，先用 `gpioget/set` 直接拉 GPIO 132 确认功放本身。

---

## 5. 验证方法

刷入新镜像后：

```sh
cat /proc/asound/cards           # 应当出现声卡，不再是 "no soundcards"
cat /sys/class/remoteproc/*/state # 应当多出一个 running 的 lpass（ADSP）
dmesg | grep -i adsp             # 应看到 ADSP 起来、没有 firmware 报错

# 放音（听筒 / 扬声器）
aplay -D plughw:0,0 test.wav
# 或用仓库里的 MP3
ffmpeg -i "梁静茹 - 暖暖.mp3" -t 30 -f wav out.wav && aplay out.wav

# 录音（两个麦克风）
arecord -D plughw:0,1 -f S16_LE -r 48000 -d 5 mic.wav
```

⚠️ 扬声器仍可能不响 —— 那是 §4 的功放没接，不是这次改动失败。

---

## 6. 待办

1. 刷入新镜像验证声卡是否出现、ADSP 是否 running。
2. 找到外置功放的型号与 GPIO（可能需要拆机看丝印，或逐个试 GPIO）。
3. 确认 `alsa-ucm-conf` 里有没有匹配本声卡的 UCM profile；没有的话补一份
   （或改用 `asound.state` 直接写默认通路）。
4. 两个麦克风分别验证（AMIC1 / AMIC3，参考 09-01 记下的 TERT_MI2S_TX 通路）。
