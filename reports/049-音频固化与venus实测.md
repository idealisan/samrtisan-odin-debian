# 049 — 音频固化进镜像 + venus 用静态 ffmpeg 实测（v0.9.11-audio）

日期：2026-09-08　设备：ODIN（Smartisan U2 Pro, msm8953）　基线：v0.9.9（kb 变体）

本文是**修复 + 实测**记录，不是只读盘点。两件事：

1. 把音频路由固化进镜像（048 报告里"音频不可用"这一项的修复）；
2. 用 arm64 静态 ffmpeg 真机跑通 venus 硬件编解码（048 里标"未验"的那一项）。

---

## 一、音频：从"手工 cset 才能响"到"刷完就有声"

### 1.1 现象（复述 048）

新刷机上 `aplay` / `arecord` 一律 `Invalid argument`；`dmesg` 里一句
`MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1, possibly missing
ALSA mixer-based routing or UCM profile`。

### 1.2 真因：路由**从来没被应用过**，不是驱动问题

三个证据：

1. **`/var/lib/alsa/` 是空的。** Debian 自带 udev 规则
   `/lib/udev/rules.d/90-alsa-restore.rules` 会在
   `ACTION=="add", KERNEL=="controlC*"` 时跑 `alsactl restore <卡号>`，
   读取的默认文件正是 `/var/lib/alsa/asound.state` —— 镜像里根本没这个文件，
   于是"恢复"每次都等于什么都没做。
2. **卡片实际用的 UCM 是错的。** `/proc/asound/card0/id` = `smartisanodin`，
   所以 alsa-lib 命中的是 `ucm2/smartisanodin/`（1091 字节那份），而正确路由
   在 `ucm2/Qualcomm/msm8953-odin/HiFi.conf`（5753 字节，reports/038 那一串
   工作的成果），只有 `conf.d/smartisan-odin/` 指向它 —— 卡片按 id 匹配，轮不到它。
   旧那份写的是 `PRI_MI2S_TX` / `ADC2`，与本机硬件（TERT_MI2S_TX / ADC1）不符。
3. **就算指过去也应用不了。** 换成 conf.d 那份正确路由后：
   - `alsaucm -c smartisan-odin set _verb HiFi` → 通过；
   - `alsaucm ... set _dev Speaker` / `set _dev Earpiece` → 一律 `Invalid argument`
     （alsa-lib 1.2.8-1+b1）。
   - 但把 Speaker 的 5 条 `cset` 逐条用 `amixer cset` 敲，**全部成功**。
     所以既不是控件名、也不是取值的问题 —— 是 UCM 的设备切换本身在这套环境里跑不通。
   - 附带一坑：正确路由里写的是 `hw:${CardId},0`，alsa-lib 报
     `variable '${CardId}' is not defined in this context`，改写成 `hw:0,0` 后
     `set _dev` 仍然 EINVAL（两件事独立）。

> 更正 045：那份报告里"麦克风/听筒/扬声器 ✅"是在**手工 cset 过**的旧机上验的，
> 路由没进镜像。048 已标注，这里给出完整根因。

### 1.3 修法：随镜像发一份 alsa 状态文件，恢复交给系统自带的 udev

- 在真机上把路由调通（扬声器 + 麦克风），`alsactl store` 落成
  `/var/lib/alsa/asound.state`（1130 个控件，178512 字节）；
- 放进覆盖树 `dist/build/rootfs/var/lib/alsa/asound.state`，随镜像发布；
- 声卡出现时由**系统自带**的 `90-alsa-restore.rules` 自动 `alsactl restore`。

**不新增任何 systemd 服务。** 时序由 udev 的 `controlC*` add 事件保证 —— 本卡
（q6afe/q6asm 那一串）大概在开机 48 s 才注册，自己写服务还得再抄一遍"等 card0
出现"的循环（项目里 odin-touchscreen.service、odin-hotkey-wait.sh 已经抄过两遍了），
而 udev 本来就是干这个的。

状态文件里的关键值（`amixer cget` 视角）：

