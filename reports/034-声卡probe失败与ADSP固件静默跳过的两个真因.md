# 034 — 声卡 probe -EINVAL 与 ADSP 固件静默跳过的两个真因

日期：2026-09-04
真机：`v0.9.4-submodules`（core 变体），内核 `6.19.5-postmarketos-qcom-msm8953`
结论：**两个独立的真因，都在"看不见"的地方** —— 一个不带任何日志，一个连日志都不写。

---

## 0. 现象

```
$ cat /proc/asound/cards
--- no soundcards ---
$ dmesg | grep -i asoc
[  112.430656] qcom-apq8016-sbc c051000.sound-card: probe with driver qcom-apq8016-sbc failed with error -22
```

ADSP 本身是**好的**：手动跑 `odin-adsp-fw.sh` 之后
`remote processor adsp is now up`，APR 设备（aprsvc:service:4:3/4/7/8/9/a/b）全部注册，
`q6afe / q6adm / q6asm / q6routing` 模块也都在 lsmod 里。
也就是说：**硬件、固件、DSP、AFE 全通，只差最后一步 —— 声卡注册。**

---

## 1. 真因 A：`&sound_card` 缺 `model`，`snd_soc_register_card()` 静默返回 -EINVAL

### 代码证据

`sound/soc/soc-core.c`：

```c
int snd_soc_register_card(struct snd_soc_card *card)
{
	int ret;

	if (!card->name || !card->dev)
		return -EINVAL;          /* ← 没有 dev_err，一行日志都不打 */
	...
}
```

`card->name` 由 `qcom_snd_parse_of()` 里的 `snd_soc_of_parse_card_name(card, "model")` 填，
而 `sound/soc/soc-core.c` 里那个函数的语义是：

```c
	ret = of_property_read_string_index(np, propname, 0, &card->name);
	if (ret < 0 && ret != -EINVAL) { ...; return ret; }
	return 0;                    /* ← 属性不存在（-EINVAL）被吞掉，返回 0 */
```

于是 `model` 缺失时：`snd_soc_of_parse_card_name` 返回 0、`card->name` 仍是 NULL，
`qcom_snd_parse_of()` 继续往下走、一路顺利，最后 `devm_snd_soc_register_card()`
一进 `snd_soc_register_card()` 就 -EINVAL 返回。

`apq8016_sbc_platform_probe()` 剩下的失败点全都有日志：

| 失败点 | 是否打日志 |
|---|---|
| `snd_soc_of_parse_card_name` | 打（"Error parsing card name"） |
| `snd_soc_of_parse_audio_simple_widgets` | 打（"DAPM widget '%s' is not supported"） |
| `snd_soc_of_parse_audio_routing` | 由被调者打 |
| `of_property_read_string(np,"link-name")` | 打（"error getting codec dai_link name"） |
| `snd_soc_of_get_dlc` / `..._dai_link_codecs` | `dev_err_probe`，非 defer 时打 |
| `devm_platform_ioremap_resource_byname` | 不打，但 mic/spkr/quin-iomux 三个 reg 都在 |
| **`snd_soc_register_card`** | **不打** ← 就是它 |

所以现场只剩 driver core 那句通用的 `failed with error -22`，没有任何 ASoC 细节 ——
这也是为什么前几轮把怀疑方向放到了 widgets / routing 上。

### 参照物：上游所有 msm8953 板都写了 model

```
msm8953-xiaomi-mido.dts    model = "xiaomi-mido";
msm8953-xiaomi-markw.dts   model = "xiaomi-markw";
msm8953-motorola-potter    model = "motorola-potter";
msm8953-xiaomi-ysl/oxygen/vince/daisy/huawei-milan  同样都有
```

我们这棵设备树里 `&sound_card` **从建起来就没写过 `model`**。

### 修法

```dts
&sound_card {
	status = "okay";
	model = "smartisan-odin";     /* 必填，且是 ALSA 卡名 */
	...
```

名字取 `smartisan-odin` 是有依据的：仓库里的 UCM 配置目录就是
`dist/build/rootfs/usr/share/alsa/ucm2/conf.d/smartisan-odin/smartisan-odin.conf`，
UCM 靠卡名匹配它。

---

## 2. 真因 B：`initramfs/sbin/odin-adsp-fw.sh` 没有可执行位

### 证据链

1. 真机 `/lib/firmware` 的文件时间戳分两拨：

   ```
   venus.*  wcnss.*   Jan  1  1970   ← initramfs 里放的（那时还没设 RTC）
   adsp.*             Sep  4 20:40   ← 我手动跑用户态脚本放的
   ```

