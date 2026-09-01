# 028 — postmarketOS Venus 方案调研（固件 / 补丁 / 设备树 / 用户态）

> 调研日期 2026-09-01。目的：回答"msm8953 的 venus 该用 HFI_VERSION_1XX 还是 3XX、
> 固件该叫什么、DTS 要不要写 firmware-name、用户态走 V4L2 M2M 还是 VA-API"。
> 素材：本地 pmaports 副本 `tmp/pmos-pmaports/`（快照 2024-11-03）+ 本地内核
> `tmp/linux-msm8953/`（6.19.5/main）+ 联网核对（pmOS wiki / GitLab / GitHub）。
>
> **本轮是纯调研，没有改任何项目代码。**

## 0. 结论速览

| 问题 | 结论 | 证据强度 |
|---|---|---|
| **HFI 版本** | **保持 `HFI_VERSION_3XX`，不要打补丁** | ★★★ 三条独立证据（原厂 DT / pmOS 现行内核逐字节一致 / pmOS wiki） |
| **固件路径** | **`/lib/firmware/venus.mdt` + `venus.bNN`**（裸路径，**无** `qcom/` 前缀） | ★★★ 驱动 `.fwname` 原样 + pmOS 全平台无覆盖 |
| **DTS `firmware-name`** | **不要加** | ★★★ 全部 msm8953 机型 DTS 都没有 |
| **用户态** | **V4L2 M2M**（`/dev/videoX`），**不是** VA-API | ★★★ pmOS wiki 原文 |
| **需不需要内核补丁** | **不需要**。pmOS 对 venus **一个补丁都没有** | ★★★ 上游 APKBUILD `source` 只有 tarball + config |
| **我们为什么还失败** | 不是 HFI 版本问题；**这台机器跑 pmOS 时 venus 也没起来** | ★★ 见 §7 |

---

## 1. 一句话结论

**主线 venus 驱动对 msm8953 的配置（`HFI_VERSION_3XX` + `fwname="venus.mdt"`）是正确
的，postmarketOS 原样使用、零补丁、wiki 标注 Works。我们的 `-EIO` 不是"选错 HFI 版本"，
别往 1XX 方向改。**

---

## 2. pmaports 里 venus 固件是怎么供给的

### 2.1 结论：主力是 `msm-firmware-loader`，不是固件包

翻遍 pmaports，**msm8953 家族（msm8953 / sdm450 / sdm632）的 device 包与 firmware 包里，
绝大多数根本不带 venus 固件**。带 GPU 固件的 `firmware-xiaomi-mido` 只装了两件：

```sh
# device/community/firmware-xiaomi-mido/APKBUILD
_fwdir="/lib/firmware/postmarketos"
package() {
	# GPU firmware
	install -Dm644 a506_zap.mdt -t "$pkgdir/$_fwdir"
	install -Dm644 a506_zap.b02 -t "$pkgdir/$_fwdir"
}
```

连 `firmware-qcom-adreno`（`device/community/firmware-qcom-adreno/APKBUILD`）都显式只打包
GPU（`_gpus="a300 a330 a420 a530 a630 a650 a660"`），注释还写着
"Drop _zap shader firmware because that is typically signed" —— **venus 一行没提**。

真机上 `firmware-qcom-msm8953` 的实测内容（我们自己的取证
`evidence/device-probe/08-peripherals-firmware.txt:121`）也印证了：只有
`qcom/msm8953/<vendor>/<device>/a506_zap.{mdt,b02}` 与 WiFi/蓝牙固件，**没有 venus**。

那 venus 固件从哪来？**`msm-firmware-loader`** —— 所有 msm8953 设备包的 `depends` 里都有它：

```sh
# device/community/device-xiaomi-mido/APKBUILD（tissot / rosy / potter / ali / ocean / fp3 同构）
depends="
	firmware-qcom-adreno-a530
	firmware-xiaomi-mido
	linux-postmarketos-qcom-msm8953
	lk2nd-msm8953
	mkbootimg
	msm-firmware-loader        ← 就是它
	postmarketos-base
	soc-qcom-msm8953
	soc-qcom-msm8953-modem
"
```

### 2.2 `msm-firmware-loader` 到底干了什么

`main/msm-firmware-loader/APKBUILD`，pkgver `1.5.0`，源码在
`gitlab.postmarketos.org/postmarketOS/msm-firmware-loader`。核心脚本 `msm-firmware-loader.sh`
（本轮已下载到 `tmp/pmos-venus-probe/msm-firmware-loader-1.5.0/`）流程：