| 控件 | 值 | 含义 |
|---|---|---|
| `PRI_MI2S_RX Audio Mixer MultiMedia1` | true | 播放后端接上 MultiMedia1 |
| `RX3 MIX1 INP1` | RX1 | 数字侧选 RX1 |
| `RX3 Digital Volume` | 84 | 0 dB（本机 `min=0 max=124`，84=0 dB） |
| `LINEOUT` | Switch | LINEOUT_OUT ← LINEOUT PA ← LINEOUT ← LINEOUT DAC ← PDM_RX3 |
| `Ext Spk Switch` | true | 外置 AW 功放使能（MODE 脚脉冲由驱动 POST_PMU 打） |
| `Earpiece Switch` / `EAR_S` / `RX1 MIX1 INP1` | false / ZERO / ZERO | 听筒通路关着 |
| `MultiMedia2 Mixer TERT_MI2S_TX` | true | 采集后端是 Tertiary，不是 Primary |
| `DEC1 MUX` / `CIC1 MUX` | ADC1 / AMIC | AMIC1 → ADC1 → DEC1 |
| `ADC1 Volume` | 8 | 增益（不开的话 RMS 只有本底） |

### 1.4 镜像层验证（不依赖真机）

v0.9.11-audio 构建完成后，把 `odin-debian-kb.img`（922746880 字节，sha256 与
SHA256SUMS 一致）用 `debugfs` 直接读：

```
debugfs -R 'ls -l /var/lib/alsa' kb.img
  18989  100644 (1)      0      0   178512  asound.state
```

再把文件 dump 出来与仓库里的源文件比 md5：

```
e71e585efe222c5a0bde53c98a80b98f  dist/build/rootfs/var/lib/alsa/asound.state
e71e585efe222c5a0bde53c98a80b98f  （镜像里 dump 出来的）
```

逐字节一致 ⇒ **路由确实进了镜像**，这一步不依赖设备是否在线。

### 1.5 实测证据（真机 v0.9.9，未重刷）

1. **复现**：把上面 5 个播放侧控件打回默认值 →
   `aplay: main:831: audio open error: Invalid argument`（与 048 报告症状逐字一致）。
2. **恢复**：`alsactl restore -f /var/lib/alsa/asound.state` →
   `aplay -D hw:0,0 t.wav` RC=0、`arecord -D hw:0,1 ...` RC=0。
3. **出声**：播放 1 kHz 正弦的同时用板载麦克风回环录音 →
   Peak **−36.1 dB**、RMS **−55.8 dB**（不是本底）；用户耳朵确认"有声音"。
4. 之后故意把 UCM 实验改动全部还原（.odin-bak 都在），`aplay` 依旧 RC=0 —— 证明
   生效的是状态文件，与我中途改过的 UCM 无关。
5. **关键一条：验证的正是要上线的那条链路。** 把 5 个播放侧控件打回默认值
   （`Invalid argument`），然后
   `udevadm trigger --action=add --subsystem-match=sound` —— 这就是开机时声卡出现、
   `90-alsa-restore.rules` 被触发的同一个事件。3 秒后五个控件全部回到状态文件里的值，
   `aplay` RC=0。也就是说：刷完镜像、声卡一注册，路由就自己就位，不需要任何手工动作。

---

## 二、venus：装个 ffmpeg 实测硬件编解码

048 里 venus 只验到"节点在、固件在、模块在"，因为没有 ffmpeg（历史 commit 6dc4255
拍板"视频工具不进 rootfs"），设备又没外网装不了包。

**绕法**：本机有网 ⇒ 下 arm64 **静态** ffmpeg 7.0.2
（johnvansickle.com，51 MB）`scp` 进设备直接跑。不进镜像，纯粹是测试工具。

### 2.1 解码：可用 ✅

```
./ffmpeg -c:v h264_v4l2m2m -i sw720.mp4 -f null -
[h264_v4l2m2m] Using device /dev/video1
[h264_v4l2m2m] driver 'qcom-venus' on card 'Qualcomm Venus video decoder' in mplane mode
frame= 40 ... speed=20.8x
```

