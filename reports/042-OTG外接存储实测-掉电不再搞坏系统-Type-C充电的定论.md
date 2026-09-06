# 042 — OTG 外接存储：从"掉电就搞坏系统"到"18 分钟零掉电"，以及 Type-C 充电的定论

日期：2026-09-06　状态：**专题核心目标已达成**；Type-C 同时 OTG+充电：**硬件/协议层面无解**

测试机型：Smartisan U2 Pro（ODIN），内核 `7.1.3-postmarketos-qcom-msm8953`
外接设备：KIOXIA EXCERIA SATA SSD 894G（Ugreen 硬盘盒，ASMedia 174c:55aa）
集线器：Xiaomi Type-C 5-in-1 Hub（VID 5059，Hub PID 5058，内置 Realtek 设备 PID 5059）

---

## 一、一句话结论

| 问题 | 结论 |
|---|---|
| OTG 掉电会把系统搞坏 | **已解决**。升级 7.1.3 后，掉电不再引发 Oops、不再损坏文件系统 |
| OTG 自己掉电 | **不是软件问题**（电池内阻 0.54Ω，见 040）。带电源 Hub 可完全绕开 |
| UAS 硬盘盒不自动挂载 | **已修并真机验证**（`ID_BUS=ata` 的坑） |
| NTFS 盘挂不上 | **已修**（归一到内核 ntfs3） |
| FAT32 中文乱码 | **已修**，用 `utf8=1`，不重编内核、不需 `nls_utf8` |
| 边 OTG 边充电 | **做不到**。本机无 PD PHY，Type-C 无 PD 时数据角色与电源角色绑定 |

---

## 二、两轮 20 分钟持续读取测试（对照）

方法：`dd if=/dev/sda1 of=/dev/null bs=1M iflag=direct`（raw 直读，绕开页缓存，真实打 USB 总线），
每轮 200 MB，同时记录电压/电流/电量/dmesg 报错。全程只读挂载，未对外接盘做任何写入。

### 第一轮：硬盘直接接手机（电池供电）

| | 值 |
|---|---|
| 起始 | 08:45:04 |
| 掉电 | 08:48:21，第 20 轮（**撑了 197 秒 / 3 分 17 秒**） |
| 速度 | 30.3 ~ 30.4 MB/s（全程稳定） |
| 电压 | 3.862 V → 3.410 V（n=19），**跌 0.45 V** |
| 电流 | −390 ~ −450 mA，**且持续爬升** |
| 电量 | 87% → 82% |

掉电瞬间三条（顺序很清楚）：
```
[816.528404] qcom-smbchg ...: OTG regulator failure
[816.530235] sd 0:0:0:0: [sda] tag#12 data cmplt err -71 uas-tag 1 inflight: CMD
[816.554203] usb 1-1: USB disconnect, device number 2
```

### 第二轮：经带电源 USB Hub（Hub 外接电源供硬盘）

| | 值 |
|---|---|
| 起始 | 08:58:09 |
| 结果 | 跑到 106 轮（18 分钟）时仍 `dev=yes`，**0 次掉电** |
| 速度 | 30.2 ~ 30.3 MB/s（同样稳定） |
| 电压 | 4.050 V → 3.875 V（n=106），**跌 0.175 V** |
| 电流 | **−195 ~ −235 mA，全程平稳不爬升** |
| 电量 | 83% → 75% |

### 对比

| | 直连（电池） | 经带电源 Hub |
|---|---|---|
| 电流 | −390 ~ −450 mA，持续爬升 | **−200 mA，平稳** |
| 电压跌落速率 | ~2.3 mV/s | **~0.2 mV/s（慢 11 倍）** |
| 撑住时间 | 197 秒 | **18 分钟+（≥5.5 倍，且无停止迹象）** |
| 按此推算续航 | 撑不住 | **9 小时以上** |

**物理解释**：电流减半 ⇒ 在 0.54Ω 内阻上的 IR 压降减半 ⇒ 离 UVLO 阈值远得很。
这也反过来再次印证 040 号报告的内阻测量：ΔV/ΔI 的量级完全对得上。

**结论**：外接供电能把这个"电池老化"的问题彻底绕过去，不需要换电池。

---

## 三、最重要的成果：掉电不再拖垮系统

第一轮掉电后立刻体检：

| 检查项 | 结果 |
|---|---|
| Oops / BUG / panic / Call trace | **0 条**（grep 到的 4 条全是 ramoops 初始化日志，属误报） |
| pstore 转储 | 空 |
| 根文件系统 `/` | 仍是 `rw,errors=remount-ro`，**没有** remount 成只读 |
| EXT4 错误计数 | **0** |
| ssh / sshd | 均 active |
| 负载 / 内存 | 0.67 / 正常 |

上一版（6.19.5 + 我们手写的 `patches/0011`）掉电是会把系统搞坏的 —— 需要重刷。
换成上游 `ec35c1969650` 的正统修法（`device_move` 管 netdev 生命周期）后，
**掉电退化成"这块盘用不了"，系统照常跑**。这正是本专题要守住的健壮性底线。

---

## 四、真机实测撞出并已修的四个用户态缺陷