```
1. tmpfs 挂到 /lib/firmware/msm-firmware-loader
2. 扫描 sysfs，只读挂载 apnhlos / bluetooth / modem$(slot) / persist 分区
3. 先把"预装目录"的 blob 软链进 target/   ← 优先级最高
     预装目录 = $(cat /sys/module/firmware_class/parameters/path)
     通常是 /lib/firmware/postmarketos
4. 再把各分区 <part>/image/* 的 blob 软链进 target/
   （已存在的名字跳过 ⇒ 预装的可以覆盖分区里的）
5. ★ venus 特判 ★
     若有 target/venus.mdt 且没有 target/qcom 目录：
       建 qcom/venus-x/，把 venus.* 全软链进去
       再把 qcom/venus-1.8  qcom/venus-3.0  qcom/venus-4.2  qcom/venus-4.4
              qcom/venus-5.2  qcom/venus-5.4  qcom/vpu-1.0  qcom/vpu-2.0
       全部软链到 qcom/venus-x
       ⇒ 不管驱动 .fwname 要的是哪个版本目录，都能命中同一份固件
6. *.mdt → 同名 *.mbn 建软链（"Some kernel versions expect .mbn instead of legacy .mdt"）
7. printf "%s" "$BASEDIR/target" > /sys/module/firmware_class/parameters/path
```

关键代码（`msm-firmware-loader.sh:124-151`）：

```sh
if [ -f "$BASEDIR/target/venus.mdt" ] && ! [ -d "$BASEDIR/target/qcom" ]
then
	mkdir -p "$BASEDIR/target/qcom/venus-x"
	for part in "$BASEDIR"/target/venus.*
	do
		ln -s "$part" "$BASEDIR/target/qcom/venus-x/$(basename "$part")"
	done
fi

VENUS_DIRS="
	venus-1.8
	venus-3.0
	venus-4.2
	venus-4.4
	venus-5.2
	venus-5.4
	vpu-1.0
	vpu-2.0
"
```

**这意味着两件事：**

1. **venus 固件就是设备自己 `modem` 分区 `/image/venus.mdt` + `venus.bNN`**，
   不是从任何软件仓库下的。跟我们 WORKLOG 里 "从 modem:/image/ 拷出来" 的做法**同源**。
2. pmOS **刻意不依赖 `.fwname` 的具体取值** —— 它把所有可能的 venus 目录都软链到同一份固件。
   所以"固件文件叫什么"在 pmOS 上根本不构成问题，**反过来说明 `firmware-name` 不是关键变量**。

### 2.3 两个"预装 venus"的例外（都是 msm8953 家族）

只有这两个包把 venus 固件打进了 `/lib/firmware/postmarketos/`（即 §2.2 步骤 3 的预装目录）：

| 包 | 机型 / SoC | 实际路径字符串 |
|---|---|---|
| `device/testing/firmware-motorola-ocean` | Moto G7 Power / SDM632 | `/lib/firmware/postmarketos/venus.mdt`<br>`/lib/firmware/postmarketos/venus.b00` … `venus.b04` |
| `device/testing/firmware-samsung-j8y18lte` | Galaxy J8 (2018) / SDM450 | 同上，`venus.mdt` + `venus.b00`…`venus.b04` |

**注意：段数就是 `b00`~`b04` 共 5 段**。我们本机拷的也是 `b00~b04`，**段数吻合，不是漏拷**。
（佐证：`qcom_mdt_load()` 会按 MDT 元数据逐段索取，少一段就直接 `-ENOENT`；我们没报
`-ENOENT` 而是过了加载关，说明段是齐的。）

> ⚠️ 这两个包走的是 `/lib/firmware/postmarketos/`（预装目录），**不是**驱动直接请求的
> `/lib/firmware/venus.mdt`。它们靠 msm-firmware-loader 的步骤 3 把文件软链进 `target/`
> 根目录后才对得上驱动的 `venus.mdt`。**Debian 上没有 msm-firmware-loader，我们必须直接
> 放在 `/lib/firmware/` 根下** —— 也就是我们现在的做法，是对的。

### 2.4 对照：非 msm8953 平台的 venus 固件路径（全表）

| 平台 | 形态 | 实际路径字符串 | DTS `firmware-name` |
|---|---|---|---|
| **msm8953 / sdm450 / sdm632** | mdt + 分段 | `venus.mdt` + `venus.b00`…`b04`（裸路径） | **无** |
| msm8916 | 单文件签名 | `qcom/venus-1.8/venus.mbn` | 无 |
| msm8996 | 单文件签名 | `qcom/msm8996/<device>/venus.mbn` | 有（oneplus3/3t） |
| sdm845 | 单文件签名 | `qcom/sdm845/<vendor>/<device>/venus.mbn` | 有（oneplus6/beryllium/polaris/axolotl/pixel3） |
| sdm660/636 类 | mdt + 分段 | `qcom/venus-4.4/venus.{mdt,b00..b04}` | 无 |
| sony ninges | mdt + 分段 | `qcom/venus-4.4/venus.*`（initd 单独拷贝） | 无 |
| qcm6490 | 单文件签名 | `qcom/qcm6490/SHIFT/otter/venus.mbn` | 有 |
| sc7180 等新平台 | 单文件签名 | `qcom/vpu-1.0/venus.mbn` 等 | 无 |

