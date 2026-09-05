## v0.9.4

坚果 U2 Pro（Smartisan ODIN，msm8953）主线 Linux 6.19 + Debian 12 bookworm 的移植。
相对 v0.9.3 有 148 次提交，主要成果是**音频全链路打通**、**内存与 swap 真正可用**，
以及**构建过程的可复现化**。

产物两个变体：`core`（无 GUI）与 `gui`（Plasma Mobile）。`core` 是 `gui` 的子集。

---

### 一、音频：从"完全没声"到扬声器 / 听筒 / 麦克风全通

v0.9.3 及之前 `aplay -l` 只有 `--- no soundcards ---`，`snd_soc_register_card()`
返回 `-22`。这一版一路挖到底，四个真因各不相同：

1. **声卡注册失败**：设备树里 `&sound_card` 缺 `model`。`snd_soc_register_card()`
   开头就 `if (!card->name || !card->dev) return -EINVAL`，**而且不打任何日志**；
   而 `snd_soc_of_parse_card_name()` 遇到属性缺失是静默返回 0。所以现象是
   "probe 失败但什么都不说"。补上 `model = "smartisan-odin"` 即可。
2. **ADSP 固件静默跳过**：initramfs 里的取固件脚本以 `100644` 入的库（没有执行位），
   `[ -x ]` 恒假，整段被跳过。修执行位，并在构建脚本里统一 `chmod 0755`。
   根因分析见 **reports/034**。
3. **扬声器功放不是"给高电平"**：这款 AW87318 类功放的 MODE 脚要的是
   **6 个上升沿脉冲**，不是静态高电平。原厂 `aw_speaker_pa_enable()` 打的正是
   1+5=6 次。所以从 `simple-audio-amplifier` 换成 `awinic,aw8738` +
   `mode-gpios` + `awinic,mode = <6>`，音频输入也从 `SPK_OUT` 改到 `LINEOUT_OUT`
   （照抄原厂 `{"AW_SPK_PA", NULL, "LINEOUT PA"}`）。
4. **听筒音量**：主线缺 `EAR PA Gain`，在 UCM 里用 `RX1 Digital Volume 90`
   （+6 dB）补偿。

代价最小的一课：中途有一版把声卡搞到完全注册不了，原因是 aw8738 的 DAPM 端点是
`IN`/`OUT` 而不是 `INL`/`OUTL`。dmesg 里
`ASoC: Failed to add route LINEOUT_OUT -> Speaker Amp INL(*)` —— **`(*)` 标的是
"缺失的那一端"，不是左边的那个**。当时理解反了方向，白绕一圈。

随镜像发布 `odin-audio-test.sh`（菜单式验收工具，音量按百分比、日志落
`~/audio-test.log`）。详见 **reports/026 / 032 / 033 / 034**。

### 二、内存与 swap

先回答了"4 GB 内存为什么只认到 3.46 G"：**这就是正常水位**。256 MiB 引导程序没
上报 + 205 MiB reserved-memory + 32 MiB CMA + 内核自身，真正可回收的大约只有
14 MiB。详见 **reports/035**。

swap 方面挖出两个真因：

- 原先的 `odin-swap.service` 挂在 `Before=sysinit.target` 却又 `After=` 一个
  `multi-user.target` 的 unit，**构成依赖环**，systemd 静默丢弃了整个 unit ——
  它从来没有执行过。
- 根分区**没开 extents**，而 `swapon` 的 swapfile 走 iomap，必须要有 extents。
  没有 extents 时连 `fallocate` 都用不了，只能 `dd` 写 4 GiB。

于是有了这一版最重的一块工作：**给 lk2nd（二级引导）加只读 ext4 extents 支持**
（`lk2nd/0005`）。因为 lk2nd 自己要从根分区里读出 vmlinuz / initramfs / DTB，
文件系统特性一开，它挂不上，整条引导链就断了。详见 **reports/036**。

这个专项里最值钱的产物其实是**宿主机仿真台 `tools/lk2nd-fs-sim/`**：lk2nd 的
ext2 驱动只依赖 6 个函数（`bio_read` + 5 个 `bcache_*`）和 `dprintf`，可以整个搬到
宿主机编译。于是迭代从"刷机 5 分钟 + 变砖风险"变成"本地秒级"，还能做回归矩阵。
它先把补丁打进源码副本再编译，**测的就是真正会编进 `lk2nd.img` 的那份代码**。

结果：swap 两级，swapfile 4 GiB（优先级 10，主力）+ zram 512 MiB（优先级 100，
第一级），合计 4.5 GiB。开 extents 之后 swapfile 用 `fallocate` 168 ms 建成。