2. `zcat /boot/initramfs.cpio.gz | grep -a -o "sbin/odin-[a-z-]*\.sh"` 三个脚本**都在包里**，
   `init` 里也有 `if [ -x /sbin/odin-adsp-fw.sh ]` 那段钩子 —— 代码在位。

3. 那为什么没执行？看 git 的模式位：

   ```
   100644  dist/build/initramfs/sbin/odin-adsp-fw.sh    ← 缺 x
   100755  dist/build/initramfs/sbin/odin-venus-fw.sh
   100755  dist/build/initramfs/sbin/odin-wlan-fw.sh
   ```

   `[ -x ]` 恒假 ⇒ 整段静默跳过 ⇒ **ADSP 固件一次都没被取过**。

### 为什么用户态那份反而是可执行的

`dist/build/apply-staging-fixes.sh:193` 有一段按路径补权限的逻辑：

```bash
*/sbin/*|*/bin/*) chmod 0755 "$dst" ;;
```

部署 `dist/build/rootfs/…` 时把 `usr/local/sbin/*` 全补成 0755，
**掩盖了仓库里 100644 的事实**。而 initramfs 树不走这个部署函数，于是露馅。

### 修法（两层）

1. 把 `dist/build/initramfs/sbin/odin-adsp-fw.sh`（以及 rootfs 下那几个 100644 的
   sbin 脚本）的 git 模式改成 100755 —— 让仓库本身就对。
2. `tools/ci/build-rootfs.sh` 在 `cp -a` 完 initramfs 树之后显式
   `chmod 0755 "$ISTAGE"/sbin/*.sh`。
   这一层才是"按正常机制"的那道：**能不能执行由构建步骤说了算，
   而不是由谁用什么姿势 `git add` 说了算**，同类问题不会再第三次出现。

---

## 3. 顺带确认 / 更正的几个判断

### 3.1 `MM_DL1` / `MM_UL2` 那些板级路由**不需要**

mido / markw / tissot 写了：

```dts
"MM_DL1", "MultiMedia1 Playback",
"MultiMedia2 Capture", "MM_UL2",
```

而 potter / ysl / oxygen / vince / daisy 没写。查 `q6asm-dai.c:1200`：

```c
SND_SOC_DAPM_AIF_IN("MM_DL1", "MultiMedia1 Playback", 0, SND_SOC_NOPM, 0, 0),
SND_SOC_DAPM_AIF_OUT("MM_UL1", "MultiMedia1 Capture", 0, SND_SOC_NOPM, 0, 0),
```

`MM_DL1` 带**流名** `MultiMedia1 Playback`，ASoC 的
`snd_soc_dapm_link_dai_widgets()` 会按流名把前端 DAI 的 AIF 与它自动连上。
那三条路由是历史遗留。**本设备树不加。**

### 3.2 cdc_pdm 的 pinctrl **必须配**（更正 09-03 的判断）

09-03 在那段注释里写过"官方 &int_codec 那一大组 pinctrl 是下游 PDM 引脚专用，
主线不走这套" —— **错了**。主线 `msm8953.dtsi` 的 `&tlmm` 里就有同名的三组状态
（`cdc_pdm_lines_act` / `_2_act` / `_comp_lines_act`，gpio67~74，function = `cdc_pdm0`），
而且**所有 msm8953 板都挂了它们**。不配就没有任何引脚被复用成 cdc_pdm0，
WCD 的数字音频接口物理上是断的。已在 `&sound_card` 上补 `pinctrl-0/1/2`，
并把那条错误注释改正。

### 3.3 功放从 **OUTL** 取，不是从 DRV 取

照抄 `msm8916-wingtech-wt88047` —— 同样 WCD + 同样 `simple-audio-amplifier`、同样
`enable-gpios`：

```dts
"Speaker Amp INL", "SPK_OUT",
"Ext Spk", "Speaker Amp OUTL",
```

`simple-amplifier` 的内部路由是 `INL/INR → DRV → OUTL/OUTR`，
其中 `OUTL` 还串了一个 `VCC` regulator supply；缺 `VCC-supply` 属性时
`devm_regulator_get(dev,"VCC")` 解析成 dummy regulator（wt88047 也没有这个属性），
不挡路。DAPM 会顺着 OUTL 反向把 DRV 带上电，GPIO 132 照拉。
（09-03 版本里"为绕开 VCC 故意从 DRV 取"的取舍作废。）

### 3.4 `SPK_OUT` / `EAR` 这两个端点确实存在

在 `sound/soc/codecs/msm8916-wcd-analog.c` 里：

```c
SND_SOC_DAPM_OUTPUT("EAR"),
SND_SOC_DAPM_OUTPUT("SPK_OUT"),
```