**规律很清楚**：新平台（sdm845 及以后）用**单文件签名 `.mbn` + DTS `firmware-name`**；
msm8953 这类老平台用**裸 `venus.mdt` + 不带 `firmware-name`**。我们属于后者。

### 2.5 落到我们（Debian）的做法

```sh
# 从 modem 分区取（与 pmOS 同源）
mount -o ro /dev/disk/by-partlabel/modem /mnt/modem
cp /mnt/modem/image/venus.mdt /lib/firmware/venus.mdt
cp /mnt/modem/image/venus.b0? /lib/firmware/     # b00..b04

# 校验：段数要与 MDT 元数据一致；缺段会在加载阶段报 -ENOENT
```

⚠️ **固件必须在驱动索取它之前就位** ⇒ 按 `reports/021-固件与驱动的供给策略.md` 的规范，
要落进 **initramfs**（`switch_root` 之前），不是 late systemd service。

---

## 3. pmaports 里针对 venus 的内核补丁：**一个都没有**

### 3.1 APKBUILD 层面

`device/community/linux-postmarketos-qcom-msm8953/APKBUILD`：

| | 本地快照（2024-11-03） | 上游当前（gitlab main） |
|---|---|---|
| `pkgver` | `6.11.1-r0` | `7.1.3-r0` |
| `source` | tarball + `config-*.aarch64` | tarball + `config-*.aarch64` |
| **patches** | **无** | **无** |

上游当前 `source` 原文（本轮已下载到
`tmp/pmos-venus-probe/upstream-msm8953-APKBUILD.txt`）：

```sh
_tag="$pkgver-r0"

source="
	$pkgname-v$_tag.tar.gz::$url/archive/v$_tag.tar.gz
	config-$_flavor.aarch64
"
```

**没有任何 `.patch`。**

### 3.2 全库检索

```
grep -rl 'hfi_version\|HFI_VERSION'  tmp/pmos-pmaports/     → 0 命中
find tmp/pmos-pmaports -iname '*venus*'                     → 0 命中
grep -rli 'vidc' device/                                    → 9 个，全是 armv7 老机型
                                                              （mako/bullhead/mata/find7a/…）
                                                              与 msm8953 无关
```

唯一沾点边的是 `device/testing/linux-lenovo-achilles/02-fix_hfi_packetization.patch`
（这是 **HFI = Host Firmware Interface，Intel 的**，不是 Qualcomm Venus 的 HFI），
**命名陷阱，别被 grep 骗过去**。

### 3.3 内核树层面

`msm8953-mainline/linux`（pmOS 的内核源）里 `drivers/media/platform/qcom/venus/` 的提交历史
（GitHub API 拉了最近 40 条）**全是上游 backport / CVE 修复 / 重构**，例如：

```
bcaaa08dd  media: venus: drop unused module aliases
afb100a5e  media: venus: pm_helpers: add fallback for the opp-table
ba4fdff92  media: venus: Add framework support for AR50_LITE video core
85c853b70  media: venus: Define minimum valid firmware version
9edaaa8e3  media: venus: hfi_parser: refactor hfi packet parsing logic
...
```

**没有任何一条是 msm8953 专有的 venus 补丁，更没有 hfi_version 3XX↔1XX 的改动。**

---

## 4. pmaports 里 venus 的设备树改动：**也没有**

### 4.1 pmaports 里压根没有 msm8953 的 DTS

```
find tmp/pmos-pmaports -name '*.dts*'   → 13 个文件，全都不是 msm8953
grep -rn '&venus' tmp/pmos-pmaports/*.dts*  → 0 命中
grep -rn 'firmware-name' tmp/pmos-pmaports/ → 唯一命中：sc7180 的 remoteproc
                                              （qcom/sc7180/acer/aspire1/qcadsp7180.mbn）
```

机型 DTS 全在内核树里，不在 pmaports。

### 4.2 内核树里：SoC 级节点默认启用，机型级零覆盖

`msm8953.dtsi`（tag `v6.11.1-r0`，第 2110 行）：