### 三、ext4 metadata_csum

根分区补开 `metadata_csum`，能检出 eMMC 位翻转造成的元数据静默损坏。
它是 `ro_compat` 特性（语义即"只读挂载可忽略"），但 lk2nd 的白名单把它挡住了，
所以加了补丁 `lk2nd/0006` 放行。

**刻意不放行** `huge_file` / `dir_nlink` / `extra_isize` / `64bit` —— 它们不是
"只读可忽略"的语义，没必要为没有收益的东西放宽门禁。

### 四、initramfs 找根：把刷机后首启从 15 分 39 秒压下来

刷完这一版时首启花了 15min39s，SSH 240 秒没起来、屏幕全黑，看着像砖。
但**同一份镜像单纯 reboot 只要 48.5 秒** —— 慢的是"刷机后第一次"才有的活。

挖出两个坑：

1. `try_mount_root` 先 `findfs LABEL=pmOS_root`，失败就**在重试循环内部**去暴力扫
   57 个分区、逐个 `mount` 试。首启那次 `findfs` 和 devtmpfs 建节点撞车，一次 miss
   就掉进扫分区，而整轮扫描是在**一次函数调用里**跑完的 —— 30 秒的重试循环被它
   一个人钉死 2 分钟。
2. 三段固件各自 `remount rw + sync + remount ro`，等于 6 次 remount + 3 次全局
   `sync`。`sync` 是全局的，会把根分区所有脏页一起刷；实测每段各卡 42~70 秒。

改法：找根第 1 顺位改成按 **GPT 分区名 `userdata`**（读 sysfs 的 `PARTNAME`）——
名字写死在 GPT 里，与文件系统无关、与 `mmcblk0`/`mmcblk1` 编号无关，还完全不用
读超级块；暴力扫分区挪到 30 秒窗口彻底失败后才跑一次，并先用 `blkid -s TYPE` 筛
掉非 ext4（真机实测要 mount 的次数 **57 → 5**）；三段固件合并成一轮 remount/sync。

### 五、构建与发布工程化

- **`Makefile` 成为统一构建入口**（`make dtb` / `kernel` / `lk2nd` / `rootfs-core`
  / `rootfs-gui`），dtb / kernel / lk2nd 三段从散装脚本搬进来，依赖关系显式化，
  戳文件做增量，`.SHELLFLAGS` 补上 `-eu -o pipefail`。
- **外部仓库改子模块**，分两组：构建必需的 `ext/linux-msm8953`、`ext/lk2nd`；
  仅参考的 `ext/smartisan-kernel`（刻意不在构建中拉取）。
- **CI 缓存**：ccache 的 `compiler_check=content` + `hash_dir=false`
  （默认值的两个坑：编译器 mtime 计入哈希、CWD 计入哈希），16 个分片分别恢复保存。
- **双变体**：`core` / `gui`，CI 用 matrix 两条 job 共用同一份 kernel / dtb 产物。
- **lk2nd 找不到可启动 fs 时进 fastboot**，不再回退去引导残留的 Android 镜像。
- **venus 硬件视频编解码打通**（reports/027~030）、**触摸屏 FT8716 可用**、
  **电池与温度**、**RTC 与时间同步**（reports/023）、**电源键屏蔽**、
  **Type-C 角色切换 / OTG**。

### 六、这一版走过哪些后缀版

`v0.9.4` 之前一共发了 27 个后缀版，几个关键的节点：

| 版本 | 在试什么 |
|---|---|
| `-lk2nd-reboot` | lk2nd 循环重启排查（reports/022） |
| `-battery` | 新基线首个能跑通的版本 |
| `-touch` | 触摸屏 FT8716 |
| `-venus` / `-venus-fw` / `-venus-applets` / `-venus-usable` / `-venus-limits` | 硬件视频编解码五轮，最后一轮是纯文档（把失效形态与可用档位查清） |
| `-otg` / `-usbc` | Type-C 角色切换与 FUSB301 |
| `-audio` ~ `-audio6` / `-audio-model` / `-aw8738` / `-aw8738-2` / `-audio-ok` | 音频九轮，从"没有声卡"到全通 |
| `-swapfix` | 修 swap 建不出来（时序 + 半截文件） |
| `-extents` | lk2nd 只读 extents + 宿主机仿真台 |
| `-csum` | metadata_csum（**这一版 CI 失败：build-image.sh 的两处判断只改了一处**） |
| `-csum-gate` | 修上面那个自检掩码 |
| `-findroot` | 修 initramfs 找根，压首启耗时 |

