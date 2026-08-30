# RTC：postmarketOS 的完整流程，与本机改造

## 一句话结论

pmOS 在 msm8953（含小米 markw）上**完全不把 RTC 当"时钟"用**，只当它是一个
一直在走的计数器：内核开机不读、NTP 校正后不写，跨重启的连续性交给用户态
的 `swclock-offset`（关机把「系统时间 − RTC」存文件，开机 RTC + 偏差还原）。
本机实测"RTC 能读、不能写"与之完全吻合，所以照同样的**流程**改造，
但用户态那一环改用 Debian 自带的 `fake-hwclock` —— 同样是写文件，
没必要自己维护一份脚本。

参考源码（本次干净全量克隆，落在 `tmp/pmos-refs/`）：

| 仓库 | 地址 | 用途 |
|---|---|---|
| pmaports | https://gitlab.com/postmarketOS/pmaports.git | markw 设备包、msm8953 SoC 包、内核配置 |
| linux-postmarketos-qcom-msm8953 | https://gitlab.com/postmarketOS/linux-postmarketos-qcom-msm8953.git | 官方内核与设备树 |
| swclock-offset | https://gitlab.postmarketos.org/postmarketOS/swclock-offset | 存文件方案的实现（不在 pmaports 里，是独立仓库） |

---

## 一、pmOS 的流程，逐层拆开

### 第 1 层：SoC 包把方案钉死

`pmaports/device/community/soc-qcom-msm8953/APKBUILD`：

```sh
depends="$pkgname-ucm swclock-offset"
```

markw 的设备包 `device/community/device-xiaomi-markw/APKBUILD` 的 depends 里
就有 `soc-qcom-msm8953`，所以**整系 msm8953 机型都会装上 swclock-offset**。

全仓共 14 个设备 / SoC 包依赖它：msm8916、msm8226、msm8953、msm8974、
sdm660、sdm845、sm7150、sc7280、sm8350，以及 klte、miatoll、elish、
lenovo-q706f、fairphone-fp4。

### 第 2 层：内核完全不碰 RTC 的读写

`device/community/linux-postmarketos-qcom-msm8953/config-postmarketos-qcom-msm8953.aarch64`：

```
# CONFIG_RTC_HCTOSYS is not set
# CONFIG_RTC_SYSTOHC is not set
CONFIG_RTC_DRV_PM8XXX=m
```

- `HCTOSYS` 关 ⇒ 开机内核不从 RTC 取时间，系统时钟从 1970 起步，
  之后被 systemd 顶到它内置的 epoch（systemd 包的打包日期，实测是 2026-04-27）。
- `SYSTOHC` 关 ⇒ NTP 校正后不回写 RTC，校正结果只在内存里。
- 驱动编成模块 `=m`，装载后 `/sys/class/rtc/rtc0/since_epoch` 可读 ——
  用户态正是拿它当"单调计数器"。

我们这份 `config-postmarketos-qcom-msm8953.aarch64` 与之逐项一致（RTC 部分）。

### 第 3 层：设备树不加 allow-set-time

主线里所有 msm8953 机型（daisy / mido / tissot / vince / potter / rimob /
markw）**没有一个**用 `allow-set-time`（全主线只有 pmp8074 用过）。
pmOS 的内核分支里同样没有 —— 官方从未试图让内核或用户态真写 RTC 寄存器。

### 第 4 层：用户态 swclock-offset 存「偏差」

包描述写得很直白：*"Keep system time at an offset to a non-writable RTC"*
—— 官方就是按"RTC 不可写"来设计的。两个脚本：

```
swclock-offset-boot：
    hwclock_epoch = $(cat /sys/class/rtc/rtc0/since_epoch)
    offset_epoch  = $(cat /var/cache/swclock-offset/offset-storage)
    date -u -s @$((hwclock_epoch + offset_epoch))

swclock-offset-shutdown：
    swclock_epoch = $(date -u +%s)
    hwclock_epoch = $(cat /sys/class/rtc/rtc0/since_epoch)
    echo $((swclock_epoch - hwclock_epoch)) > /var/cache/swclock-offset/offset-storage
    sync
```

服务的位置（systemd 版）：

```
swclock-offset-boot.service：DefaultDependencies=no
                             Before=systemd-fsck-root.service systemd-fsck@.service
swclock-offset-shutdown.service：Before=shutdown.target reboot.target halt.target
```

即 **fsck 之前 load、关机时 save**。

### 为什么存"偏差"而不是存"绝对时间"

因为 RTC 一直在走。存偏差，下次开机 `RTC(现在) + 偏差(上次)` 还原，
**关机期间流逝的时间由 RTC 那头补上**，不会丢。
代价：RTC 若被外部改动、或掉电后归零，偏差就失效。

### 它的两个短板（我们没有照搬的原因之一）

1. boot 脚本发现 `/sys/class/rtc/rtc0/since_epoch` 不存在就**静默跳过**。
   而 `CONFIG_RTC_DRV_PM8XXX=m` 是模块，sysinit 早期多半还没装载 ——
   等于白装一次。
2. **只在关机时保存一次**：手机很少干净关机，一掉电或长按电源硬复位就全丢了。

### 流程串起来

```
上电 → lk2nd → 内核（不读 RTC，时钟从 1970 起步，systemd 顶到自己的 epoch）
     → sysinit 早期：swclock-offset-boot 设「时间 = RTC + 偏差」（fsck 之前）
     → fsck / 挂载 / 起服务
     → 联网：NTP 校到真实时间
     → 关机：swclock-offset-shutdown 把新的偏差写回文件
```