```dts
venus@1d00000 {
	compatible = "qcom,msm8953-venus";
	reg = <0x1d00000 0xff000>;
	clocks = <&gcc GCC_VENUS0_VCODEC0_CLK>,
		 <&gcc GCC_VENUS0_AHB_CLK>,
		 <&gcc GCC_VENUS0_AXI_CLK>;
	clock-names = "core", "iface", "bus";
	interconnects = ...;
	interconnect-names = "video-mem", "cpu-cfg";
	interrupts = <GIC_SPI 44 IRQ_TYPE_LEVEL_HIGH>;
	iommus = <&apps_iommu 0x16>;
	memory-region = <&venus_mem>;
	power-domains = <&gcc VENUS_GDSC>;

	video-decoder { compatible = "venus-decoder"; ... };
	video-encoder { compatible = "venus-encoder"; ... };
	venus_opp_table: opp-table { ... };
};
```

两个要点：

1. **没有 `status` 属性** ⇒ DT 语义上**默认启用**。不需要写 `status = "okay"`。
   （对比 `&mpss` / `&wcnss` 是显式 `status = "disabled"`，那两个才要 opt-in。）
2. **没有 `firmware-name`** ⇒ 用驱动内置 `.fwname = "venus.mdt"`。

逐机型核对（`msm8953-xiaomi-mido` / `-tissot` / `-motorola-potter` / `sdm632-motorola-ocean` /
`sdm450-motorola-ali` / `sdm632-fairphone-fp3`，tag `v6.11.1-r0`）：

```
&venus 覆盖 → 全部 0 命中
```

**六台主力机型的 DTS 都没有 `&venus` 覆盖。所以我们的 DTS 也不需要加任何东西。**

> 顺带：`msm8953.dtsi` 里 `venus_mem` 是 `venus@91400000`，7 MiB
> （真机 dmesg：`0x91400000..0x91afffff (7168 KiB) nomap non-reusable venus@91400000`）。
> 固件要塞进这块 reserved memory，`firmware.c:114` 会校验 `*mem_size < fw_size || fw_size > VENUS_FW_MEM_SIZE`
> ⇒ 我们过了这关，说明固件尺寸没问题。

---

## 5. 用户态：V4L2 M2M，不是 VA-API

### 5.1 pmOS wiki 原文（决定性依据）

<https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_450/625/626/632_(MSM8953)>
"Video Encoder / Decoder (Venus)" 一节：

> **Venus works. It exposes 2 v4l2 devices, one for encode and one for decode.
> They can be used via gstreamer, or mpv.**
> For mpv, you need to prioritize the `*_v4l2m2m` hardware decoders via the `vd` setting
> in your `~/.config/mpv/mpv.conf`:
> ```
> vd=hevc_v4l2m2m,h264_v4l2m2m,h263_v4l2m2m,vp8_v4l2m2m,mpeg4_v4l2m2m
> ```
> SDM450 based devices are limited by the firmware to 1080p encode/decode, while
> SDM625/632 based devices are able to do 4Kp30 decode, and 1080p encode.
> Supported formats are: VP8, VP9, MPEG2, H.264 and H.265.

gstreamer 验证命令（wiki 原文）：

```sh
# test h264
gst-launch-1.0 -e filesrc location="/path/to/video.mp4" ! qtdemux name=d \
  d.video_0 ! h264parse ! v4l2h264dec capture-io-mode=dmabuf ! kmssink \
  d.audio_0 ! queue ! aacparse ! faad ! autoaudiosink
# test h265
gst-launch-1.0 filesrc location=big_buck_bunny.mp4 ! qtdemux ! queue ! \
  h265parse ! v4l2h265dec ! imxvideoconvert_g2d ! queue ! autovideosink
```

**结论：V4L2 M2M（`/dev/videoX` + `v4l2m2m` / `v4l2h26Xdec`），完全没有提 VA-API。**

⚠️ **我们是 SDM450 ⇒ 固件限制 1080p 编解码**，不是 4K。别拿 4K 片源当验收标准。

### 5.2 pmaports 里没有相关用户态包 —— 因为那些来自 Alpine aports

pmaports 的 `main/` 里**没有** `ffmpeg` / `mesa` / `gstreamer` / `libva` / `v4l-utils`
（这些都是 Alpine 官方源的包）。全库检索 `mesa-venus` / `libva` / `vaapi`：
**0 命中**。

### 5.3 ⚠️ 命名陷阱：`mesa-venus` 不是给裸机 qcom venus 用的

`mesa-venus` 是 **Mesa 的 VirtIO-GPU Venus 驱动**
（<https://docs.mesa3d.org/drivers/venus.html>），作用是把 **guest 里的 Vulkan 调用
通过 virtio-gpu 转发给 host** —— 是**虚拟机**用的东西，跟裸机上的 Qualcomm Venus
视频编解码器**同名不同物，毫无关系**。

