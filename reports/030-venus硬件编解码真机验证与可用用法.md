# 030 — venus 硬件编解码：真机验证与可用用法

> 本文回答两个问题：**能不能用**，以及**怎么用**。
>
> 配套：`027-原厂ROM视频编解码链路调研`（Android 侧）、
> `028-postmarketOS-Venus方案调研`（pmOS 侧）、
> `029-venus硬件视频编解码全链路调研与打通`（补丁与供给机制）。
> 029 的结论在真机上全部成立，本文是它的**真机验证结果**与**用法手册**。
>
> 验证环境：v0.9.4-venus-applets（core 变体），2026-09-03 实刷真机，
> `80 verify` 16/16 通过。素材 `IMG_6626.MOV`：HEVC 1920x1440 30fps 4.97s，
> 149 帧，音频 pcm_s16le。

---

## 0. 结论速览

| 场景 | 结论 |
|---|---|
| **venus 驱动** | ✅ 已起来。dmesg 只有 0009 预期的那条 `truncated property`，**无 probe 失败** |
| **固件供给** | ✅ initramfs 从原厂 modem 分区现取成功（6 个文件），`head` applet 修复生效 |
| **硬件解码** | ✅ 可用。1920x1440 HEVC 149 帧 → **2.5 秒** |
| **硬件编码** | ✅ 可用，但**必须显式 `-pix_fmt nv12`**；1920x1440 编码 → 7.3 秒 |
| **全硬件转码** | ✅ 可用（同分辨率直通）；需要缩放时改用**两进程管道** |
| **1920x1080 编码** | ❌ 稳定段错误（rc=139），**原因未定位**，见 §5 |

**一句话：能用，但有三条硬约束（§1），且要避开 §5 的崩溃区间。**

---

## 1. 三条硬约束（缺一条就报看不懂的错）

### 1.1 用户必须在 `video` 组

`/dev/video*` 是 `root:video 660`，而镜像里 `video:x:44:` **组成员为空**。
ffmpeg 打不开设备时会**直接跳过它**继续找下一个，最后报：

```
[h264_v4l2m2m] Could not find a valid device
[h264_v4l2m2m] can't configure encoder
Error initializing output stream 0:0 -- Error while opening encoder ...
```

**报错里一个字都没提权限** —— 这是排查时最大的误导。

验证：`v4l2-ctl -d /dev/video1 --list-formats` 以 `user` 身份跑会
`Failed to open /dev/video1: Permission denied`，以 root 跑正常。

修法：`usermod -aG video user`（改完需重新登录才生效）。
> ⚠️ 本节写报告时只在真机上手工执行过，**还没进 rootfs 构建流程**（见 §7 待办 1）。

### 1.2 硬件编码必须显式 `-pix_fmt nv12`

venus 编码器只接受 NV12。源是 `yuvj420p`（iPhone 录像常见，全范围 JPEG 色域）时
ffmpeg **不会**自动插 `auto_scale` 转换，直接报：

```
[h264_v4l2m2m] Encoder requires nv12 pixel format.
```

> **为什么之前没测出来**：用 `lavfi` 合成源时像素格式是 `yuv420p`，ffmpeg 会自动
> 插入 `auto_scale` 转成 nv12，所以合成源测试里这个坑永远不出现。
> **测硬件编码必须用真实文件。**

不论源是什么格式，硬件编码一律显式写 `-pix_fmt nv12`。

### 1.3 音频：`-c:a copy` 的 `pcm_s16le` 不能进 mp4

与 venus 无关 —— 软件编码（`libx264`）同样报：

```
Could not write header for output file #0 (incorrect codec parameters ?): Invalid argument
```

用 `-c:a aac`，或不要音轨时用 `-an`。

### 1.4 三个约束的对照实验

证据：`evidence/venus/final-commands.txt`

| 变体 | 结果 |
|---|---|
| 原命令 | ❌ `Could not find a valid device` |
| 只改音频 `-c:a aac` | ❌ `Encoder requires nv12 pixel format` |
| 只加 `-pix_fmt nv12` | ❌ `Could not write header` |
| **video 组 + 两项都改** | ✅ **2539744 字节 / 7.3s** |

---

## 2. 可用命令（全部真机实测通过）

