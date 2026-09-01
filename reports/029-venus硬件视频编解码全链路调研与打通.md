# 029 — venus 硬件视频编解码全链路调研与打通

> 目标：让 ODIN（msm8953）的硬件视频编解码真正可用，最终能由 **FFmpeg** 调用。
>
> 配套：`027-原厂ROM视频编解码链路调研`（Android 侧）与
> `028-postmarketOS-Venus方案调研`（pmOS 侧）。本报告是两者的收敛与真机落点。

---

## 0. 结论速览

| 环节 | 结论 |
|---|---|
| venus 硬件 | msm8953 的 Venus（HFI **3xx**），解码 4K30 hevc/h264/vp8/vp9，编码 4K30 hevc/h264 |
| 内核驱动 | 主线 `CONFIG_VIDEO_QCOM_VENUS=m`（pmOS 配置已开），DT 节点 `1d00000.venus` 默认启用 |
| 固件 | `venus.mdt` + `venus.b00~b04`，来自**原厂 modem 分区**的 `/image/` |
| 原来的故障 | 固件回的 SYS_INIT_DONE 属性表**尾部一条被截断 8 字节**，主线的 `hfi_parser()` 把它当致命错误 ⇒ `hfi_core_init()` 返回 `-EIO` ⇒ probe 失败 |
| 修法 | `patches/0009`：TLV 遍历遇到"声明长度超出报文余量"就当属性表结束，`break` + `dev_warn_once` |
| 用户态 | **V4L2 M2M**（不是 VA-API）→ `ffmpeg -c:v h264_v4l2m2m`，装 `ffmpeg` + `v4l-utils` |
| 固件供给 | initramfs 的 `switch_root` 之前现取（正确时序）+ 用户态 systemd 兜底（venus 是模块，可重载补救） |

⚠️ 本报告的"修完是否真的能编解码"一节（§7）在真机验证前是**空的** ——
验证时我自己的调试代码把设备搞成了半关机状态，需要人工长按电源键后才能补。
补丁与脚本本身已提交。

---

## 1. 两条参考系

### 1.1 postmarketOS 给 msm8953 / 小米设备的方案（详见 028）

- **HFI 版本就用 `HFI_VERSION_3XX`，不要改成 1XX。** 本机原厂 DT
  （`evidence/stock-rom-battery/odin-stock.dts:5256`）明写 `qcom,hfi-version = "3xx"`；
  且原厂的 `qcom,reg-presets` 三组寄存器与主线 `msm8953_reg_preset[]` **逐字对应**
  —— 主线这份资源表就是照着同一类设备抄的。1XX 属于 msm8916/msm8939 那一代。
- **固件路径是裸的 `/lib/firmware/venus.mdt`**（没有 `qcom/` 前缀）。
  主线 `msm8953_res.fwname = "venus.mdt" /* FIXME */` 里那个 FIXME 就是"上游没定
  正式路径"，pmOS 也是这么放的（与 `firmware-motorola-ocean`、
  `firmware-samsung-j8y18lte` 的段文件数量完全吻合）。
- **DTS 里不要加 `firmware-name`**：pmaports 里六台主力 msm8953 机型的 DTS 全无
  `&venus` 覆盖，节点本来就没有 `status` 属性（= 默认启用）。
  pmaports 对 venus **零补丁、零 DTS 改动**。
- **用户态走 V4L2 M2M**，不是 VA-API。
- ⚠️ **重要的前提更正**：pmOS 在 msm8953 上 **venus 同样没起来**。
  本机 8-27 的取证里 6 个 `/dev/videoX` 全是 `msm_vfe*`（摄像头），
  `venus_dec/enc` 的 `Used by` 是 0。所以"pmOS 行、我们不行"这个前提不成立 ——
  能参考的是它的**配置与固件约定**，不是"它能跑通"这件事。

### 1.2 原厂安卓包里的视频链路（详见 027）