---

## 二、本机实测：RTC 只能读，不能写

| 尝试 | 结果 |
|---|---|
| 不加 `allow-set-time` 写 RTC | `rtc-pm8xxx` 的 `set_time` 走 `pm8xxx_rtc_update_offset()`，它要设备树里名为 `offset` 的 nvmem cell，本机没有 ⇒ 函数开头 `return -ENODEV` ⇒ `hwclock --systohc` 报 `ioctl(RTC_SET_TIME) ... No such device` |
| 加 `allow-set-time` 让它真写寄存器（`bd39907`，已撤） | `hwclock --systohc` 把整机**挂死** —— 进程卡在不可中断状态，连设备端的 `timeout` 都杀不掉 |
| 开 `CONFIG_RTC_HCTOSYS/SYSTOHC=y` 让内核读写（`335d1e0`，已撤） | 走的是同一条 `set_time` 路径，同样失败；且真机出现 **5–12 分钟一次的周期性硬复位**，撤销后待复验 |

⇒ 与 pmOS 官方对 msm8953 的定位完全一致：这颗 RTC **能读、不能写**。

---

## 三、我们的改造：照 pmOS 的流程，用 Debian 的包

既然两边都是"写文件、读文件"，就用 Debian 自带的 `fake-hwclock`
（bookworm `0.12+nmu1`，已解包逐字核对）：

| 项 | pmOS swclock-offset | 我们（Debian fake-hwclock） |
|---|---|---|
| 文件里存什么 | 「系统时间 − RTC」的偏差 | 绝对时间（UTC） |
| 文件位置 | `/var/cache/swclock-offset/offset-storage` | `/etc/fake-hwclock.data`（**不是** /var/lib，`/sbin/fake-hwclock` 里 `FILE=` 写死） |
| 开机 | `swclock-offset-boot` | `fake-hwclock.service` 的 `ExecStart=load` |
| 关机 | `swclock-offset-shutdown` | 同一服务的 `ExecStop=save` |
| 时序 | `Before=systemd-fsck-root.service` | `Before=sysinit.target shutdown.target`（同为 fsck 之前 / 关机时） |
| 运行中定期存 | **无** | 包自带 `/etc/cron.hourly/fake-hwclock`（要 cron 才跑，故一并装 cron） |
| 防止时间倒退 | 无（直接 `date -s`） | `load` 仅当 `NOW <= SAVED` 才设；`save` 拒绝退到 2016-04-15（包发布日）之前，报 "Time travel detected!" |

**装上 cron 这一条正是补 pmOS 参考实现的短板**：手机很少干净关机，
swclock-offset 只在关机存一次，一硬复位就全丢；fake-hwclock 有每小时存一次
的机制（要 cron 才跑），最坏误差压到 1 小时。

### 改动清单

1. `dist/build/setup-rootfs.sh`：装 `fake-hwclock` 与 `cron`；
   启用 `fake-hwclock.service`、`cron.service`。
2. 撤掉自制的 `odin-swclock-offset.{sh,三个 unit}` 的安装与启用
   （文件保留在 `dist/build/rootfs/` 下，按"只增不删"待确认后再清）。
3. 撤掉 `systemctl mask hwclock-save.service` —— 解包核对过，
   bookworm 的 `util-linux-extra` **根本没有**这个 unit，它只带
   `/etc/init.d/hwclock.sh` 与 udev 的 `hwclock-set`，两者开头都是
   `[ -e /run/systemd/system ] && exit 0`，systemd 下压根不会去写 RTC。
   那句 mask 是照 pmOS 的思路想当然加的。
4. 内核配置与设备树**保持 pmOS 原样**（HCTOSYS/SYSTOHC 关、不加
   allow-set-time），这两处此前加过又已撤销。

---

## 四、这个方案的局限（必须知道）

1. **只在正常关机 / 每小时整点落盘**：硬复位、掉电、panic 之后开机，
   时间停在最近一次存盘点。
2. **不能自校正**：断网期间时间只会一路落后，必须靠 NTP 拉回来
   （`systemd-timesyncd`，已配国内可达的 NTP 候选）。
3. **首次开机没有数据文件** ⇒ `load` 直接跳过，只能靠 systemd 的 epoch + NTP。
4. 存的是**绝对时间**而不是偏差，所以**关机期间时间是"停走"的** ——
   这一点不如 pmOS 的偏差方案（RTC 一直在走，偏差方案能补上关机时长）。
   权衡：本机 RTC 里是 1970 年的废值，且已不参与报时，
   绝对时间方案反而更可预期（不依赖 RTC 是否可信）。
5. 与 `systemd-timesyncd` 自带的 `/var/lib/systemd/timesync/clock`
   （同步成功后每 60s 存一次）叠加，两者都只往前设，不会互相打架。

---

## 五、待验证

刷入后真机复验：

1. 联网后 `timedatectl` 应显示 `System clock synchronized: yes`，时间正确；
2. 正常 reboot 后，时间应停在上次存盘点附近（误差 ≤ 1 小时），
   **不再退回 systemd 的打包日期 2026-04-27**；
3. `cat /etc/fake-hwclock.data` 有内容，且随关机 / 每小时在更新；
4. 连续静置观察 ≥ 15 分钟，确认没有周期性重启（这是撤销
   `CONFIG_RTC_HCTOSYS/SYSTOHC` 之后最需要确认的一条）。