扬声器内部通路：`SPK DAC --Switch--> PDM_RX3`，`SPK PA ← SPK DAC`，`SPK_OUT ← SPK PA`。
听筒通路：`EAR ← EAR_S ←(Switch) EAR PA ← HPHL/HPHR DAC`，所以听筒还得靠 UCM
把 `EAR_S` 那个 switch 打开（`SPK DAC Switch` / `RX3 MIX1 INP1` 同理）。

### 3.5 pin 默认是通的

`snd_soc_dapm_new_control_unlocked()` 里 `w->connected = 1`，
所以 `pin-switches = "Ext Spk", "Earpiece"` 建出来的两个开关开机就是 on，
不需要 UCM 额外 cset。

---

## 4. 用户态兜底的那个竞态

`odin-adsp-fw.service`（`After=local-fs.target`）实测在开机 **40.0s** 跑完，
而 `qcom,msm8953-adsp-pil` 要到 **40.5s** 才把 `remoteproc1` 注册出来 —— 差 0.5 秒，
于是每轮都只留下一句 `没有找到 adsp remoteproc，跳过`。

改成**轮询等待**：每秒查一次、最多等 40 秒（服务的 `TimeoutStartSec=60`，
留 20 秒给取固件与启动）。initramfs 那一层修好之后这条兜底正常不会被触发，
但触发时它得是对的。

---

## 5. 本轮改动清单

| 文件 | 改动 |
|---|---|
| `patches/0007-*.patch` | `&sound_card` 加 `model`、`pinctrl-0/1`、功放改走 OUTL；改正两处过期注释；hunk 头 740→778 |
| `dts/*.dtb`、`dts/*.dts` | 重新编译（63413 / 63261 字节，原 63209 / 63057） |
| `dist/build/initramfs/sbin/odin-adsp-fw.sh` | git 模式 100644 → 100755 |
| `dist/build/rootfs/usr/local/sbin/odin-{adsp-fw,usb-role,wlan-fw,automount,mount-opts}.sh` | 同上，不再依赖部署时补权限 |
| `tools/ci/build-rootfs.sh` | initramfs 树拷完显式 `chmod 0755 sbin/*.sh` |
| `dist/build/rootfs/usr/local/sbin/odin-adsp-fw.sh` | 轮询等 adsp remoteproc 出现（≤40s） |

验证：`git apply --check` 通过 → `dts/build-dtb.sh` 四份 DTB 编译通过、
四项自检 ✅；反编译能看到 `model = "smartisan-odin"` 与 `pinctrl-0/pinctrl-1`。

**尚未真机验证** —— 等 CI 出包刷入后再补 §6。

---

## 6. 真机验证（v0.9.4-audio-model，2026-09-04 22:57 刷入）

### 6.1 两个真因都被证实

刷入后声卡第一次出现：

```
$ cat /proc/asound/cards
 0 [smartisanodin  ]: smartisan-odin - smartisan-odin
                      smartisan-odin

$ aplay -l                                  $ arecord -l
card 0: device 0: MultiMedia1 (*)           card 0: device 1: MultiMedia2 (*)
card 0: device 2: MultiMedia3 (*)           card 0: device 4: VoiceMMode1 (*)
card 0: device 4: VoiceMMode1 (*)
```

ADSP 也从"手动才起"变成开机自起。判据是 `/lib/firmware` 的文件时间戳：

| 版本 | adsp.* 时间戳 | 谁放的 |
|---|---|---|
| v0.9.4-submodules | `Sep 4 20:40` | 我手动跑用户态脚本 |
| v0.9.4-audio-model | `Jan 1 1970` | **initramfs**（那时还没设 RTC） |

`venus.*` / `wcnss.*` 一直是 1970，现在 `adsp.*` 终于与它们一致了。
刷机验收 16 项全过，其中 `背光(回读): 500`。

### 6.2 播放侧：整条链通电 + 功放使能脚拉高

一边播 1 kHz 一边抓 `/sys/kernel/debug/asoc/smartisan-odin/**/dapm/*`：

```
card 级      Ext Spk             On
digital      AIF1 Playback       On      I2S RX1        On
             RX3 MIX1            On      RX3 MIX1 INP1  On
             RX3 INT             On      PDM_RX3        On
analog       PDM_RX3             On      SPK DAC        On
             SPK PA              On      SPK_OUT        On
             SPKR_CLK            On      RX_BIAS        On
GPIO         gpio132 : out high func0 2mA pull down     ← 外置功放已开
```

从 ADSP 的 PRI_MI2S_RX 一路到外置功放的使能脚，全通。

