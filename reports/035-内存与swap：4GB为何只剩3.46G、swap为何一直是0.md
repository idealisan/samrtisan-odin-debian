# 035 — 内存为什么只有 3.46 GiB，以及 swap 为什么一直是 0

日期：2026-09-05
真机：`v0.9.4-aw8738-2`（内核 `6.19.5-postmarketos-qcom-msm8953`）

---

## 0. 结论先说

| 问题 | 结论 |
|---|---|
| 内存 4 GiB 只识别 3.46 GiB | **不是故障。** 256 MiB 是 bootloader 没报成 RAM（SoC 32 位地址空间的固有取舍）；205 MiB 是 modem/ADSP/WiFi/视频/开机画面的保留内存；32 MiB 是 CMA。可优化空间只有零头（十几 MiB）。 |
| swap 一直是 0 | **两个独立的毛病叠在一起**：① unit 因 systemd 依赖环被**静默丢弃**，脚本一次都没跑过；② 即使跑了也建不起来 —— 根分区 ext4 关掉了 extents，而 swapfile 需要 extents。已改用 zram。 |

---

## 1. 内存：4 GiB → 3.46 GiB 逐项拆解

### 1.1 内核看到的物理内存只有 3840 MiB

`msm8953.dtsi` 里内存节点的基址是**写死的**，大小由 bootloader 填：

```dts
	memory@10000000 {
		device_type = "memory";
		/* We expect the bootloader to fill in the reg */
		reg = <0 0x10000000 0 0>;
	};
```

真机上读 `/proc/device-tree/memory@10000000/reg` 的**原始字节**（注意 `od -tx8` 在 ARM64 上按小端解释，会骗人，必须用 `-tx1` 逐字节看）：

```
00 00 00 00 10 00 00 00 | 00 00 00 00 70 00 00 00     bank0: base=0x10000000  size=0x70000000 = 1792 MiB
00 00 00 00 80 00 00 00 | 00 00 00 00 80 00 00 00     bank1: base=0x80000000  size=0x80000000 = 2048 MiB
                                                      合计                              = 3840 MiB
```

两个 bank 首尾相接（0x10000000 + 0x70000000 = 0x80000000），等价于一段
`0x10000000..0x100000000` 的 3840 MiB。

**头一刀：0x0–0x10000000 这 256 MiB 没被报成 RAM。** 这是 SoC 32 位地址空间的
固有取舍（低地址段要给 modem / TZ / 外设窗口让位），不是我们配置错了，
也不能靠改设备树安全地拿回来 —— 那是 bootloader 报上来的事实。

### 1.2 reserved-memory 又吃掉 205 MiB

`dmesg` 里逐条列出（nomap non-reusable，KiB）：

| 区域 | 大小 | 用途 |
|---|---|---|
| mpss | 106 MiB | **modem**，最大头 |
| other-ext | 30 MiB | TZ / 其他核 |
| cont-splash | 20 MiB | 开机连续画面（见 §1.4） |
| adsp | 17 MiB | 音频 DSP |
| qseecom | 8 MiB | 安全世界 |
| wcnss | 7 MiB | WiFi |
| venus | 7 MiB | 视频编解码 |
| reserved | 4 MiB | 通用保留 |
| gps | 2 MiB | GPS |
| rmtfs | 1.5 MiB |  modem 文件系统共享内存 |
| smem / mba | 各 1 MiB | 共享内存 / modem 引导认证 |
| ramoops | 1 MiB | 崩溃日志（我们自己的 DTS 加的） |
| zap / dfps-data | ~0 | — |
| **合计** | **205 MiB** | |

### 1.3 总账

```
  4096 MiB   物理内存
−  256 MiB   bootloader 没报成 RAM（0x0–0x10000000）
= 3840 MiB   内核看到的物理内存
−  205 MiB   reserved-memory（modem 106 占大头）
−   32 MiB   CMA（视频 / DMA 连续内存，dmesg: cma: Reserved 32 MiB at 0xf9c00000）
−   58 MiB   内核自身（代码/数据/页表）
= 3545 MiB   MemTotal = 3629956 kB = 3.46 GiB
```

内核启动那行也对得上：
`Memory: 3583872K/3932160K available (... 309124K reserved, 32768K cma-reserved)`
—— 3932160K = 3840 MiB。

### 1.4 还有没有可抠的

- **cont-splash 20 MiB**：我们的 `simple-framebuffer` 只用 `1920×1080×3` ≈ 6.2 MB，
  但 `msm8953.dtsi` 里预留了 `0x13ff000` ≈ 20 MiB。浪费约 14 MiB。
  （`patches/0007` 里**没有**改写这个节点 —— 实测 `grep 90001000` 在补丁里没有命中。）
- **ramoops 1 MiB**：可调小，但拿不回来多少，还会丢崩溃日志的价值。
- **CMA 32 MiB**：可以降到 16 MiB，但会影响视频/显示。