```sh
# 硬件编码（软解 + 硬编）—— 转码主路径
ffmpeg -i in.mov -c:v h264_v4l2m2m -b:v 4000k -pix_fmt nv12 -c:a aac out.mp4
#   实测：1920x1440 源 → 2539744 字节 / 7.3s

# 硬件解码（硬解 → 原始帧）
ffmpeg -c:v hevc_v4l2m2m -i in.mov -f rawvideo -pix_fmt nv12 out.raw
#   实测：1920x1440 HEVC 149 帧 → 617932800 字节 / 2.5s

# 全硬件转码（硬解 + 硬编，同分辨率直通，不要加 -vf scale）
ffmpeg -c:v hevc_v4l2m2m -i in.mov -c:v h264_v4l2m2m -b:v 4000k -pix_fmt nv12 -an out.mp4
#   实测：1920x1440 → 2487622 字节 / 7.8s

# 需要缩放时的全硬件转码 —— 拆成两进程，中间走 rawvideo 管道
ffmpeg -c:v hevc_v4l2m2m -i in.mov -vf scale=1280:720 -f rawvideo -pix_fmt nv12 - \
  | ffmpeg -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i - \
           -c:v h264_v4l2m2m -b:v 4000k out.mp4
#   实测：2580327 字节 / 17.8s
```

> **注意 `-c:v` 放 `-i` 前面才是硬件解码**：`-c:v hevc_v4l2m2m -i in.mov`。
> 放后面是硬件编码。同一个 `-c:v` 位置不同，含义完全不同。

### 不要装 `mesa-venus`

那是 VirtIO-GPU 的 Vulkan 驱动（给虚拟机用的），与裸机的 qcom venus **同名不同物**。

---

## 3. 能力清单（真机查询所得）

### 3.1 编解码格式

| 方向 | 设备 | 格式 |
|---|---|---|
| 解码输入 | `/dev/video0`（`qcom-venus-decoder`） | H264 / HEVC / VP80 / VP90 / VC1G / VC1L / MPG4 / MPG2 / H263 / XVID |
| 解码输出 | 同上 | NV12、Q08C（QCOM 压缩格式） |
| 编码输入 | `/dev/video1`（`qcom-venus-encoder`） | **NV12（唯一）** |
| 编码输出 | 同上 | H264 / VP80 / HEVC / MPG4 / H263 |

### 3.2 分辨率范围

```
编码器：stepwise 82x16 – 4096x4096，step 1/1   ← 注意最小宽度是 82，不是 16
解码器：stepwise 16x16 – 4096x4096，step 1/1
```

### 3.3 主要控制项

| 控制 | 范围 | 默认 |
|---|---|---|
| `video_bitrate` | 32000 – 160000000，step 100 | 1000000 |
| `video_bitrate_mode` | 0=VBR / 1=CBR | VBR |
| `video_gop_size` | 0 – 65535 | 30 |
| `h264_profile` | 0 – 16 | 4（High） |
| `h264_level` | 0 – 15 | 0（**Level 1**，见下） |
| `min_number_of_output_buffers` | min 4 **max 11** | 4 |

> ⚠️ `h264_level` 显示默认 Level 1，但 1920x1440 实际能编 —— 说明驱动会按分辨率
> 自行调整，这个 sysfs 值是 stale 的，**不要拿它判断能不能编**。
>
> ⚠️ `min_number_of_output_buffers` 上限 11，而 ffmpeg 的 `-num_output_buffers`
> 默认 16、下限 6。实测把它压到 11/8/6 **并不能**解决 §5 的段错误，别再试。

---

## 4. 硬件编码实测档位表

素材 `IMG_6626.MOV`，`-vf scale=W:H -c:v h264_v4l2m2m -b:v 4000k -pix_fmt nv12`：

| 分辨率 | 结果 |
|---|---|
| 1920x1440（源原尺寸） | ✅ |
| 1280x720 | ✅ |
| 854x480 | ✅ |
| 640x480 | ✅ |
| 320x240 | ✅ |
| **1920x1080** | ❌ 段错误 rc=139 |
| 1920x1072 / 1088 / 1096 | ❌ 段错误 rc=139 |
| 640x240 / 640x360 / 640x368 / 640x720 / 1280x240 | ❌ 段错误（合成源实测） |

---

## 5. 未解决：段错误（rc=139）

### 5.1 现象

- 1920x1080 一带**稳定**复现（连续 3 次以上）。
- 内核侧**零消息**：`dmesg -w` 全程跟踪，崩溃前后没有任何 venus / SMMU /
  IOMMU / Call trace 输出。**纯粹是 ffmpeg 用户态崩**，驱动没问题。
- 与分辨率不是简单的阈值关系，也不是对齐问题：1920x1088 已经是 32 的倍数，同样崩。
- 与码率、缓冲区数量无关（`-num_output_buffers` 16/11/8/6 全崩）。

### 5.2 已排除的方向（别再查）