### 4.1 UAS 硬盘盒从来不会被自动挂载（最严重）

udev 报的是 **`ID_BUS=ata`**（SCSI 层按 ATA 报），USB 属性全在 `ID_USB_*` 上：
```
ID_BUS=ata   ID_USB_DRIVER=uas   ID_USB_VENDOR_ID=174c   ID_USB_MODEL=XCERIA_SATA_SSD
```
于是 `ID_BUS=="usb"` 的 udev 规则与脚本里的二次判断**双双跳过**，日志只有：
```
/dev/sda1 ID_BUS='ata' != usb, skip
```
插上去毫无反应。而现在 USB 硬盘盒基本都走 UAS —— **核心场景一直是坏的**。

修法：判定改成 `ID_BUS=usb` **或** `ID_USB_DRIVER` 非空。udev 规则补第二条，脚本同步放宽。
内部 eMMC 实测仍正确跳过：`ID_BUS='' ID_USB_DRIVER='' —— 不是 USB 设备，skip`。

真机验证（修复后）：
```
08:57:26 mount /dev/sda1 (vfat → -t vfat) -> /run/media/sda1 [...,utf8=1]
/dev/sda1 on /run/media/sda1 type vfat (rw,...,utf8,errors=remount-ro)
```

### 4.2 NTFS 盘会挂不上

`blkid` / udev 对 NTFS 报的类型是 **`ntfs`**，不是 `ntfs3`。虚拟盘 + loop 设备实测：

| 场景 | 结果 |
|---|---|
| `-t ntfs3` | `type ntfs3 (rw,...)`，中文名写入/读回字节全对，重挂仍在 ✅ |
| 不指定类型（装了 ntfs-3g） | `type fuseblk` —— 走 FUSE |
| 不指定类型（无 ntfs-3g，= 我们镜像） | **`unknown filesystem type 'ntfs'`** ❌ |
| 无 ntfs-3g + 显式 `-t ntfs3` | 仍可用 ✅ |

内核 NTFS3 是**内建**的（`CONFIG_NTFS3_FS=y`，`modinfo` 显示 `(builtin)`）。
修法：`odin-automount.sh` 把 `ntfs` 归一成 `ntfs3`，用 `systemd-mount --type=` 显式传。

端到端实测：
```
mount /dev/loop0 (ntfs → -t ntfs3) -> /run/media/uasntfs
/dev/loop0 on /run/media/uasntfs type ntfs3 (rw,noatime,uid=1000,gid=1000,...)
```

### 4.3 FAT32 中文文件名（撤销"此路不通"的旧结论）

README 第八节原写"放弃 FAT32 中文、不做 `nls_utf8`"，**这条撤销**。
卡住的根本不是缺内核模块，是**挂载选项写错了**。只读挂载设备上现成的 vfat 分区
（`/dev/mmcblk0p52`，modem 分区，不写盘）对拍：

```
A) iocharset=utf8 —— 挂载失败，dmesg：
     FAT-fs: utf8 is not a recommended IO charset for FAT filesystems...
     FAT-fs: IO charset utf8 not found          ← 卡在这
B) utf8=1        —— 挂载成功
     (ro,...,codepage=437,iocharset=iso8859-1,...,utf8,errors=remount-ro)
                                                      ^^^^ utf8 已生效
C) modprobe nls_utf8 → FATAL: Module nls_utf8 not found
   /lib/modules/.../kernel/fs/nls/ 下只有 nls_ucs2_utils.ko
```

原理：`utf8=1` 让名字转换改走 `utf16s_to_utf8s()` / `utf8s_to_utf16s()`，
这两个在 `fs/nls/nls_base.c`，`obj-$(CONFIG_NLS)` 就编进去，**与 `CONFIG_NLS_UTF8` 无关**。
本镜像 `CONFIG_NLS=y` + `CONFIG_NLS_ISO8859_1=y` + `CONFIG_NLS_CODEPAGE_437=y` 全齐 ⇒ 零改动可用。

唯一副作用：大小写比较仍走 iso8859-1 的 `nls_strnicmp` —— ASCII 仍不区分大小写、
非 ASCII 不折叠，对中文名无影响。

### 4.4 镜像缺 fsck 工具

`debootstrap --include` 原本只有 `e2fsprogs`（ext 系）。而 OTG 盘在本机会因电池欠压
突然掉电，掉完很可能要 fsck —— vfat / exFAT 的一个都没有。已补 `dosfstools,exfatprogs`。

**刻意不装 ntfs-3g**：装了会让自动探测优先走 `fuseblk`（实测），而内核 ntfs3 更好；
且 4.2 已把类型显式归一到 ntfs3。

---

## 五、Type-C：为什么做不到"边 OTG 边充电"

### 5.1 现象

Hub 通着电、硬盘被 Hub 供电（电流从 −400 降到 −200 mA 可证），但手机始终：
```
qcom-battery:   status = Discharging, current_now = -257 mA
qcom-smbchg-usb: present = 0, online = 0, usb_type = [Unknown]
extcon:          USB=0  USB-HOST=1  SDP=0  DCP=0  CDP=0
```

### 5.2 证据链