- **固件只在 modem 分区**。`NON-HLOS.bin` 是**裸 FAT16**（不是 MBN 容器），
  `/IMAGE/VENUS.MDT` + `VENUS.B00~B04`。system 分区里一个 venus 固件都没有。
  固件是 Venus332 / HFI 3xx，PAS_ID=9。
- **原厂 DT**（`qcom,vidc@1d00000`）：`qcom,hfi-version = "3xx"`、
  `max-hw-load 1044480`、allowed-clock-rates 465/400/360/310/228.57/114.29 MHz；
  `venus_region` = 8 MiB、reusable、alloc-ranges `0x80000000~0x90000000`，
  挂在独立 PIL 设备 `qcom,venus@1de0000` 上；四个 IOMMU 域（venus_ns /
  sec_bitstream / sec_pixel / sec_non_pixel）。
- **`media_codecs.xml` 声明的能力**：解码 4K30（hevc/h264/vp8/vp9）、
  1080p（mpeg4/wmv/vc1/divx/mpeg2）、864x480(h263)、720x480(divx311)；
  编码 4K30（hevc/h264）+ 1080p30（mpeg4/vp8）+ 864x480(h263)。
  安全路径是 `OMX.qcom.video.decoder.avc.secure` 这类带 `.secure` 后缀的组件
  （主线不走安全路径，忽略）。

### 1.3 两条参考系给出的关键差异

| 项 | 原厂 Android | 主线 Linux | 是否需要处理 |
|---|---|---|---|
| venus 内存窗口 | 8 MiB @ `0x80000000~0x90000000`，reusable | `venus_mem` 7 MiB @ `0x91400000`，nomap | 否（主线窗口够放固件，实测固件 917 KB） |
| IOMMU 域 | 4 个（ns + 3 个 secure） | 1 个 `apps_iommu 0x16` | 否（不走安全路径） |
| PIL 设备 | 独立 `qcom,venus@1de0000` 带总线投票 | 由 venus 驱动自己 `qcom_mdt_load` + `qcom_scm_pas_auth_and_reset` | 否（实测 boot 成功，见 §4） |
| 寄存器预设 | `qcom,reg-presets` 三组 | `msm8953_reg_preset[]`，在 `venus_set_reg_preset()` 里用 | 已对齐 |
| OPP | 频率表 6 档 | `venus_opp_table` 存在但**未绑**到节点 | 否，见 §6.1 |

---

## 2. 真机故障现象

```
[   35.223821] qcom-venus 1d00000.venus: Unsupported property: 0
[   35.257573] qcom-venus 1d00000.venus: probe with driver qcom-venus failed with error -5
```

`-5` = `-EIO`。此前 WORKLOG 记的推断是"固件与驱动协议不匹配、不是缺文件的问题"。
**这个推断部分正确、部分错了**：固件文件确实是对的，协议交互也走了大半，
但原因不是"协议不匹配"，而是**属性表末尾一条被截断**（§4）。

---

## 3. 取证方法（可复用）

不改一行正式代码就能看到固件到底说了什么：

1. 只在 `tmp/linux-msm8953/` 这棵树里给 venus 驱动加调试打印
   （**不进 `patches/`**，原文件留 `*.odin-bak`）；
2. 在容器里只编模块，5 秒出结果：
   ```
   docker exec odin-dev bash -c 'cd /work/odin-work/tmp/linux-msm8953 && \
     make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
          M=drivers/media/platform/qcom/venus modules -j8'
   ```
   （这棵树编译出来的 `include/config/kernel.release` 真机上是
   `6.19.5-postmarketos-qcom-msm8953+`，与正在跑的内核**逐字相同**，
   所以编出来的 `.ko` 可以直接 `insmod` 到真机上）
3. `rmmod venus_core` + `insmod /tmp/venus-core.ko`，`dmesg` 抓；
4. 把 dmesg 里的十六进制转储拉回宿主机，用 Python 还原成字节，
   **离线复现 `hfi_parser()` 的游标推进**，与真机 trace 逐步比对。

第 4 步是关键：光看十六进制猜不出问题，把解析过程跑一遍就一目了然
（`tmp/venus/replay_hfi.py` / `tail.py` / `analyse.py`）。