### 6.3 采集侧：后端是 Tertiary MI2S，不是 Primary

第一次 `arecord -D hw:0,1` 直接 `Invalid argument`，内核给了关键一句：

```
MultiMedia2: ASoC: no backend DAIs enabled for MultiMedia2,
             possibly missing ALSA mixer-based routing or UCM profile
```

`msm8953.dtsi` 里只有 `tertiary-mi2s-dai-link` 是 TX 后端（`TERTIARY_MI2S_TX`），
而 UCM 里写的是 `MultiMedia2 Mixer PRI_MI2S_TX` —— 名字对得上（控件确实存在）、
方向不对，于是后端永远没被启用。改成 `TERT_MI2S_TX` 后能开了。

采集链通电情况（改对之后）：

```
analog   MIC BIAS External1  On    MIC_BIAS1  On    PDM_TX  On    PDM Capture  On
digital  ADC1  On   DEC1 MUX  On   CIC1 MUX  On   I2S TX1  On   AIF1 Capture  On
```

### 6.4 控件名的陷阱：scontrols 显示的名字 ≠ cset 认的名字

`amixer scontrols` 走 alsa-lib 的 **simple 层**，会把尾部的
`" Switch"` / `" Volume"` / `" Mux"` 剥掉；而 `cset name=...` 走的是原始元素名。
同一张卡上实测对照：

| `amixer scontrols` 显示 | `cset` / UCM 要写 |
|---|---|
| `SPK DAC` | `SPK DAC Switch` |
| `RX3 Digital` | `RX3 Digital Volume` |
| `Ext Spk` | `Ext Spk Switch` |
| `Earpiece` | `Earpiece Switch` |
| `ADC2` | `ADC2 Volume` |
| `ADC2 MUX` | `ADC2 MUX`（两边一样） |

拿左列去写 UCM，`alsaucm` 只给一句 `Invalid argument`，不说是哪条。

顺带一条：上游 `apq8016-sbc` 的 UCM 里 `RX3 Digital Volume` 写 **128**，
本机是 `min=0 max=124`、1 dB/档、84 = 0 dB —— 写 128 直接 -EINVAL。
**这才是 `alsaucm set _dev Speaker` 失败的真因**（不是文件结构问题）。

### 6.5 麦克风输入扫描

让扬声器持续播 1 kHz，逐个试 `DEC1 MUX`，各录 2 秒算 RMS：

```
DEC1=ADC1 CIC1=AMIC ADC2MUX=INP2     RMS = 5.5    ← 唯一明显高于本底
DEC1=ADC1 CIC1=AMIC ADC2MUX=INP3     RMS = 5.6
DEC1=ADC2 CIC1=AMIC ADC2MUX=INP2     RMS = 1.2
DEC1=ADC2 CIC1=AMIC ADC2MUX=INP3     RMS = 2.1
DEC1=ADC3 CIC1=AMIC ADC2MUX=INP2     RMS = 1.1
DEC1=ADC3 CIC1=AMIC ADC2MUX=INP3     RMS = 2.1
DEC1=DMIC1 CIC1=DMIC                 RMS = 0.0
DEC1=DMIC2 CIC1=DMIC                 RMS = 0.0
静音基线（DEC1=ADC2 INP2）           RMS = 1.2
```

只有 **ADC1（AMIC1）** 有响应，两个数字麦恒为 0。

⚠️ 但把这个结论再往前推一步就不成立了：之后用 1 kHz 谱线做的 A/B
（直接算 1000 Hz 的 DFT 幅值）显示

```
1000 Hz 幅值：扬声器关 = 8.1   扬声器开 = 9.0
```

几乎没有变化 —— ADC1 上并没有明确的 1 kHz 分量。前面那个 RMS 抬升
更像是开扬声器时的整体噪声抬升，不是收到了 1 kHz。
所以"主麦克风 = AMIC1"**仍待耳朵复核**，可能的原因有：

- 手机平放在桌上，扬声器出声孔被压住、或被外壳遮挡；
- 内置麦与扬声器之间的声耦合本来就很弱；
- 扬声器本身虽然通电但没出声（DAPM 全 On 只证明电路打通，不证明有声音）。

### 6.6 遗留：`alsaucm set _dev` 恒定 -EINVAL

设任何设备都失败，**连上游 apq8016-sbc 的配置也一样**；而把同样的 cset
用 `amixer cset` 逐条手工执行，全部成功。已排除：