同理，Debian 上没有任何 VA-API 后端能驱动裸机 qcom venus：

- `mesa-va-drivers` → 只覆盖 radeon/nouveau/iHD 等
- VA-API 在 qcom 上的唯一形态是 `qcom-venus` 的 **V4L2 stateless 后端**，
  需要 `libva-v4l2` 这类第三方适配层，**Debian 没有打包**

**⇒ 走 VA-API 是死路。老老实实用 V4L2 M2M。**

### 5.4 Debian bookworm 需要装的包

```sh
apt install ffmpeg \
            v4l-utils \
            gstreamer1.0-tools \
            gstreamer1.0-plugins-base \
            gstreamer1.0-plugins-good
```

| 包 | 提供 | 用途 |
|---|---|---|
| `ffmpeg` | `h264_v4l2m2m` / `hevc_v4l2m2m` / `vp8_v4l2m2m` / `vp9_v4l2m2m` / `mpeg4_v4l2m2m` 等 | FFmpeg 走硬件编解码 |
| `v4l-utils` | `v4l2-ctl`、`v4l2-compliance`、`media-ctl` | **验收必备**：`v4l2-ctl --list-devices` / `-d N --list-formats-ext` |
| `gstreamer1.0-tools` | `gst-launch-1.0`、`gst-inspect-1.0` | 跑 wiki 的验证管线 |
| `gstreamer1.0-plugins-good` | `v4l2h264dec` / `v4l2h265dec` / `v4l2vp8dec` / `v4l2vp9dec` / `v4l2h264enc` | GStreamer 的 v4l2 编解码元素 |
| `gstreamer1.0-plugins-base` | `kmssink`、`autovideosink`、`videoconvert` | 显示输出 |

**不需要 / 装了也没用**：`mesa-va-drivers`、`libva-utils`（`vainfo` 会显示无驱动）、
`mesa-venus`、`intel-media-va-driver` ……

### 5.5 验收命令（venus probe 成功之后才跑得通）

```sh
# 1) 节点在不在
v4l2-ctl --list-devices          # 应看到 venus-decoder / venus-encoder（不是 msm_vfe!)
ls /dev/video*

# 2) FFmpeg 有没有编到 v4l2m2m 后端（先确认这步，别急着编解码）
ffmpeg -decoders 2>/dev/null | grep v4l2m2m
ffmpeg -encoders 2>/dev/null | grep v4l2m2m

# 3) 硬解验收
ffmpeg -c:v h264_v4l2m2m -i test.mp4 -f null -

# 4) mpv（写进 ~/.config/mpv/mpv.conf）
#    vd=hevc_v4l2m2m,h264_v4l2m2m,h263_v4l2m2m,vp8_v4l2m2m,mpeg4_v4l2m2m

# 5) GStreamer（抄 wiki，dmabuf 零拷贝）
gst-launch-1.0 -e filesrc location=test.mp4 ! qtdemux ! h264parse \
  ! v4l2h264dec capture-io-mode=dmabuf ! kmssink
```

---

## 6. HFI 版本裁决：**3XX，不要动**

### 6.1 证据一：本机原厂设备树白纸黑字写了 `3xx`

`evidence/stock-rom-battery/odin-stock.dts:5256`（这台 U2 Pro 的原厂 DT）：

```dts
qcom,vidc@1d00000 {
	compatible = "qcom,msm-vidc";
	reg = <0x1d00000 0xff000 0xa4124 0x04>;
	reg-names = "vidc", "efuse";
	qcom,platform-version = <0x180000 0x13>;
	interrupts = <0x00 0x2c 0x00>;
	venus-supply = <0xb8>;
	venus-core0-supply = <0xb9>;
	clocks = ...;
	clock-names = "core_clk", "core0_clk", "iface_clk", "bus_clk";
	qcom,clock-configs = <0x01 0x00 0x00 0x00 0x00>;
	qcom,hfi = "venus";
	qcom,hfi-version = "3xx";                                        ★
	qcom,reg-presets = <0xe0020 0x5555556 0xe0024 0x5555556 0x80124 0x03>;   ★
	qcom,max-hw-load = <0xff000>;
	qcom,slave-side-cp;
	qcom,sw-power-collapse;
	qcom,firmware-name = "venus";                                    ★
	...
};
```

对照主线 `core.c:902`：

```c
static const struct reg_val msm8953_reg_preset[] = {
	{ 0xe0020, 0x05555556 },
	{ 0xe0024, 0x05555556 },
	{ 0x80124, 0x00000003 },
};
```