> ⚠️ 打印会拉慢启动：真机的串口控制台同步输出，十六进制转储一行要 ~8.7 ms，
> 一个 2576 字节的报文要打印 1.4 秒。等 probe 结果要留足时间。

---

## 4. 抓到的回包与断点

```
ODIN-INITDONE hdr.size=2576 pkt_type=0x20001 error_type=0x0 num_properties=76
payload 2560 字节 / 640 word
驱动共走 89 步：真属性 79 个，零填充 10 个
```

最后几步（这是驱动自己打的 trace）：

```
ODIN-PROP idx_rem=28  property=0x100e ret=8     ← CODEC_MASK (VP8/MPEG1, DEC)
ODIN-PROP idx_rem=16  property=0x100e ret=8     ← 又一条？不，见下
ODIN-PROP idx_rem=12  property=0x1007 ret=20    ← CAPABILITY，剩 12 字节要 20
```

报文最后 4 个 word（文件偏移 `0x0a00` 起）：

```
07 10 00 00  01 00 00 00  14 00 00 00  10 00 00 00
│            │            │            └─ min = 16
│            │            └────────────── capability_type = 0x14 = LCU_SIZE
│            └─────────────────────────── num_capabilities = 1
└──────────────────────────────────────── 0x1007 = CAPABILITY_SUPPORTED
                                          ← 缺 max 与 step_size，共 8 字节 →
```

`struct hfi_capability` 是 4 个 u32（type/min/max/step），20 字节里
头 4 字节是 `num_capabilities`，后面 16 字节是那一条 capability ——
而报文在写完 `type` 与 `min` 之后就结束了。

对照紧邻的上一条（功能等价、完整的那一条）：

```
word 627: CAPABILITY_SUPPORTED  num=1  { 0x14, 0x10, 0x10, 0x01 }
word 636: CAPABILITY_SUPPORTED  num=1  { 0x14, 0x10,  ???   ???  }  ← 尾部截断
```

**离线复现的游标与主线的 89 步 trace 逐步对齐，无一处不符** ⇒ 不是解析错位，
是报文尾部确实短了 8 字节。

### 失败链条

```
hdr.size = 2576  ⇒  rem_bytes = 2576 - sizeof(struct hfi_msg_sys_init_done_pkt) = 2560
hfi_parser() 走 89 步，第 89 步：
    property = 0x1007，rem_bytes = 12
    parse_caps() 返回 ret = 4 + 16*1 = 20
    if (rem_bytes < ret)  →  return HFI_ERR_SYS_INSUFFICIENT_RESOURCES   ← 原逻辑
hfi_sys_init_done()  →  core->error = HFI_ERR_SYS_INSUFFICIENT_RESOURCES
hfi_core_init()      →  core->error != HFI_ERR_NONE  →  return -EIO       (hfi.c:73)
venus_probe()        →  probe with driver qcom-venus failed with error -5
```

### 顺带澄清：`Unsupported property: 0` 是**噪音**，不是故障

属性 0 落在 `hfi_parser()` 的 `default` 分支，`ret = 0`，然后 1 word 1 word 地往前挪，
**不影响结果**。固件在属性之间插了 3 处零填充（4/4/2 个 word），
驱动就是这么蹭过去的。真正的故障是最后那条 `rem_bytes < ret`。

---

## 5. 修复：`patches/0009`

```c
-		if (ret < 0 || rem_bytes < ret)
+		if (ret < 0)
 			return HFI_ERR_SYS_INSUFFICIENT_RESOURCES;
 
+		/* 固件能力表可能在最后一个属性处被截断（…） */
+		if (rem_bytes < ret) {
+			dev_warn_once(core->dev,
+				      "truncated property %#x: need %d bytes, %u left\n",
+				      property, ret, rem_bytes);
+			break;
+		}
+
 		words += ret / sizeof(u32);
 		rem_bytes -= ret;
```