- Syntax 3 / Syntax 4 —— 都一样失败
- 卡名写法（`smartisan-odin` / `hw:0` / `smartisanodin` / 不填）—— 都一样
- `ConflictingDevice` —— 删掉也一样
- `EnableSequence` 内容 —— 空序列、单条 cset、完整序列全一样
- 单次调用 vs batch 模式 —— 都一样（`set _verb` 成功、`list _devices` 正常）

对照组：`set _verb NoSuchVerb` 会报 `No such file or directory`（说明 verb 查找是好的），
而 `set _dev NoSuchDevice` 与 `set _dev Speaker` 报一样的 `Invalid argument`
—— 从 alsaucm 的角度看，这个设备就是"不存在"，尽管 `list _devices` 列得出来。

暂未定位。不影响用 `amixer` 直接控音：播放与采集通路本身是通的
（6.2 / 6.3），UCM 只是桌面声音服务（PipeWire/PulseAudio）的配置入口。

### 6.7 需要人耳确认的两件事

1. **扬声器到底出不出声**：跑
   `sudo amixer -c 0 cset name='RX3 MIX1 INP1' RX1 && sudo amixer -c 0 cset name='RX3 Digital Volume' 100 && sudo amixer -c 0 cset name='SPK DAC Switch' on && sudo amixer -c 0 cset name='Ext Spk Switch' on && sudo amixer -c 0 cset name='PRI_MI2S_RX Audio Mixer MultiMedia1' 1 && sudo speaker-test -D hw:0,0 -c 2 -r 48000 -F S16_LE -t sine -l 1`
2. **听筒**（另一条通路，走 EAR）：把上面换成
   `RX1 MIX1 INP1=RX1`、`RX1 Digital Volume=84`、`EAR_S=Switch`、
   `Earpiece Switch=on`、`Ext Spk Switch=off` 再试。

证据文件：`evidence/audio/audio-v094-audio-model.txt`

---

## 7. 人工听音结果（2026-09-04，用户用 odin-audio-test.sh 跑的）

| 项目 | 结果 |
|---|---|
| 听筒 —— 3 秒 1 kHz 提示音 | ✅ **听到** |
| 听筒 —— 《暖暖》前 30 秒 | ✅ **听到，正常** |
| 麦克风 —— 录 6 秒 | ✅ **RMS ≈ 327**（本底 1~2），信号很强 |
| 麦克风录音回放 | ❌ 听不到 —— 但这是"回放走扬声器"导致的，不是采集的问题 |
| 扬声器 —— 3 秒提示音 / 《暖暖》30 秒 | ❌ 没声音 |

### 7.1 三个结论

1. **听筒通了** ⇒ ADSP、q6afe/q6routing、数字 codec、模拟 codec 全都是好的。
   听筒走的是 `RX1 → PDM_RX1 → HPHL DAC → EAR PA → EAR_S → EAR`。
2. **麦克风通了，而且就是 ADC1（AMIC1）**。RMS 327 对上本底 1~2，
   §6.5 里那个"可疑"的 5.5 现在有了解释：当时是增益没开够（ADC1 Volume 默认 0），
   本轮脚本里设了 `ADC1 Volume = 8` 之后信号一下就出来了。
   **§6.5 末尾"待耳朵复核"的疑问解除**，UCM 里 `DEC1 MUX = ADC1` 是对的。
3. **扬声器是剩下唯一的问题**，而且范围已经很窄了：
   上游（ADSP → AFE → 数字 codec → PDM）被听筒证伪不了，
   问题只可能落在"SPK 那一条腿"或"外置功放"上。

### 7.2 扬声器的可疑点（下一轮的起点）

听筒用的是 `HPHL DAC`，而扬声器这条腿我按 `SPK_OUT` 走的：

```dts
"Speaker Amp INL", "SPK_OUT",
"Ext Spk", "Speaker Amp OUTL",
```

但主线 `msm8916-wingtech-wt88047` 的扬声器功放是**从 HPH_R 取的**：

```dts
"Speaker Amp INL", "HPH_R",
"Speaker Amp INR", "HPH_R",
```

本机没有 3.5mm 耳机口，HPH_L / HPH_R 是空着的 —— 外置功放很可能就挂在
它们上面，而不是挂在 SPK_OUT 上。原厂 `mixer_paths_mtp.xml`（reports/033 里
已经解出来了）应当能直接给出答案，下一轮先去那里查。

---

## 8. 扬声器不响的真因：功放是 AW87318，MODE 脚要打脉冲（2026-09-05）

### 8.1 现象里最费解的那一点

上一轮抓到的证据是矛盾的：

- DAPM 整条链全 On：`PDM_RX3 → SPK DAC → SPK PA → SPK_OUT`
- 外置功放的使能脚 `gpio132 : out high` —— 确实拉高了
- **但就是没声**