**`qcom,reg-presets` 与主线的 `msm8953_reg_preset[]` 三组寄存器/值逐字对应** —— 说明主线的
`msm8953_res` 就是照着 msm8953 的下游配置抄的，而下游同一份配置里写着 `hfi-version = "3xx"`。

### 6.2 证据二：pmOS 现行内核的 `msm8953_res` 与我们的**逐字节完全一致**

把 pmOS 当前在用的 `msm8953-mainline/linux` tag `v7.1.3-r0` 的 `core.c` 拉下来，
与本地 6.19.5 的同一段做 diff：

```
$ diff <(sed -n '902,934p' tmp/linux-msm8953/drivers/media/platform/qcom/venus/core.c) \
       <(sed -n '902,934p' tmp/pmos-venus-probe/c-v7.1.3-r0.c)
【完全一致】
```

```c
static const struct venus_resources msm8953_res = {
	.freq_tbl = sdm660_freq_table, /* FIXME */
	...
	.max_load = 1036800,
	.hfi_version = HFI_VERSION_3XX,        ← 一模一样
	...
	.fwname = "venus.mdt", /* FIXME */     ← 一模一样
};
```

**我们跑的代码 == pmOS 跑的代码。若 3XX 是错的，pmOS 那边也该挂。**

### 6.3 证据三：pmOS wiki 标 Works

见 §5.1。Video（Hardware-accelerated video de/encoding）= **Works**，四档 SoC
（SDM450 / 625 / 626 / 632）全都标 Works。

### 6.4 旁证：HFI 1XX 是 msm8916 / msm8939 那一档，不是 msm8953