理由：`hfi_parser()` 是一个**按剩余字节数推进的 TLV 遍历**。当某条属性的声明长度
超出报文余量时，唯一合理的处置就是把它当作属性表结束 —— 前面 78 条能力
（各 codec 的 raw format、capability、profile/level、buf mode、interlace）
**全部已经解析进 `core->caps[]`，有效**；不该为了末尾这一条残缺把整个 core init
否掉，那等于让硬件编解码整体不可用。

代价：最后一个 codec 分组（这条是 VP8/MPEG1 解码）少一条 `LCU_SIZE` 能力值。
`HFI_CAPABILITY_LCU_SIZE` 只对 HEVC 有意义，HEVC 那条在前一步已经完整解析到了
（`{0x14, min=16, max=16, step=1}`），所以实际影响可忽略。

`ret < 0` 仍然返回错误 —— 那是 `parse_raw_formats()` 的 `-EOVERFLOW` 之类，
属于"固件说了明显不合理的话"，与"尾部残缺"是两回事，不该一起放过。

---

## 6. 两条被排除的怀疑（别再查）

### 6.1 `venus_opp_table` 是"孤儿"—— 不是问题

`msm8953.dtsi` 的 venus 节点里定义了 `venus_opp_table: opp-table`，
却唯独**没有** `operating-points-v2 = <&venus_opp_table>;`（sdm845 是有的）。
看着像上游漏了，实际不影响：

- V3 走 `core_get_v1()`，它只做 `devm_pm_opp_set_clkname(dev, "core")`，
  **从不调用** `devm_pm_opp_of_add_table()` ——
  后者只在 `res->opp_pmdomain` 存在时才调（`pm_helpers.c:1000`），
  而 msm8953 没有 cx 电源域。所以就算 DT 里写了 `operating-points-v2` 也没人读。
- 而 OPP 核心对**空表**有专门兜底（`drivers/opp/core.c:1435`）：
  ```c
  if (!_get_opp_count(opp_table)) {
          return opp_table->config_clks(dev, opp_table, NULL, &target_freq, false);
  }
  ```
  即 `dev_pm_opp_set_rate()` 退化成 `clk_set_rate()`。
  ⇒ `load_scale_v1()` → `core_clks_set_rate()` → 时钟照调，**不会失败**。
- 另外 `core_clks_enable()` 对 V3 压根不调 `clk_set_rate()`（只对 V6 与
  lite-V4 调），只 `clk_prepare_enable()`；频率是后面 `load_scale` 时才设的。

### 6.2 HFI 版本 —— 就用 3XX，不要动

见 §1.1。原厂 DT 明写 `3xx`，寄存器预设与主线逐字对应。

---

## 7. 修完是否真的能编解码 —— **待验证**

（补丁已提交，真机验证还没做。验证时我自己的调试代码 deref 了一个内部指针，
触发空指针 Oops，IRQ 线程 `irq/84-venus` 死掉、`insmod` 卡在 D 状态，
`sudo reboot` 被它挡住没能完成，设备停在"网络在、SSH 已停"的半关机状态，
已语音提醒长按电源键。设备回来后补这一节。）

验证步骤（已写好脚本，见 §9）：

1. `rmmod venus_core` + `insmod /tmp/venus-core.ko`（只含 0009 的干净模块）
2. 看 `dmesg`：应只剩一条
   `truncated property 0x1007: need 20 bytes, 12 left`，**不再有** probe 失败
3. `ls /dev/video*` —— 应出现两个新设备（decoder / encoder）
4. `v4l2-ctl -d /dev/videoN --list-formats` —— 应列出 H264 / HEVC / VP8 / VP9 等
5. `ffmpeg -c:v h264_v4l2m2m` 真编一帧、再解回来

---

## 8. 固件供给

此前 `venus.mdt`/`venus.b00~b04` 是我**手工**从 `modem:/image/` 拷进
`/lib/firmware` 的，没有任何供给机制 —— 重刷一次就没了。已按 `reports/021`
的规矩补齐：