都是零头。**总量上 3.46 GiB 就是这台机器的正常水位**，原厂安卓走的是同一份
内存映射，不会比这多。

---

## 2. swap：两个毛病叠在一起

现象：`swapon --show` 空、`/proc/swaps` 空、`free` 里 Swap = 0，
而服务是 `enabled` 的。

### 2.1 毛病一：unit 被 systemd 静默丢弃（依赖环）

**内核日志里其实写得很清楚**，只是之前只盯着 `journalctl -u`，没往 dmesg 看：

```
systemd[1]: sysinit.target: Found ordering cycle on odin-swap.service/start
systemd[1]: sysinit.target: Job odin-swap.service/start deleted to break
                            ordering cycle starting with sysinit.target/start
```

环是这样闭上的：

```
odin-swap.service          After=local-fs.target odin-firstboot-resize.service
                           Before=sysinit.target
                           WantedBy=sysinit.target
odin-firstboot-resize.service   WantedBy=multi-user.target
```

    sysinit.target → odin-swap → firstboot-resize → multi-user.target → sysinit.target

systemd 的破环手段是**把本 unit 整个丢掉**。于是：

- `journalctl -u odin-swap.service` → **0 条记录**
- `/var/log/odin-swap.log` → **文件根本不存在**
- `systemctl status` → `Active: inactive (dead)`
  （`Type=oneshot` + `RemainAfterExit=yes` 成功跑完应该是 `active (exited)` ——
   `inactive (dead)` 就是"从没跑过"的指纹）

**教训**：`WantedBy=sysinit.target` + `Before=sysinit.target` 的单元，绝不能
`After` 一个属于 `multi-user.target` 的单元。改完要用 `journalctl -u` 确认
**有**记录才算真的跑过。

### 2.2 毛病二：swapfile 在本机根本建不起来

手动跑脚本，`swapon` 失败：

```
swapon: /tmp/t.swap: found signature [pagesize=4096, signature=swap]
swapon: /tmp/t.swap: pagesize=4096, swapsize=268435456, devsize=268435456
swapon: /tmp/t.swap: swapon failed: Invalid argument
```

而且**内核不打任何日志** —— 既不走 `iomap_swapfile_fail()` 的 `pr_err`，
也不走 "Cannot find a single usable page in file." 的 `pr_warn`。只剩
util-linux 那句 Invalid argument，极难定位。

对照实验（都在 loop 上）：

| 场景 | 结果 |
|---|---|
| `swapon` 块设备（loop） | ✅ 成功 |
| `swapon` zram | ✅ 成功 |
| ext4 **带 extents** 上建 swapfile | ✅ 成功 |
| 根分区（**无 extents**）上建 swapfile | ❌ Invalid argument |

根分区的 ext4 特性实测（**注意没有 `extent`**）：

```
Filesystem features: has_journal ext_attr resize_inode dir_index filetype
                     needs_recovery flex_bg sparse_super large_file
```

根分区关掉 extents 是有原因的：`/extlinux/extlinux.conf` 在根文件系统里，
**lk2nd 要读它**，而 lk2nd 只有 ext2 驱动，读不了 extents
（`tools/build-image.sh` 里 `mke2fs -O ^extents`）。所以这个约束动不了，
swapfile 这条路在本机是死的。

### 2.3 改用 zram

`CONFIG_ZRAM=m` 已在，且实测可用。zram 是**压缩的内存**交换：

- 不写 eMMC → 不磨损闪存、比 eMMC swap 快几个数量级
- 不碰磁盘 → 不依赖 resize2fs → 依赖环自动消失
- 安卓手机用的就是它

改动：

| 文件 | 改动 |
|---|---|
| `odin-swap.sh` | 重写为 `start`/`stop`，默认 1 GiB 逻辑容量、`swapon -p 100`，可用 `ODIN_ZRAM_SIZE` 覆盖；失败一律不致命 |
| `odin-swap.service` | `WantedBy=swap.target` + `Before=swap.target`，去掉 `After=odin-firstboot-resize.service` |
| `99-odin-swap.conf` | `vm.swappiness` 20 → 80（原值为"eMMC 磨损"而设，zram 是内存没有磨损问题；早换出反而给文件缓存腾物理内存） |

代价：zram 占的是内存，压缩后约为逻辑容量的 1/3 —— 1 GiB 逻辑容量塞满时
实际约占 300 MiB。

### 2.4 实测

`systemd-analyze verify` 通过（无环）；`systemctl start` 成功；**重启后**：

```
NAME       TYPE       SIZE USED PRIO
/dev/zram0 partition 1024M   0B  100

               total        used        free
Swap:          1.0Gi          0B       1.0Gi

● odin-swap.service   Active: active (exited)      ← 以前是 inactive (dead)
journal -u odin-swap  有记录
swappiness = 80
```

---

## 3. 证据

- `evidence/mem-swap-audit-20260905.txt` —— 内存与 swap 现状、reserved-memory 清单
- `evidence/swap-why-20260905.txt` —— swapon 报错、extents 对照实验