- `msm8916_res` → `HFI_VERSION_1XX` + `qcom/venus-1.8/venus.mbn`
- 2026-04/05 的 **MSM8939** venus 补丁集（LWN [1069668](https://lwn.net/Articles/1069668/) /
  [1071397](https://lwn.net/Articles/1071397/)），作者原话：
  > "It is mostly similar to **MSM8916** Venus, except it needs two additional cores to be
  > powered on before it can start decoding."
  并且补丁集里明确引了 `c50cc6dc6c48 ("media: venus: hfi_parser: Ignore HEVC encoding for V1")`
  讨论 HFI **v1** 的 HEVC 限制。

  ⇒ 1XX 对应的是 MSM8916/8939 这一代，**不是 MSM8953**。

  顺带：该补丁集的 changelog 里有
  "Clarified the reason for **missing firmware-name property** in device tree" ——
  再次印证老平台**不写 `firmware-name`** 是有意为之。

### 6.5 裁决

| 项 | 值 | 出处 |
|---|---|---|
| `hfi_version` | **`HFI_VERSION_3XX`**（保持原样） | 原厂 DT `qcom,hfi-version = "3xx"`；pmOS 逐字节一致 |
| `.fwname` | **`"venus.mdt"`**（保持原样） | 同上；原厂 `qcom,firmware-name = "venus"` |
| 固件落点 | **`/lib/firmware/venus.mdt` + `venus.b00`…`b04`** | 驱动 `request_firmware(fwname)` 原样 |
| DTS `firmware-name` | **不加** | 六台主力机型 DTS 全都没有 |

---

## 7. 那我们为什么还是 `-EIO`？（以及一个重要的自我修正）

### 7.1 ⚠️ 修正：不能用"pmOS 在 msm8953 上 Works"直接推"我们这台也该 Works"

回头查我们自己的取证 `evidence/device-probe/`（2026-08-27 采样，hostname `u2pro`，
`deviceinfo_codename="qcom-msm8953"` —— **这台机器当时跑的就是 pmOS 通用 msm8953 口**）：

```
10-driver-binding.txt:23
=== 模块加载但未使用(Used by 0) ===
veth xt_tcpudp bridge ... venus_dec venus_enc qcom_wcnss_pil qcom_q6v5_pas ...

06-hardware-detail.txt:338
--- venus ---
video0  video1  video2  video3  video4  video5

07-boot-log-peripherals.txt:397-402
video0     msm_vfe0_video0
video1     msm_vfe0_video1
video2     msm_vfe0_video2
video3     msm_vfe1_video0
video4     msm_vfe1_video1
video5     msm_vfe1_video2
```

**6 个 `/dev/videoX` 全是 `msm_vfe*` = CAMSS 摄像头，没有一个是 venus。**
`venus_dec` / `venus_enc` 虽已加载但 **Used by 0**，`05-hardware-full.txt:311` 里
`qcom-venus` / `qcom-venus-decoder` / `qcom-venus-encoder` 三条都只显示 `module`
（**没有绑定到 `1d00000.venus` 这个 platform device**）。

> **⇒ venus 在这台 U2 Pro 上跑 pmOS 时也没起来。**
> 之前"pmOS 上 msm8953 的 venus 是好的，所以是我们的问题"这个隐含前提**不成立**。
> 更可能：**pmOS 的 "Works" 是"在部分机型上 Works"，而 U2 Pro 恰好不在其中。**

### 7.2 `-EIO` 与 `Unsupported property: 0` 的精确落点

```
hfi_parser.c:383   dev_warn_once(core->dev, "Unsupported property: %x\n", property);
hfi.c:73           if (core->error != HFI_ERR_NONE) { ret = -EIO; goto unlock; }
```

`Unsupported property` 是 **`dev_warn_once`**（只打一次，**不是致命错误**），
真正的 `-EIO` 是 `core->error != HFI_ERR_NONE`。

调用链：

```
hfi_core_init(core)                       hfi.c:50
  → core->ops->core_init(core)            发 HFI_SYS_INIT
  → wait_for_completion_timeout(&core->done)
  → hfi_sys_init_done()                   hfi_msgs.c:253   （固件回 SYS_INIT_DONE）
       error = pkt->error_type
       if (error != HFI_ERR_NONE)         → 固件自己报错
       if (!pkt->num_properties)          → HFI_ERR_SYS_INVALID_PARAMETER
       rem_bytes = pkt->hdr.size - sizeof(*pkt)
       if (rem_bytes <= 0)                → HFI_ERR_SYS_INSUFFICIENT_RESOURCES
       error = hfi_parser(core, inst, pkt->data, rem_bytes)   ← 这里打的 Unsupported
  → core->error = error
  → hfi_core_init 里 error != HFI_ERR_NONE ⇒ -EIO
```

**关键机制**：`hfi_platform.c:9` 的 `hfi_platform_get()` **只认 4XX 和 6XX**：

```c
const struct hfi_platform *hfi_platform_get(enum hfi_version version)
{
	switch (version) {
	case HFI_VERSION_4XX:  return &hfi_plat_v4;
	case HFI_VERSION_6XX:  return &hfi_plat_v6;
	default:               break;
	}
	return NULL;          /* 1XX / 3XX 都走到这里 */
}
```

于是 `hfi_parser()` 开头：

```c
ret = hfi_platform_parser(core, inst);
if (!ret) return HFI_ERR_NONE;      /* 4XX/6XX 走静态能力表，直接返回 */
/* 1XX/3XX：继续，动态解析固件回的属性表 */
```

**⇒ 3XX 完全依赖固件回的 SYS_INIT_DONE 属性表**。这份表驱动读不懂，就会
先打 `Unsupported property: 0`，再在某个属性上 `rem_bytes < ret` 而返回
`HFI_ERR_SYS_INSUFFICIENT_RESOURCES` ⇒ `-EIO`。

**所以这是"固件回的话驱动听不懂"，不是"驱动选错了版本号"。**
改成 1XX 只会在另一张不对的桌子上吃同样的亏。

### 7.3 已排除的方向

| 假设 | 结论 | 依据 |
|---|---|---|
| HFI 版本选错（该 1XX） | ❌ 排除 | §6 三条证据 |
| 固件段数漏拷 | ❌ 排除 | `qcom_mdt_load()` 缺段会 `-ENOENT`；我们是过了加载关才报错 |
| 固件太大塞不进 venus_mem | ❌ 排除 | `firmware.c:114` 的 `fw_size > VENUS_FW_MEM_SIZE` 没触发 |
| venus0_core0 时钟卡死（GDSC 未 HW_CTRL） | ❌ 已修 | `gcc-msm8953.c:3869` `venus_core0_gdsc` 已有 `.flags = HW_CTRL` |
| 节点没启用 | ❌ 排除 | `venus@1d00000` 无 `status` 属性 = 默认启用；真机 dmesg 里 `sync_state() pending due to 1d00000.venus` 也在 |

### 7.4 下一步该查什么（按性价比排序）

1. **看固件镜像版本号**。`hfi_msgs.c:288` 的 `sys_get_prop_image_version()` 从
   `HFI_MSG_SYS_PROPERTY_INFO` 里 `sscanf("14:video-firmware.%u.%u-%u")` /
   `"14:VIDEO.VPU.%u.%u-%u"` / `"14:VIDEO.VE.%u.%u-%u"` 解析版本；三种都不匹配时打
   `dev_err "error reading F/W version"`。
   ⇒ 开 `dyndbg` 抓这行，直接知道我们喂进去的固件到底报什么版本：

   ```sh
   echo 'file drivers/media/platform/qcom/venus/* +p' > /sys/kernel/debug/dynamic_debug/control
   dmesg | grep -i 'venus\|F/W version'
   ```

   我们这版 venus 固件是 **2018 年 Android 7.1** 的 —— 相对主线驱动期待的可能偏老，
   这是**当前最可疑的一条**。

2. **把原始 SYS_INIT_DONE 包 dump 出来**。在 `hfi_sys_init_done()` 里临时加
   `print_hex_dump` 打 `pkt->hdr.size` / `pkt->error_type` / `pkt->num_properties` 与
   前 64 字节 `pkt->data`，一眼就能看出属性表是错位还是全零。

3. **横向对照**：找一台 pmOS 上 venus 确实 Works 的 msm8953 机型（wiki 点名的
   mido / tissot / potter / markw 都行），把它 `modem:/image/venus.*` 的
   **md5 + 段数 + 尺寸** 与我们本机的做 diff。若两者不同，直接换固件试。

4. **确认固件在 initramfs 里就位**。按 `reports/021`，`CONFIG_VIDEO_QCOM_VENUS=m`
   且模块可能在 initramfs 阶段被加载 ⇒ 固件必须跟着进 initramfs，否则
   `request_firmware` 拿不到（虽然我们这次报的不是 `-ENOENT`，但仍值得钉死）。

---

## 8. 踩坑清单

1. **`mesa-venus` ≠ Qualcomm Venus**。前者是 Mesa 的 VirtIO-GPU Vulkan 驱动
   （虚拟机 guest 用），跟视频编解码器同名不同物。别 `apt install mesa-venus`。
2. **`02-fix_hfi_packetization.patch` 里 HFI 是 Intel 的 Host Firmware Interface**，
   跟 Qualcomm Venus 的 HFI 毫无关系。grep `hfi` 会被它骗。
3. **`venus@1d00000` 没有 `status` 属性 = 默认启用**，跟 `&mpss` / `&wcnss`
   （显式 `disabled`）是两种完全不同的剧本。别照抄 `status = "okay"` 的习惯。
4. **节点标签是 `venus_mem`（reserved-memory）和 `venus@1d00000`（设备）**，
   全库搜 `&venus` 时这两个会一起冒出来，注意区分。
5. **本地 pmaports 副本是 2024-11-03 的快照**（`git log -1` → `817ed870e9`），
   比上游落后约 22 个月（上游内核已 `7.1.3-r0`）。凡涉"pmOS 现在怎么做"的结论，
   本轮都额外核了 GitLab `main` 分支与 msm8953-mainline 的对应 tag，没直接采信快照。
6. **`firmware-motorola-ocean` 的 pkgdesc 是 "Motorola Moto G7 Power"，SoC 是 SDM632**
   （msm8953 马甲），不是字面上的 "ocean = Moto Z2 Play"。同类命名漂移还有
   `firmware-samsung-j8y18lte`（Galaxy J8 2018，SDM450）。
7. **msm8953-mainline 的 `master` 分支上 `msm8953_res` 已经不存在了**（venus 节点也被删了），
   但 **tag `v7.1.3-r0` / `v7.0.9-r0` 里还在且与我们一致**。
   查这个仓库时**一定要带 tag**，拿 `master` 当"pmOS 现状"会得出完全相反的结论。
8. **我们是 SDM450 ⇒ 固件限制 1080p**，别用 4K 片源验收（SDM625/632 才支持 4Kp30 解码）。

---

## 9. 待办

- [ ] 开 venus 的 `dyndbg`，抓 `F/W version` 与 `Unsupported property` 的完整上下文
- [ ] dump `SYS_INIT_DONE` 原始包，确认属性表是错位还是全零
- [ ] 找一台 pmOS venus 确认可用的 msm8953 机型，diff `venus.*` 固件的 md5 / 段数
- [ ] 确认 `venus.mdt` + `venus.b00~b04` 已进 initramfs（按 `reports/021` 的落点规范）
- [ ] 补一篇 `027`（编号空缺）—— 本报告按用户指定落在 028

---

## 附录：本轮拉到的原始素材

全部落在 `tmp/pmos-venus-probe/`（临时目录，git 忽略）：

| 文件 | 来源 |
|---|---|
| `msm-firmware-loader-1.5.0/` | GitLab tarball（venus 软链逻辑的关键证据） |
| `upstream-msm8953-APKBUILD.txt` | GitLab `main` 分支（证实现行内核零补丁） |
| `pmos-6.11.1-core.c` / `pmos-6.11.1-msm8953.dtsi` | msm8953-mainline tag `v6.11.1-r0` |
| `c-v7.1.3-r0.c` / `c-v7.0.9-r0.c` | msm8953-mainline tag `v7.1.3-r0` / `v7.0.9-r0` |
| `msm8953-mainline-core.c` / `.dtsi` | msm8953-mainline `master`（**注意：已删 msm8953_res**） |