如果 GPIO 拉高就等于功放开了，那应该响。所以"拉高"和"开了"之间还差一步。

### 8.2 原厂源码给的答案

`sound/soc/codecs/msm8x16-wcd.c`：

```c
	/* lineout to AW87318 */                              ← 注释点名型号
	{"AW_SPK_PA", NULL, "LINEOUT PA"},                    ← 音频来自 LINEOUT
	SND_SOC_DAPM_SPK("AW_SPK_PA", aw_speaker_pa_enable),

	#define AW_BOOST_DEFAULT_MODE 6
	static int aw_boost_mode = AW_BOOST_DEFAULT_MODE - 1; /* = 5 */

	static int aw_speaker_pa_enable(struct snd_soc_dapm_widget *w, ...)
	{
		case SND_SOC_DAPM_POST_PMU:
			gpio_set_value_cansleep(pdata->ext_pa_en_gpio, 1);      /* 第 1 个上升沿 */
			for (i = 0; i < mode; i++) {                            /* mode = 5 */
				gpio_set_value_cansleep(pdata->ext_pa_en_gpio, 0);
				gpio_set_value_cansleep(pdata->ext_pa_en_gpio, 1);  /* 再来 5 个 */
			}
	}
```

而 `pdata->ext_pa_en_gpio` 的来源是 `qcom,ext-pa-enable` ——
正好就是 ODIN 音频 DTS 里那个 `qcom,ext-pa-enable = <&tlmm 132 0>`。**同一个脚。**

### 8.3 三条结论

1. **这颗功放靠 MODE 脚上的脉冲个数选工作模式**，不是拉高就开。
   `simple-audio-amplifier` 只会把脚拉高 ⇒ AW 芯片永远等不到模式脉冲 ⇒
   一直关着 ⇒ 不出声。这就是为什么"GPIO 是 high"和"没声"能同时成立。
2. `awinic,mode = <6>`：上游 aw8738 从 low 起打 `mode` 个 (0,1)，
   要凑出下游的 1 + 5 = 6 个上升沿就得写 6。
3. **音频输入是 LINEOUT，不是 SPK_OUT**。主线对应：
   ```
   {"LINEOUT_OUT", NULL, "LINEOUT PA"}
   {"LINEOUT PA",  NULL, "LINEOUT"}
   {"LINEOUT", "Switch", "LINEOUT DAC"}
   {"LINEOUT DAC", NULL, "PDM_RX3"}
   ```
   所以 routing 写 `"Speaker Amp INL", "LINEOUT_OUT"`，
   UCM 里再补 `cset "name='LINEOUT' Switch"`（mux 不打就没有信号进功放）。
   主线 `LINEOUT_OUT ← LINEOUT PA` 是无 mux 直连，选它可以少开一个开关。

### 8.4 两个干扰项（都排掉了）

- codec 里还有另一个功放 widget
  `SND_SOC_DAPM_SPK("Ext Spk", msm8x16_wcd_codec_enable_spk_ext_pa)`，
  走**电平**驱动，GPIO 由 `qcom,msm-spk-ext-pa` 指定。
  **整个原厂 DTS 树里没有任何一份定义这个属性** ⇒ 那条路对 ODIN 是死代码。
- `mixer_paths_mtp.xml` 里 `<path name="speaker">` 写的是
  `RX3 MIX1 INP1 = RX1` + `SPK = Switch`，看着像说"扬声器走 SPK_OUT"。
  但那份 XML 是 **mtp 参考设计的通用配置**，`SPK` 指内部小喇叭那条；
  ODIN 的大喇叭在原厂是由 `AW_SPK_PA` widget 承载的（注释点名 AW87318）。
  两者不是一回事 —— 这也是为什么我一开始照 XML 接 SPK_OUT 却没声。

### 8.5 改动

| 文件 | 改动 |
|---|---|
| `patches/0007` | `compatible = "awinic,aw8738"` + `mode-gpios` + `awinic,mode = <6>`；routing `SPK_OUT → LINEOUT_OUT`；hunk 头 778 → 808 |
| `dts/*.dtb` | 重编（63435 / 63283 字节，原 63413 / 63261），`.gitignore` 里不入库 |
| UCM `HiFi.conf` | Speaker 的序列用 `LINEOUT` mux 取代 `SPK DAC Switch`；文件头加了"换回 simple-amplifier 就会静音"的警告 |
| `odin-audio-test.sh` | `spk_on` / `ear_on` 同步改走 LINEOUT |

`CONFIG_SND_SOC_AW8738=m` 内核里本来就有，不用动。

