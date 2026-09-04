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