`-csum` 那次失败值得一提：镜像本身是对的，是 `tools/build-image.sh` 里**两处**
独立判断"lk2nd 能不能挂载"——特性名清单（正向断言）改了，硬编码位掩码
`MRO=$(( RO & ~3 ))` 漏了。于是日志里出现自相矛盾："metadata_csum OK" 和
"lk2nd mountable WILL REFUSE" 同时出现。

### 七、刷机与验收

```sh
bash flash/flash-all.sh              # 00 → 90，全自动（远程进 fastboot，无需按键）
bash flash/flash-all.sh --from 40    # 从某阶段继续
bash flash/flash-all.sh --dry-run    # 只打印不真刷
```

刷完自动跑 16 项验收（内核 / 面板 / 背光 / DRM / usb0 / WiFi / 扩容…）。
另外新增 `odin-fs-verify.sh`，验那些"不出声就出错"的项：

```
1. ext4 特性位（extents / metadata_csum 必须在；64bit / huge_file /
   dir_nlink / extra_isize 必须不在）
2. lk2nd 挂载门禁（直接读超级块的 ro_compat 位，不靠特性名翻译）
3. 启动以来 EXT4-fs error 与 checksum 错误计数
4. initramfs 找根走的是快路径还是退化到暴力扫分区
5. swap 两级都在、总量 > 4 GiB
6. 启动耗时
```

### 八、已知限制

- **蜂窝网络（Modem）不可用**，也不在计划内 —— 见 reports/020 的可行性调研。
- **venus 硬件编解码有档位限制**，见 reports/030（不是所有分辨率/码率都行）。
- **`metadata_csum` 之后根分区仍不是"标准发行版 ext4"**：`64bit`、
  `huge_file`、`dir_nlink`、`extra_isize` 都还关着 —— 不是不想开，是 lk2nd 的
  ext2 驱动读不了，而它们带来的收益不足以 justify 继续给 bootloader 打补丁。
- **刷机后首次启动比后续慢**（首启要抽三段固件 + 扩容），这是预期的。

---

**产物清单**

| 文件 | 说明 |
|---|---|
| `lk2nd.img` / `lk2nd-nomarkw.img` | 刷 boot 分区的二级引导（精简版强制命中 odin） |
| `msm8953-smartisan-odin*.dtb` ×4 | 设备树（面板写死 FT8716 / 自动识别 × 有无 Type-C 角色切换） |
| `odin-debian.img` / `-sparse.img` | 系统镜像（core 变体），sparse 版给 fastboot 分块传输用 |
| `odin-debian-gui.img` / `-sparse.img` | 同上，gui 变体（Plasma Mobile） |
| `SHA256SUMS` | 全部产物的校验和 |

---

### 真机验证（2026-09-05，v0.9.4-findroot 刷入后）

**刷机后首次启动：63 秒**（12:05:57 下发 reboot → 12:07:00 SSH 可达）。
修之前同一台机器是 **15 分 39 秒**。

```
Startup finished in 16.679s (kernel) + 38.427s (userspace) = 55.107s
```

`flash-all.sh` 阶段 80 的 16 项验收：**16 通过 / 0 失败**
（内核 / 面板驱动 ft8716 / DSI connected+enabled / DRM / 背光回读 500 /
usb0 / wlan0 + wcn36xx / sshd / resize2fs / 扩容 112G / modprobe）。

`odin-fs-verify.sh` 的 14 项：**14 通过 / 0 失败**

```
1. 特性位   extents ✅  metadata_csum ✅
            64bit / huge_file / dir_nlink / extra_isize ✅ 均未开
2. lk2nd 门禁  s_feature_ro_compat = 0x403，越界位 0x000 ✅
3. 报错      0 条 EXT4-fs error、0 条 checksum 错误 ✅
4. 找根      本次只挂载 p57（根）与 p24（persist，取 WiFi 校准数据）——
             没有 p53/p54 那些，说明走的是快路径，没掉暴力扫描 ✅
5. swap      /swapfile 4G（优先级 10）+ /dev/zram0 512M（优先级 100）= 4607 MiB ✅
6. 启动耗时  55.107s ✅
```

刷前在宿主机上也验过一遍：

- `tools/lk2nd-fs-sim`（跑的是真正会编进 `lk2nd.img` 的那份 ext2 驱动）挂载本次
  镜像，成功读出 `/extlinux/extlinux.conf`、`/boot/vmlinuz`、
  `/boot/initramfs.cpio.gz`、DTB，校验和与 CI 产物逐一比对 MATCH
- 超级块校验和按内核算法重算 = `0xd59aeacc`，与镜像存储值一致
- sparse 镜像头正常，展开后 922746880 字节与 raw 一致