**待真机听音确认**（CI run 33892957697 → v0.9.4-aw8738）。

---

## 9. 里程碑：扬声器 / 听筒 / 麦克风全部打通（2026-09-05，v0.9.4-aw8738-2）

刷入 `v0.9.4-aw8738-2` 后用户用 `odin-audio-test.sh` 逐项听音：

| 项目 | 结果 |
|---|---|
| 扬声器 —— 3 秒提示音 | ✅ 响 |
| 扬声器 —— 《暖暖》前 30 秒 | ✅ 正常 |
| 听筒 —— 提示音 / 音乐 | ✅ 依然正常 |
| 麦克风 —— 录 6 秒 | ✅ RMS ≈ 327 |

**整机音频链路打通**：ADSP（开机自起）→ q6afe/q6routing → 数字 codec → 
模拟 codec → 外置 AW 功放（脉冲模式）→ 扬声器；听筒与采集各自独立可用。

从 §1 的"一条声卡都没有"到这一步，中间卡住的四处分别是：

1. `&sound_card` 缺 `model` ⇒ `snd_soc_register_card()` 静默 -EINVAL（§1）
2. initramfs 取固件脚本没有可执行位 ⇒ ADSP 固件从未就位（§2）
3. 外置功放是 AW87318，MODE 脚要打 6 个脉冲才开机，不是拉高就开（§8）
4. aw8738 的 DAPM 端点是 **IN / OUT**，不是 INL / OUTL —— 照 simple-amplifier
   写会 ENODEV，两条路由全挂，**声卡直接注册不起来**（v0.9.4-aw8738 的教训）

### 9.1 音量刻度不是百分比（用户实测撞到的小坑）

`RXn Digital Volume`：`min=0 max=124`，**84 = 0 dB**，1 dB/档。
所以填 30 不是"30%"，而是 **−54 dB**。

后果：把音量调到 30 时，扬声器还能勉强听见（它本来就响），
**听筒则完全没声** —— 听着像听筒坏了，其实是数值理解错了。

两个应对：

- 主线 **没有** `EAR PA Gain` 控件（下游有）。原厂 handset 通路是
  `RX1 Digital Volume = 84` **加上** `EAR PA Gain = POS_6_DB`，
  主线缺了后者，所以 UCM 里听筒直接给 **90（+6 dB）**。
- 测试脚本里扬声器与听筒**各存各的音量**（`VOL` / `EVOL`），
  并且在所有显示处把数字换算成 dB（`84 → 0 dB`、`30 → −54 dB`），
  免得再被当成百分比。

### 9.2 最终确认：两条播放通路都完整通电（2026-09-05 07:58）

改完音量（听筒 UCM 默认 90 = +6 dB、脚本 VOL/EVOL 分离）之后，
用户再次听音：**扬声器与听筒都听到**。同时用 debugfs 做了客观复核——
播放时两条链上的部件全 On，且 GPIO 132 在两条路之间正确互斥：

```
扬声器（RX3 → LINEOUT → 外置 AW 功放）
  digital  AIF1 Playback On → I2S RX1 On → RX3 MIX1 On → RX3 MIX1 INP1 On
           → RX3 INT On → PDM_RX3 On
  analog   PDM_RX3 On → LINEOUT DAC On → LINEOUT On → LINEOUT PA On → LINEOUT_OUT On
  card     Ext Spk On            Earpiece Off
  GPIO132  out high              ← 功放开了

听筒（RX1 → HPHL DAC → EAR PA → EAR）
  digital  AIF1 Playback On → I2S RX1 On → RX1 MIX1 On → RX1 MIX1 INP1 On → PDM_RX1 On
  analog   PDM_RX1 On → HPHL DAC On → EAR PA On → EAR_S On → EAR On
  card     Earpiece On           Ext Spk Off
  GPIO132  out low               ← 扬声器功放正确关闭
```

两条路的 `GPIO132` 状态相反，说明 `ConflictingDevice` 语义下的互斥是生效的
（听筒响的时候外置功放没被误开）。

证据：`evidence/audio/audio-all-paths-ok-20260905.txt`、
`evidence/audio/audio-test-log-20260905.txt`

### 9.3 音频专项收尾状态

| 项 | 状态 |
|---|---|
| 声卡注册 | ✅ `smartisan-odin`，PCM device 0/1/2/4 齐全 |
| ADSP 开机自起 | ✅ 固件由 initramfs 提供（时间戳 1970） |
| 扬声器 | ✅ 外置 AW 功放（脉冲模式） |
| 听筒 | ✅ |
| 麦克风（AMIC1） | ✅ RMS ≈ 327 |
| UCM 设备切换 `alsaucm set _dev` | ❌ 恒定 -EINVAL，**不影响 amixer 直接控音**，但桌面声音服务依赖它，未解决（§6.6） |
| 音量百分比映射 | ⚠️ 0~124 且 84 = 0 dB，桌面音量条会表现异常，未做映射 |
| 耳机通路 | — 本机无 3.5mm 口，不需要 |