**① 这台机器没有 PD**（原厂源码坐实）
- `drivers/misc/fusb301.c`：一条 PD 报文处理都没有（无 PDO / RDO / VDM / SOP / BIST）
- 原厂 `drivers/` 下没有 `tcpc` / `typec` 子系统
- FUSB301 只是 **CC/DRP 控制器**，不是 PD PHY

**② 原厂 ROM 根本没启用 Type-C 控制器**
- `u3-p1-msm8953-odin.dts` 引的是 `msm8953-mtp.dtsi`
- 其中 `&pm8953_typec {...}` 和 `qcom,external-typec;` **整段被注释掉**
- `u3-p1-msm8953-special-odin.dtsi` 里一条 typec/fusb/otg 都没有
- ⇒ 原厂走的是 PMI8950 自己的 BC1.2（SDP/DCP/CDP）

**③ 原厂驱动里 OTG 与充电是两条独立的线，没有任何"同时"逻辑**
```c
static irqreturn_t usbid_change_handler(int irq, void *_chip) {
        otg_present = is_otg_present(chip);
        power_supply_set_usb_otg(chip->usb_psy, otg_present ? 1 : 0);
        ...
}
```
只按 ID 脚单向设置 OTG 标志，不碰充电通路。

**④ 主线驱动其实已经内置了"host + 充电"路径**（我们不需要改驱动）
```c
if (otg_present) {
        usb_role = USB_ROLE_HOST;               /* 数据角色：仍是主机 */
        smbchg_otg_switch(chip, !usb_present);  /* usb_present=1 → 关升压 */
} else if (usb_present) {
        usb_role = USB_ROLE_DEVICE;
}
```
`otg_present && usb_present` 同时成立 = **数据当主机 + 关掉自己的升压 + 打开充电通路**。
这条路是设计好的，只差 `usb_present` 能变成 1。

**⑤ 但 `usb_present` 永远变不成 1**
实验：`echo none > .../usb_role/.../role`（实际落到 device）
```
写入后: role=device  otg_regulator_state=enabled   ← 升压没关掉
        smbchg-usb present=0                        ← 仍检测不到输入
        battery status=Discharging
```
升压是 `smbchg_detect_work()` 内部控制的（`regulator.33 users=0` 的悬空 enabled 状态），
sysfs 改 role 不会关它。于是形成死锁：
```
升压开 → 检测不到外部电源 → usb_present=0 → 升压继续开
```

**但这个死锁不是主因** —— 主因是 **PD 协商失败**。这个 Hub 是 PD 直通型（能给 Mac
边充电边传数据），它只在对端回应 PD 握手后才供电；本机不回应 ⇒ 它不供。
就算我们关掉升压，它也不会给 5V。

### 5.3 定论

**USB Type-C 在没有 PD 时，数据角色与电源角色是绑定的：**

| 要什么 | 必须的角色 | 结果 |
|---|---|---|
| 用 OTG（读硬盘） | DFP（主机）= 源 | 手机**供** 5V，不能充 |
| 要充电 | UFP（从设备）= 汇 | 不能当主机，硬盘不可用 |
| 两者都要 | 需要**功率角色交换** | **只有 PD 能做，本机没有** |

**软件补不了** —— 没有 PD PHY 就是没有。

### 5.4 选项

- **接受**：带电源 Hub 下 18 分钟零掉电、−200 mA、续航 9 小时以上，够用
- **要同时**：只能用非标的「OTG + 充电」二合一头（十几元），它把外部 5V 直接灌进 VBUS、
  同时把 ID/CC 拉成 host —— **不需要 PD**，正好命中 ④ 那条已存在的代码路径

---

## 六、基线的时效（2026-09-06 查）

| | 版本 | 日期 | 距今 |
|---|---|---|---|
| **我们** | 7.1.3 | 2026-07-19 | **48 天** |
| 最新 stable | 7.2.3 | 2026-09-02 | 4 天 |
| mainline | 7.3-rc1 | 2026-08-30 | — |
| 7.1 系列最后一版 | 7.1.13 **[EOL]** | 2026-09-02 | — |

升级前是 6.19.5（2026-03-01，距今 189 天），这轮**追回 141 天**。
但 **7.1 系列已被 kernel.org 标记 EOL** ⇒ 钉在它上面只会越来越旧，不会再有更新进来。
是否再升到 7.2，取决于上游 pmOS 有没有开 `7.2.x/main` 分支（远端分支列表查询超时，待补）。

---

## 七、遗留

1. **FAT32 中文缺端到端闭环**：core 镜像已补 `dosfstools`，但还没在真机上造一个
   带中文名的盘做"写入→读回"。现有的只读对拍（4.3）足以证明挂载与名字转换路径正确。
2. **外接盘 dirty bit**：自动挂载默认 rw，遇上 OTG 掉电会给外接盘留 dirty 标记。
   用户明确表示**自动挂载就该是 rw**，故不改；仅在文档里提示掉电后到原系统修复。
3. **是否升到 7.2**：待查上游分支。
4. **远端 `git ls-remote` 超时**：本地分支列表可能不是最新的，下次联网再确认一次。