| 假设 | 结论 |
|---|---|
| 分辨率对齐（16 / 32 的倍数） | ❌ 1088 已对齐仍崩；720、240 未对齐却通过 |
| 像素总数超限 | ❌ 1280x240（307200）崩，640x480（同为 307200）通过 |
| 缓冲区数量不足 | ❌ 放大到 16、缩小到 6 都崩 |
| 码率/级别上限 | ❌ 不带 `-b:v` 走默认也崩 |
| 驱动/固件问题 | ❌ dmesg 零消息，`--list-formats` 与控件查询全正常 |

### 5.3 一条有价值的线索：崩溃与**喂帧速度**相关

同一个 1280x720：

- 用 `lavfi` 合成源（喂帧极快）→ **崩**
- 用真实文件走软件 HEVC 解码（喂帧慢）→ **通过**

推测是 ffmpeg 的 v4l2m2m 在"入队快于出队"时的竞态。**未证实**，
要坐实得给 ffmpeg 挂 gdb 拿 backtrace（见 §7 待办 3）。

### 5.4 当前的绕行方案

1. **避开崩溃档位**：优先用 1920x1440 / 1280x720 / 854x480 / 640x480 / 320x240。
2. **需要 1080p 时**：用两进程管道（§2 第 4 条），或先用软件编码。
3. 不要用 `-vf scale` 直连硬解与硬编 —— 要么直通（同分辨率），要么拆两进程。

---

## 6. 另一条坑：venus 被强杀后会卡死，且可能拖垮整机

2026-09-03 调试时出现一次**未定位的重启**（19:41:38）。

### 6.1 已排除的

| 项 | 证据 |
|---|---|
| 内核 panic | pstore 空、无 Oops、无 Call trace |
| 看门狗 | 无 `/dev/watchdog` 设备 |
| 电池 | 61%、4.07 V、28 °C、capacity 100% |
| 温度 | 44–49 °C，正常 |
| 纯 CPU 满载 | 8 路 `sha256sum` 跑 25 秒，不重启 |
| 1920x1080 的段错误本身 | 复现了，不重启 |
| 死亡那一刻那条命令 | 干净状态下原样重跑，618 MB 正常产出 |

### 6.2 唯一的相关前置状态

```
19:28:50  qcom-venus 1d00000.venus: wait for cpu and video core idle fail (-110)
19:36:21  WARNING: venus/core.c:540 venus_remove+0xd8  x0=-22(-EINVAL)
19:41:00  最后一条日志
19:41:38  重启
```

第一条 `-110` = `-ETIMEDOUT`，是我**强杀了一个正占着编码器的 ffmpeg** 留下的 ——
venus 停在"等硬件 idle"的死等状态。

第二条是我 unbind 时触发的上游 `WARN_ON(ret < 0)`（`pm_runtime_get_sync` 返回
`-EINVAL`）。**这条是无害警告，不是崩溃原因**，但说明 `odin-venus-fw.sh` 依赖的
unbind/bind 补救路径会带出一条内核 WARN。

### 6.3 结论与操作纪律

**根因没抓到，也复现不出来。** 唯一可复用的结论是一条操作纪律：

> **调试 venus 时不要强杀 ffmpeg。** 它与 `reports/029 §7` 记的
> "卡 D 状态、`sudo reboot` 被挡住、只能长按电源键"是同一类故障。
> 卡住后只能长按电源键，代价是整轮验证作废。

---

## 7. 待办

1. **把 `user` 加进 `video` 组做进 rootfs 构建流程**（`dist/build/setup-rootfs.sh`
   或 `apply-staging-fixes.sh`），走 CI 出正式版。目前只在真机手工执行过。
2. **把 §1 的三条约束与 §2 的命令写进 `docs/03-系统使用.md`**，替换 029 之后
   那版只讲"能力"不讲"约束"的段落。
3. （可选）给 ffmpeg 挂 gdb 拿 §5 的 backtrace，坐实是不是喂帧竞态。
4. `odin-video-check.sh` 改用已验证通过的档位（现在用 640x360，
   **正好落在崩溃区间里**，所以体检脚本自己会崩 —— 见 §4）。

---

## 8. 体检脚本

```sh
sudo odin-video-check.sh            # 完整体检
sudo odin-video-check.sh --quick    # 只看固件/模块/设备/格式，不跑编解码
```

`--quick` 现在的结果（v0.9.4-venus-applets 实刷后）：**5 项全过** ——
固件齐套、模块已加载、无 probe 失败、`/dev/video0` 是 decoder、
`/dev/video1` 是 encoder。

> ⚠️ 完整体检的编码用例用的是 640x360，落在 §4 的崩溃区间，会段错误。
> 修法见 §7 待办 4。