---

## 10. 更正 §6.6：`alsaucm set _dev` 不是 bug，是我命令用错了

§6.6 记的"遗留：alsaucm set _dev 恒定 -EINVAL，暂未定位"——**结论是错的**。
UCM 配置一直是对的，坏的是我的命令。

翻 alsa-lib 1.2.8 的 `src/ucm/main.c`（第 2724 行起）：

```c
int snd_use_case_set(snd_use_case_mgr_t *uc_mgr,
		     const char *identifier, const char *value)
{
	...
	else if (strcmp(identifier, "_verb") == 0)
		err = set_verb_user(uc_mgr, value);
	else if (strcmp(identifier, "_enadev") == 0)
		err = set_device_user(uc_mgr, value, 1);
	else if (strcmp(identifier, "_disdev") == 0)
		err = set_device_user(uc_mgr, value, 0);
	...
	else {
		str1 = strchr(identifier, '/');
		if (str1) { ... }
		else {
			err = -EINVAL;          /* ← `set _dev` 就掉进这里 */
			goto __end;
		}
		if (check_identifier(identifier, "_swdev"))
			err = switch_device(uc_mgr, str, value);
		else if (check_identifier(identifier, "_swmod"))
			err = switch_modifier(uc_mgr, str, value);
		else
			err = -EINVAL;
	}
	...
}
```

**1.2.8 支持的 identifier 只有**：`_fboot` / `_boot` / `_defaults` / `_verb` /
`_enadev` / `_disdev` / `_enamod` / `_dismod` / `_swdev/<名>` / `_swmod/<名>`。
**根本没有 `_dev`** —— 所以它必然返回 -EINVAL，对任何配置、任何机器都一样。
这也解释了 §6.6 里那两条当时想不通的对照：
"上游 apq8016-sbc 的配置也一样失败"（不是配置问题）、
"`set _dev NoSuchDevice` 和 `set _dev Speaker` 报一样的错"（根本没走到查找那步）。

### 10.1 实测：用对 identifier 后一切正常

同一进程里 `set _verb HiFi` → `set _enadev Speaker`：

```
PRI_MI2S_RX Audio Mixer MultiMedia1   values=on
RX3 MIX1 INP1                         values=3     ← RX1
RX3 Digital Volume                    values=84    ← 0 dB
LINEOUT                               values=1     ← Switch
Ext Spk Switch                        values=on
```
EnableSequence 被完整执行。

再 `set _disdev Speaker`：

```
RX3 MIX1 INP1                         values=0     ← ZERO
LINEOUT                               values=0     ← ZERO
Ext Spk Switch                        values=off
```
DisableSequence 也正确执行。

听筒同理（`_enadev Earpiece` → `RX1 MIX1 INP1=RX1`、`EAR_S=Switch`、
`Earpiece Switch=on`、`RX1 Digital Volume=90`）。

### 10.2 两个容易误解的细节

1. **跨进程时 `_disdev` 会报 ENOENT**。`set_device_user` 里
   `find_device(uc_mgr, uc_mgr->active_verb, name, 1)` 要求设备在当前
   active 列表里；alsaucm 每次调用都是新进程，active 列表是空的。
   这不是配置问题，用 `-b -`（batch）把一串命令喂进**同一个进程**即可。
2. **`set_device` 开头有幂等短路**：
   ```c
   if (device_status(uc_mgr, device->name) == enable)
           return 0;          /* 已经是目标状态 ⇒ 不执行序列 */
   ```
   所以重复 `_enadev` 不会重跑序列，重复 `_disdev` 也不会。
   我之前测出"disdev 好像没生效"，是因为同一串命令里又 `set _verb HiFi`
   把 active 设备列表清了 —— 不是配置错。

### 10.3 顺带：音量百分比映射（已做进测试脚本）

`RXn Digital Volume` 原始值 0~124、84 = 0 dB。测试脚本原来让用户直接填原始值，
很容易被当成百分比（填 30 实际是 −54 dB，听筒直接静音）。现在脚本按**百分比**
输入，内部换算，并同时显示原始值与 dB：

    0% → 原始 0（−84 dB，静音）  68% → 原始 84（0 dB）  100% → 原始 124（+40 dB）

保留原始值直通：前面加 `r`，例如 `r90`。