20.8 倍实时。硬件解码确实在用 venus（不是软件解）。

⚠️ **会掉帧**：源 60 帧，默认缓冲下只出 46 帧 / 59 帧（两次跑结果不同），日志明示
`All capture buffers returned to userspace. Increase num_capture_buffers to prevent
device deadlock or dropped packets/frames`。把 `-num_capture_buffers` 调到 32 反而
**卡死**（4 分钟不返回，只能杀掉）。所以：解码能用，但**帧数不可靠**，不能拿来做
逐帧一致性比对。

### 2.2 编码：可用，但有分辨率边界 ⚠️

`h264_v4l2m2m`（`/dev/video0`）实测矩阵（NV12 输入，30 fps，1 s）：

| 分辨率 | 结果 |
|---|---|
| 320×240、640×480、800×480、1024×576 | ✅ |
| 1280×480、1280×640、1280×704、1280×736、1280×768、1280×800 | ✅ |
| **1920×1088** | ✅（507 KB / 30 帧） |
| **1280×720、640×720** | ❌ SIGBUS（ffmpeg 崩，RC=135，内核无日志） |
| 1280×240、1280×360、1280×688、1280×752 | ❌ SIGBUS |

规律：宽度 ≥ 640 时，**高度必须 32 对齐**；不满足就 SIGBUS。
（1280×240 与 640×480 像素数完全相同，前者崩后者过 ⇒ 与画面大小/内存无关，
是高度本身。）**最常见的 720p 正好踩雷** —— 要用硬件编码，先把高度补到 736/768。

另外 `vp8_v4l2m2m` / `mpeg4_v4l2m2m` 在本机直接"不支持"（RC=234）；
`hevc_v4l2m2m` 能开设备，但同样在 720 高度上 SIGBUS。

### 2.3 一句结论

- **硬件解码可用**（20.8×，会掉帧）；
- **硬件编码可用**（含 1088p），**但 720p 会崩**，用之前把高度垫到 32 的倍数；
- 之前 048 写的"实际编解码未验"到此补齐，venus 这条从"未验"变成
  **"可用 + 已知边界"**。

---

## 三、本轮改动清单

| 文件 | 改动 |
|---|---|
| `dist/build/rootfs/var/lib/alsa/asound.state` | 新增（1130 控件 / 178512 字节） |
| `WORKLOG.md` | 追加两节（音频固化、venus 实测） |

内核 / DTB / lk2nd / 其他用户态脚本**一律未动**。

---

## 五、刷机与当前状态（2026-09-09 01:10）

- **已刷**：`fastboot flash userdata odin-debian-kb-sparse.img` —— 2 段 sparse
  全部 OKAY，37 s 完成；刷前 sha256 已与 SHA256SUMS 对齐。
- lk2nd / DTB / 内核本轮**未变**，所以只刷 userdata，没动 boot 分区。
- `fastboot reboot` 之后设备**一直没上线**：ping 不通、`fastboot devices` 空、
  主机侧连 USB 以太网接口都没出现 ⇒ 不是"系统起不来"，而是**主机根本看不到这个
  USB 设备**（线松了 / 手机没开机 / 没电），需要人去按一下电源键或看一眼屏幕。
- 设备回来后跑 `tmp/verify-911-audio.sh`（脚本已备好，scp 到 `/home/user/` 即可）：
  里面**一条 amixer 都不敲**，只看控件值 + `speaker-test` + `arecord` 的 RMS，
  用来确认"刷完就有声"。

---

## 四、仍未解决 / 未验

- **听筒**：状态文件里是关着的（与扬声器互斥）。要听筒得跑
  `odin-audio-test.sh` 的 earpiece 项，或手工切路由。
- **麦克风**：采集链已固化且能录到信号，但没做过"回放人声"的主观验收。
- **GPS**：QRTR 缺 service 16(LOC)、6(PDS)，ModemManager 被 mask —— 本轮没碰。
- **venus 编码掉帧 / 720 崩溃**：只做到现象与边界，没有继续往内核/固件层面查。
- **OTG 外接存储、三键按键事件**：仍需人工插线 / 按键。