| 文件 | 作用 |
|---|---|
| `dist/build/initramfs/sbin/odin-venus-fw.sh` | **正确时序**：`switch_root` 之前从 modem 分区现取 |
| `dist/build/initramfs/init` | 调用它的钩子（与 `odin-wlan-fw.sh` 并列） |
| `dist/build/rootfs/usr/local/sbin/odin-venus-fw.sh` | 用户态兜底，取完 `modprobe -r` + `modprobe` 重载 |
| `dist/build/rootfs/etc/systemd/system/odin-venus-fw.service` | 上面那个的 oneshot service |

为什么必须在 initramfs（与 `odin-wlan-fw.sh` 同源同理）：
venus 是 platform 驱动，开机早期就被 udev 加载并立刻 `request_firmware("venus.mdt")`。
放到 systemd 的 late service 里做就晚了 —— 驱动那次请求失败后不会自己重试。

为什么要额外留一条用户态兜底：venus 是**模块**，与 remoteproc 不同，
缺固件导致 probe 失败后重载一次就能补救。这条兜底让**已经刷好的机器**
（initramfs 里还没有这段）也能拿到硬件编解码能力。

两个脚本都不写死段文件列表 —— 段数量随 ROM 版本可能变，
把 `modem:/image/` 下所有 `venus.*` 都搬过去（**大小写不敏感**：FAT 目录项里是
大写 `VENUS.MDT`，而挂载后小写也可用）。校验只认 `venus.mdt`：
段表在 `.mdt` 里，内核的 `qcom_mdt` 会按表去取各 `.bXX`。

固件本身已核对无误：真机 `/lib/firmware/venus.*` 与原厂 ROM 的
`NON-HLOS.bin`（裸 FAT16）里 `/IMAGE/VENUS.MDT + VENUS.B00~B04` md5 逐个相等：

```
venus.mdt  afb361669ab2ae3d92c94d101e1db72b    6812 字节
venus.b00  3ae53e72639241af332066d4acc04bd4     212 字节
venus.b01  6349df477c3bb07cf3f1d078d815eb44    6600 字节
venus.b02  f9fb73a1eeab7434fe8a204060176e73  903464 字节
venus.b03  42a9b3b157465aa7cb0bc631528b2400   29048 字节
venus.b04  0d68af0904dd698b16ffc9cd28b9b0c8      32 字节  ← 0xdeadadd0 填充，极易漏
```

---

## 9. 用户态：FFmpeg 怎么调

主线 qcom-venus 暴露的是 **V4L2 M2M** 设备（decoder / encoder 各占一个 `/dev/videoX`），
**不是 VA-API**。裸机上没有 mesa 后端会去接管它。

```sh
# 编码（用 venus 的 H.264 编码器）
ffmpeg -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=10 \
       -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 4M out.mp4

# 解码
ffmpeg -c:v h264_v4l2m2m -i in.mp4 -f rawvideo -pix_fmt nv12 out.raw

# 转码（硬解 → 硬编）
ffmpeg -c:v hevc_v4l2m2m -i in.mkv -c:v h264_v4l2m2m -b:v 4M out.mp4
```

需要的 Debian 包：`ffmpeg` `v4l-utils`（已加进 `setup-rootfs.sh` 的基础包清单）。

⚠️ **不要装 `mesa-venus`** —— 那是 VirtIO-GPU 的 Vulkan 驱动（给虚拟机用的），
与裸机的 qcom venus **同名不同物**。

排障工具就是 `v4l2-ctl`：

```sh
v4l2-ctl --list-devices           # 哪个 /dev/videoX 是 venus
v4l2-ctl -d /dev/videoX --list-formats
```

体检脚本：`dist/build/rootfs/usr/local/sbin/odin-video-check.sh`
（看固件 / 模块 / 设备 / 格式 + 真跑一次编码再解回来；
`--quick` 只做静态检查不跑编解码）。

---

## 10. 待办

1. 设备回来后跑 §7 的验证，把结果补进去；
2. 把"硬件编解码怎么用"写进 `docs/03-系统使用.md`；
3. 走 CI 出带 0009 的正式版。
