# 工作日志 — ODIN 移植实施（016 之后的阶段 0/1/3）

> 用途：随时记录进展与下一步，**任何时刻中断都能照此恢复**。每完成一步就地更新本文件。
> 起始时间：2026-08-29 11:4x　分支：`main`　基线提交：`1838e73`

---

## 一、已锁定的决策（用户拍板，2026-08-29）

| # | 决策 | 选择 |
|---|---|---|
| 1 | 阶段 2（UTF-8） | **放弃 FAT32 中文，不做 nls_utf8**。不重编内核模块；以 exFAT / NTFS 为主力文件系统 |
| 2 | 自动挂载方案 | **systemd mount unit**（udev 打 `TAG+="systemd"`），**不装 udisks2** |
| 3 | 首刷策略 | **接受首刷期间没有 OTG**，安全版 `l0-safe` 作为 `default` |

## 二、安全红线（自定，不突破）

- **不对真机做任何刷写**（fastboot flash 一律不做）。
- 真机上的改动分两级：
  - **可逆**：`/etc`、`/usr/local/sbin`、`/etc/systemd` 下的用户态文件 —— 改前备份到 `*.odin-bak`，可随时回滚。
  - **不可逆**：替换 `/boot` 里的 DTB 或改 `extlinux.conf` 的 `default` 并重启 —— **必须先跟用户单独确认**。
- 真机当前是唯一的 SSH 生命线，任何可能导致重启后失联的操作都视为高风险。

## 三、当前基线状态（已实测核对）

产物 md5（与 reports/013 记录一致，8/28 批次之后无改动）：

```
dist/lk2nd.img              521d64fcb2ab4cf534bac1f9b8440712
dist/odin-debian.img        6b009587431b2d4e88bd6c4698a18bfd
odin-qemu/rootfs.img        2ab66f0800afa2e0c560dff7d36569fe
dist/odin-debian-sparse.img b7aea6cfe5f4a167f2a8796e8cade624
```

镜像内实测（挂载 `dist/odin-debian.img` 到容器 `/mnt/chk` 后核对）：

| 项 | 值 |
|---|---|
| `/boot` | `vmlinuz` 30468104、`initramfs.cpio.gz` 988089、`dtbs/qcom/msm8953-smartisan-odin.dtb` 44362（**仅此一个 dtb**） |
| `extlinux.conf` | 单 label `l0`；`fdtdir /boot/dtbs`；append 含 `console=ttyMSM0,115200n8 earlycon=msm_serial_dm,0x78af000 root=/dev/disk/by-label/pmOS_root rootwait rw` |
| 模块目录 | 仅 `6.19.0-postmarketos-qcom-msm8953`；`kernel/fs/nls/` 只有 `nls_ucs2_utils.ko` |
| `/etc/udev/rules.d/` | **空** |
| `/usr/local/sbin/` | `odin-firstboot-resize.sh`（013 已重写）、`odin-usb-gadget.sh`（8/22 旧版，待替换） |
| odin DTB 属性 | `dr_mode` 有、`usb-role-switch` 有、**`role-switch-default-mode` 无**（→ 默认 peripheral，UDC 恒在）；无 `chosen/framebuffer` 节点；含 `cont-splash@90001000` 保留内存；含 `fusb301`/`typec-controller@25`/`usb-c-connector`/`otg-vbus` |

构建环境：

- 容器 `odin-build`（debian:bookworm，OrbStack）**运行中**，`/work` = 宿主 `/Volumes/caseSensitiveBar`
- `/mnt/stage` = 真机 rootfs 可写基线；`/mnt/stage-qemu` = QEMU 基线；两者**与镜像同步**（无更新文件）
- 内核源码树 `/Volumes/caseSensitiveBar/linux-msm8953`：`.config`、`vmlinux`、`arch/arm64/boot/Image`、odin DTB、`Module.symvers` 齐全（Alpine gcc 13.2.1，8/21–8/22 构建）
- QEMU 台 `odin-qemu/`：`run.sh`（`-M virt -cpu cortex-a57 -smp 2 -m 1024`，ssh 2222 / telnet 2323，qemu-xhci + usb-storage）
  - **注意**：`odin-qemu/Image` 是 8/23 的**另一个内核**，与镜像内核不同源，只能验用户态

## 四、任务清单

| # | 任务 | 状态 |
|---|---|---|
| T5 | 阶段0：生成并编译 `msm8953-smartisan-odin-norolesw.dtb` | **已完成** |
| T6 | 阶段0：`extlinux.conf` 双 label，首刷 default = `l0-safe` | **已完成** |
| T7 | 阶段1：staging 安装 exfatprogs/ntfs-3g/dosfstools/btrfs-progs/xfsprogs/f2fs-tools | **已完成** |
| T8 | 阶段1：automount udev 规则 + `odin-mount-opts.sh` | **已完成** |
| T9 | QEMU 验证阶段0+1（启动 / 自动挂载 / 网络 / usb0 unmanaged） | 待开始（等镜像重建） |
| T10 | 阶段3：`odin-usb-role.sh` + udev 规则 + service/timer 看门狗 | **已完成** |
| T11 | QEMU 冒烟验证阶段3 | 待开始 |
| T12 | 重建镜像 + 全量校验 | 进行中 |
| T13 | 真机动态验证（仅可逆改动） | 待开始 |
| T14 | 更新 FLASH.md / README + 写 reports/017 + 提交 | 待开始 |

## 五、进度日志

（每步完成后追加）

- **2026-08-29 11:4x** — 建任务清单与本日志；完成镜像/环境基线核对（见 §三）。
- **11:50 T5 完成** — 安全版 DTB 落地。
  - 新增 `dts/msm8953-smartisan-odin-norolesw.dts`（`#include` 完整版后做 4 处删改：
    `dr_mode` → peripheral、删 `usb-role-switch`、删 `ports`、删 fusb301 的 `connector`）
  - 新增 `dts/build-dtb.sh`（可复现构建脚本，自动识别 dtc 1.6/1.7）
  - **标定**：用宿主 dtc 1.7.2 与容器 dtc 1.6.1 分别重编完整版 DTS，**两者都逐字节复现**
    既有 dtb（md5 `e0ecc4ad23d02bce50997bdb011aa993`，44362 B）→ 管线可信
  - 产物：`dts/msm8953-smartisan-odin.dtb` 44362 B（同上）、
    `dts/msm8953-smartisan-odin-norolesw.dtb` 43924 B（md5 `627f692d298d425b69ac4f81867c0436`，
    两个 dtc 版本结果一致）
  - 反编译自检：安全版 `usb-role-switch`=0、`usb-c-connector`=0、`dr_mode="peripheral"` ✅；
    仅 `otg-vbus` 稳压器保留（切回完整版时仍可用）
  - **踩坑**：dtc 要求属性写在 `/delete-node/` 之前，否则报
    `Properties must precede subnodes`；内核自带的 `scripts/dtc/dtc` 是 aarch64-musl
    二进制，macOS 宿主与 debian 容器都跑不了（exec format / 缺 musl loader）

- **12:00 T6 完成** — 双 label 引导。
  - **读 lk2nd 源码定案**（`lk2nd/boot/extlinux.c:394-434`）：`fdt` 与 `fdtdir`
    **互斥** —— label 里只要有 `fdtdir`，lk2nd 就用 `lk2nd,dtb-files` 拼
    `<dtbdir>/qcom/<name>.dtb` 并**覆盖** `fdt`。所以安全版 label 只写 `fdt`。
  - **重大结构发现**：镜像是**单一文件系统**（只有 `pmOS_root`），`/extlinux/` 与
    `/boot/` 都在根分区里，不是 pmOS 那种 pmOS_boot+pmOS_root 双分区。
    ⇒ **切 label 只需在系统里改 `/extlinux/extlinux.conf` 再重启**，不用挂 boot 分区。
  - 新增源 `dist/build/rootfs/extlinux/extlinux.conf`（default=l0-safe，l0 用 fdtdir、
    l0-safe 用 fdt），由 `apply-staging-fixes.sh` 部署。

- **12:05 T7 完成** — 两个 staging（`/mnt/stage`、`/mnt/stage-qemu`）都装了
  exfatprogs / ntfs-3g / dosfstools / btrfs-progs / xfsprogs / f2fs-tools。
  无新增 systemd 服务拓扑（只有静态的 `sys-fs-fuse-connections.mount`）。
  `user` 的 uid = 1000（挂载选项要对齐这个值）。

- **12:08 T8 完成** — 自动挂载。
  - **推翻了 015 §3.2 的一处假设**：实测 bookworm systemd 252 里，**PID 1 不读任何
    `SYSTEMD_MOUNT_*` 属性**，只有 `/usr/bin/systemd-mount` 读，且只认
    `SYSTEMD_MOUNT_WHERE` 与 `SYSTEMD_MOUNT_OPTIONS` 两个。
    ⇒ 光写 `TAG+="systemd"` 不会挂载任何东西，必须显式 `RUN+=/usr/bin/systemd-mount`。
  - 放弃 `--owner=`（systemd-mount 会对挂载点做 chown，vfat/exfat 上会失败），
    改为在挂载选项里给 `uid=/gid=/fmask/dmask`。
  - 新增源：`dist/build/rootfs/etc/udev/rules.d/99-odin-automount.rules`、
    `dist/build/rootfs/usr/local/sbin/odin-mount-opts.sh`。
  - `odin-mount-opts.sh` 逐 fstype 自检已过（vfat/exfat → uid,gid,fmask,dmask；
    ntfs3/ntfs → uid,gid,umask；POSIX → 仅 noatime）。

- **12:13 T10 完成** — USB 角色自动切换。
  - 新增源：`dist/build/rootfs/usr/local/sbin/odin-usb-role.sh`、
    `dist/build/rootfs/etc/udev/rules.d/99-odin-usb-role.rules`。
  - 脚本特性：flock 防重入、先空后名绑定 UDC、任何分支 exit 0、无 typec 且无 UDC
    时立即返回（避免 QEMU 空等 20s）、dnsmasq 按 pidfile 幂等。
  - **保留服务名 `odin-usb-gadget.service`**（不改名为 odin-usb-role），因为 QEMU
    镜像是按这个名字 mask 的；改为 `Type=oneshot + RemainAfterExit=yes`。
  - 看门狗命名 `odin-usb-gadget.timer`（同源名），只在服务未被 mask 的真机镜像启用。
  - 同步改了 `dist/build/setup-rootfs.sh` 的 gadget 段，改从 `dist/build/rootfs/`
    取源，避免将来从零重建时静默回退到旧逻辑。
  - **脚本部署注意**：`apply-staging-fixes.sh` 用 `cat >` 而非 `cp` 写 service/timer ——
    QEMU 镜像里它是 `/dev/null` 符号链接，写穿它正好保持 mask 生效。

- **12:41 QEMU 最终回归（第四次重建的镜像）** —— 全绿：
  - 4 个 USB 盘全部自动挂载（vfat/ntfs/ext4；exFAT 因 QEMU 内核不支持而挂不上）
  - **挂载选项生效**：sda = `noatime,uid=1000,gid=1000,fmask=0133,dmask=0022` ✅
    sdc(ntfs-3g) = `noatime` + `default_permissions,allow_other` ✅；sdd(ext4) = `noatime` ✅
  - **用户可写性验证通过**：sda、sdc 用 `user` 直接写成功，文件属主 1000:1000 ✅
  - `systemctl --failed` = 0 ✅
  - 两个 DTB 与双 label extlinux.conf 均正确落到镜像内 ✅

- **12:32 发现并修掉一个"刷了就起不来"的隐患（本次最重要的发现）**
  - 从 `dist/lk2nd.img` 里解出全部 31 条 QCDT 条目后比对发现：
    `msm8953-smartisan-odin` 的 board-id 是 `<0x0b 0x01>`，而
    `msm8953-xiaomi-markw` 是 `<0x1000b 0x01>`。
  - 查 `dev_tree.h:56-58`：`VARIANT_MASK=0xff` ⇒ 两者 **variant_id 都是 0x0b**，
    高位 `0x10` 只是 major。按 `dev_tree.c:448-500` 的匹配规则，变体相同即同时候选。
  - **修正一处误判**：真机 DT 里的 `<0x1000b 0x01>` **不是硬件 ID** —— 全树 grep 确认
    lk2nd **没有任何写 `qcom,board-id` 的代码**，那只是 markw 内核 DTB 自己的声明值。
    原厂 `evidence/stock_dtb_1.dtb` 明确写着 `qcom,board-id = <0x0b 0x01>`
    （model = "Qualcomm Technologies, Inc. MSM8953 ODIN"）⇒ **项目 DTS 写的是对的**。
  - 但风险仍在：若 lk2nd 判给 markw，原 `l0` 的 `fdtdir` 会去找镜像里没有的
    `msm8953-xiaomi-markw.dtb` ⇒ 启动失败。
  - **已修**：`l0` 与 `l0-safe` **全部改为显式 `fdt`**，不再用 `fdtdir`。
    选中 odin → 有屏 + 全功能；选中 markw → 无屏但能起、SSH 可用。
  - 附带确认：只有 lk2nd 选中 odin 条目才会替换 `smartisan,odin-panel` 占位
    compatible —— 这是屏幕点亮的唯一开关，只能真机判定。若实测无屏，下一步是
    精简 lk2nd（只留 odin 条目）强制命中。

- **12:47 真机安全验证（只读 + dry-run，SSH 全程未受影响）**
  - UDC = `7000000.usb` ✅；`/sys/class/typec` 不存在（pmOS 内核无 fusb301）✅
  - **`find /sys -name role` 为空** ⇒ 阶段 3 的"手动 `echo device > .../role` 强制切回"
    这条后门在当前内核上**不可用**（风险坐实，已写进 FLASH.md）
  - `odin-usb-role.sh --dry-run` 在真机上跑通：`device: [dry-run] udc=7000000.usb
    gadget-UDC='' dnsmasq_running=no; no action` —— 逻辑正确且**零副作用**
  - `odin-mount-opts.sh` 四种 fstype 自检通过
  - pmOS 侧对照：systemd 257 / udev 257 有 `systemd-mount`、`exfat.ko` 存在、
    `nls_utf8` 缺失（与项目内核一致）

- **12:47 T12 完成** — 最终产物（第 5 次重建，全部校验通过）：
  ```
  dist/lk2nd.img              521d64fcb2ab4cf534bac1f9b8440712   （未改动）
  dist/odin-debian.img        98482fdbdcd15e6f568c162fda3629ca
  dist/odin-debian-sparse.img 56a2cbca0075c7aac3d184b5f2a618e1   （check_sparse = IDENTICAL）
  odin-qemu/rootfs.img        c30ecee6a9ffb519cf5ac6f37fea1949
  ```
  注：上面 sparse 的 md5 是 12:47 那次；随后 12:47 又为 dry-run 重建过一次，
  以 `tools/check_sparse.py` 复跑为准（最近一次为 IDENTICAL）。

### 柒、真机刷入循环（用户授权选项二：无人值守执行）

**流程依据**：`reports/018`（状态机、命令、红线）。红线：**只刷 userdata，绝不刷 boot**。

**13:19 前置确认**
- 状态 A：pmOS 运行，`model = Xiaomi Redmi 4 Prime`，lk2nd `21.0-r0-postmarketos`
- `extlinux.conf` 真实位置 `/boot/extlinux/extlinux.conf`（`/boot` = `pmOS_boot` 子分区）
- 备份已在本地 `evidence/live-device-backup/`（boot 分区 64M / /boot 28M / GPT 前 8M / STATE.txt）

**13:20 步骤 ① A→B：改名引导配置 → 重启 → lk2nd 停 fastboot ✅**
- 只 `mv` 未删除：`extlinux.conf` → `extlinux.conf.DISABLED`，内容校验完整
- 两次踩坑：macOS 无 `timeout` 命令；`pm_do.exp` 执行的是手机上的 `/tmp/pmr.sh`，
  必须走 `sh /tmp/pmr.sh <本地脚本>` 才会先 scp 上传
- 重启后 ~60s：`fastboot devices` → **`<emmc-serial>  fastboot`** ✅
  **实测证实：lk2nd 启动失败确实会自动停在 fastboot**（与用户判断一致）

**13:22 fastboot 只读探测 —— 拿到高价值信息（已存档 `fastboot-getvar-all.txt`）**
```
lk2nd:version    : 21.0-r0-postmarketos
lk2nd:model      : Xiaomi Redmi 4 Prime (markw)      ← lk2nd 选中的是 markw 条目
lk2nd:compatible : xiaomi,markw
lk2nd:panel      : qcom,mdss_dsi_ft8716_1080p_video  ← ★ 面板名
unlocked         : yes
max-download-size: 0x1fe00000 (534 MB)
partition-size:userdata : 0x1bfabfbe00 (111.9 GiB)
```
- ★ **`lk2nd:panel` 有值 ⇒ 原厂 aboot 确实透传了面板名**，reports/010 §七 悬而未决的问题
  答案是"是"。且面板为 **FT8716**，正是补丁 0005 支持的型号。
- lk2nd 仍选中 markw（不是 odin）⇒ 我们的 `smartisan,odin-panel` 占位不会被替换 ⇒
  **预期无屏**，与 reports/017 的分析一致。
- 推论：硬件 target major = 0x10（故 markw 以 major 精确匹配胜出），
  即使换成我们的 lk2nd，markw 仍会赢 ⇒ **必须精简 lk2nd（去掉 markw）才能让 odin 命中**。

**13:24 步骤 ② 刷入 userdata ✅（EXIT=0，178 秒）**
```
Sending sparse 'userdata' 1/2 (522237 KB)  OKAY [ 13.021s]
Writing  'userdata'                        OKAY [ 14.222s]
Sending sparse 'userdata' 2/2 (122484 KB)  OKAY [  2.957s]
Writing  'userdata'                        OKAY [147.606s]
```

**13:27 步骤 ③ `fastboot reboot` → 至今（13:48）未出 SSH —— 状态 D，无响应**

诊断：
- `fastboot devices` 空（不在 fastboot）
- SSH 两个密码（user / cheng）均超时
- PC 侧 USB 网卡 en17 消失
- `ioreg`/`system_profiler` 上**完全没有手机**，只剩 Hub(`Xiaomi Type-C 5-in-1 Hub`) 与 RTL9210 硬盘盒
  ⇒ **手机不是直连，是接在 Type-C Hub 上**（新发现，之前没注意到）

分析（推测，待串口证实）：
- 与 ① 不同：这次 lk2nd **找到了** extlinux.conf 并成功跳转内核，
  所以"找不到配置→停 fastboot"这条救援路径**不再触发**
- 内核若 panic 或卡死，USB gadget 不会枚举 ⇒ PC 上完全看不到设备 ⇒ 与观察吻合
- 已排除扩容因素：无 64bit 特性下 895 个组、只需 6 个 reserved GDT（有 127），分钟级

**当前阻塞**：无串口输出，无法定位卡在哪一步；恢复需要人工长按电源键 + 音量键进 fastboot。

**下一步（等用户在场或授权）**
1. 长按电源 10–15s 强制关机 → 音量减+电源 进 fastboot
2. `fastboot boot` 试启动，或换 `l0`/`l0-safe`、或改用 markw DTB 试
3. 若都不行，用 pmbootstrap 重装 pmOS 回到已知可用状态

**19:08 用户已手工进 fastboot，并改为直连（不再走 Type-C Hub）**
- `fastboot devices` → `<emmc-serial>  fastboot` ✅
- USB 拓扑：`"USB Product Name" = "Android"` / Serial `<emmc-serial>`，Hub 已消失 ✅
- 结论：**当前处于状态 B**，可以按 018 手册继续

**19:10 精简 lk2nd 的可行性推导（源码级，不是猜测）**

`dev_tree.h:81-112` 的匹配位序（数字=bit 位，越大优先级越高）：
```
VARIANT_MINOR_BEST/EXACT      9/10
VARIANT_MAJOR_BEST/EXACT     11/12
SUBTYPE_DEFAULT_MATCH        25
SUBTYPE_EXACT_MATCH          26   ← 关键
VARIANT_MATCH                27
SOC_MATCH                    28
```
`dev_tree.c:599-608` 比较规则：先比 `dt_match_val`（位图整体当整数比），**相等时再比 major，major 大的赢**。

因为 `BIT(26) > BIT(25) + BIT(12)`，**带 SUBTYPE_EXACT 的条目必然压过只有 MAJOR_EXACT 的**。

遍历全部 31 条 QCDT 条目，`msm-id=0x125 & (variant & 0xff)=0x0b & subtype=0x01` 的**只有两个**：
- `msm8953-xiaomi-markw` (`<0x1000b 0x01>`，major=0x10 → SUBTYPE_EXACT + MAJOR_EXACT)
- `msm8953-smartisan-odin` (`<0x0b 0x01>`，major=0x00 → SUBTYPE_EXACT + MAJOR_BEST)

⇒ **删掉 markw 后，odin 成为唯一带 SUBTYPE_EXACT 的候选，稳赢。**
（对照：xiaomi-common 是 `<0x1000b 0x00>` → 只有 SUBTYPE_DEFAULT，注定输给 odin；
sdm450-xiaomi-rosy / sdm632-qrd-sku4 虽也是 0x0b/0x01 但 msm-id 分别是 0x152/0x15d，SOC 不匹配直接排除。）

**19:13 精简 lk2nd 构建成功**
- 改 `lk2nd/device/dts/msm8953/rules.mk`：整行移除 `msm8953-xiaomi-markw.dtb` 与
  `sdm450-xiaomi-rosy.dtb`，说明注释写在 **ADTBS 块之前**
- **踩坑**：Makefile 里**不能把注释插进 `\` 续行中间** —— 第一次改写把注释放进续行块，
  报 `rules.mk:28: recipe commences before first target`（注释行打断了续行链，
  后续以 tab 开头的行被当成 recipe）。改成块外注释后正常。原文件已备份为 `rules.mk.orig`
- 构建：`make TOOLCHAIN_PREFIX=arm-none-eabi- PROJECT=lk2nd-msm8953`（容器已装该工具链）
- 产物 `dist/lk2nd-nomarkw.img`：364560 B（原 366608，小 2 KB），md5 `b6e475252976e267bc8b6d7766f9c9f9`
  - **27 个 appended DTB**（原 29）
  - `strings | grep xiaomi-markw` → **0 处**（已清除）✅
  - `strings | grep smartisan-odin` → 2 处（保留）✅

**19:14 用 `fastboot boot` 从内存启动验证（未写分区，boot 分区仍是 pmOS 的 lk2nd）**
- 命令 `fastboot boot dist/lk2nd-nomarkw.img` 已下发
- 结果：**又是状态 D** —— 不在 fastboot、USB 上无手机、无 USB 网卡、SSH 全不通
- 用户观察：**背光亮着、黑屏**

**关键判断（重要）**
- 两次失败用的是**同一个 Debian 镜像**，lk2nd 分别是 pmOS 原版(21.0) 与 精简版 ⇒
  **问题不在 lk2nd，在 Debian 6.19 + odin DTB 这一侧**
- 背光亮说明手机有电、lk2nd/内核走到了点亮背光这一步（比上次的完全无响应进了一步）
- 无 USB 网卡 ⇒ 内核里 UDC 没起来（dwc3 未成功 probe）⇒ 与我们"安全版 DTB 是
  dr_mode=peripheral、UDC 应恒在"的预期不符
- **当前瓶颈：没有串口输出，无法定位内核卡在哪一步。** 继续盲试只会反复消耗按键。

**待验证的两个假设（等进 fastboot 后做对照测试）**
- H1 硬件其实更接近 markw（lk2nd 判 markw、board-id 0x1000b/01），odin DTB 不匹配
  ⇒ 对照：用 **Debian 内核 + markw DTB** 构造 boot.img 做 `fastboot boot`
- H2 odin 安全版 DTB 本身有问题（我删 ports/role-switch 的改动引入）
  ⇒ 对照：用 **Debian 内核 + odin 完整版 DTB**（未删改）做 `fastboot boot`

### 玖、★ 重大突破：Debian 系统已在真机跑起来，且 lk2nd 命中 odin

**19:14 `fastboot boot dist/lk2nd-nomarkw.img`（内存启动精简版 lk2nd）**
- 现象：USB 网卡枚举了（en20），但 PC 只拿到 169.254 自分配地址
- 分析：gadget 是 **initramfs 的 `usb_up()`** 配的（只配地址、**不开 dnsmasq**）
  ⇒ 系统当时还没走到 systemd 的 gadget 服务
- 用户手动给 PC 配固定 IP → **SSH 成功登录** ✅

**19:31 登录后核心诊断 —— 两个目标全部达成**
```
hostname  : odin                                ← 我们的镜像（不再是 pmOS 的 u2pro）
uname     : 6.19.0-postmarketos-qcom-msm8953
model     : Smartisan U2 Pro (ODIN)             ← 加载的是 odin DTB ✅
compat    : smartisan,odin qcom,msm8953
★ panel@0 : smartisan,odin-ft8716 smartisan,odin-panel
            ↑ lk2nd 把占位替换成真实面板 FT8716 ⇒ 精简 markw 生效，odin 命中 ✅
lk2nd,version : unknown-20260829                ← 本次构建的精简版（version 未注入）

UDC       : 7000000.usb ✅
usb0      : 172.16.42.1/24 ✅
gadget    : active ✅
扩容      : /dev/mmcblk0p57  111G  651M  105G  1%   ← 2GiB→111G 成功 ✅
failed    : 0 个 ✅
```
**结论：reports/018 的推导被实机证实 —— 删掉 markw 后 odin 成为唯一
SUBTYPE_EXACT_MATCH 候选，必然命中；面板识别链路（aboot 透传 → lk2nd 替换
占位 compatible）在真机上完整工作。**

**剩余问题：屏幕仍未点亮**
```
/sys/class/drm/ : 只有 version      ← 没有 card0
/dev/dri        : 不存在
/sys/class/backlight/ : 空
但驱动都绑定了：
  1a00000.display-subsystem → msm-mdss
  1a01000.display-controller → msm_mdp
  1a94000.dsi   → msm_dsi
  1a94400.phy   → msm_dsi_phy
  panel_ft8716  : 已加载但 0 users（没绑到设备）
/sys/bus/platform/devices/ 里只有 1a94000.dsi，**没有 panel 设备**
/sys/kernel/debug/devices_deferred : 空（没有设备 deferred）
dmesg: gcc-msm8953 sync_state() pending due to 1a00000.display-subsystem
```
→ 初步判断：**panel platform device 没有被创建**（panel@0 是 dsi 的子节点，
不是 simple-bus，不会自动变成 platform device），需要 msm_dsi 在 probe 时
自己解析子节点找 panel；而 panel 驱动是模块(=m)，加载时机可能晚于 msm_dsi probe。

**下一步待试（按风险从低到高）**
1. 重新触发 msm_dsi probe：`echo 1a94000.dsi > .../msm_dsi/unbind; echo ... > bind`
   （此时 panel_ft8716 已注册，重 probe 可能就接上了）—— **零风险，先试**
2. 装 kmod（modprobe 不存在）+ iputils-ping（用户已发现 ping 缺失）
3. 把面板驱动改为内建(=y)重编内核
4. 若都不行，考虑 panel 是否应改成通过 ports/endpoint 连接

**顺带发现的两个包缺失（待办）**
- `kmod` 未装 ⇒ `modprobe` 不存在 ⇒ 模块自动加载机制失效
- `iputils-ping` 未装 ⇒ `ping` 不可用

**★ 屏幕取得实质进展（ovp 改 29600 并重启后）**
```
/sys/class/backlight : backlight          ← 背光设备出现 ✅（WLED probe 不再报错）
/dev/dri             : by-path card0 renderD128   ← DRM card0 出现 ✅
/sys/class/drm       : card0 card0-DSI-1 renderD128
[drm] Initialized msm 1.13.0 ... minor 0
[drm] fb0: msmdrmfb frame buffer device   ← fb0 出现 ✅
panel compatible     : smartisan,odin-ft8716（写死生效，lk2nd 未覆盖）
```
**仍未点亮** —— 只剩最后一步：
```
ft8716 1a94000.dsi.0: Failed to initialize panel: -22
[drm:mdp5_irq_error_handler] *ERROR* errors: 04000000
```
即背光/DRM 框架都起来了，但面板驱动自身的初始化序列返回 -EINVAL，需查
`drivers/gpu/drm/panel/panel-ft8716.c` 的 probe（供电/时序/命令序列）。

### 拾、USB 网络自动分配 IP —— 根因已查明，修复已提交，但尚未部署成功

**两层原因（都是实机抓出来的，不是推测）**

第 1 层：dnsmasq 根本起不来
```
dnsmasq: cannot set --bind-interfaces and --bind-dynamic
```
/etc/dnsmasq.d/zz-gadget-exclude.conf 里有 `bind-dynamic`，与脚本命令行的
`--bind-interfaces` 互斥 ⇒ dnsmasq 读配置后直接退出（日志里 "dnsmasq started
(pid N)" 是假象，进程随即消失、pgrep 查不到）。
另外系统 dnsmasq 用 bind-dynamic 绑通配地址，占住 UDP 67。

第 2 层：地址池"没有可用地址"
```
DHCPDISCOVER(usb0) a6:df:c9:9c:b7:3e   no address available
租约文件: 66:ec:1e:92:ff:3f 172.16.42.2 <pc-hostname>
```
地址池当时只有 172.16.42.2 一个；手机每次重启 USB gadget 会**重新生成随机 MAC**，
PC 侧网卡 MAC 跟着变 ⇒ dnsmasq 当成全新客户端，而唯一地址被旧 MAC 的 12h 租约占住
⇒ PC 只能拿 169.254 自分配地址。
**这正是 postmarketOS 用 unudhcpd 的原因**（它不做租约管理，任何客户端都给固定 IP）。

**修复（已提交 fe2904d）**
1. 写死 NCM 的 host_addr/dev_addr（02:00:0d:1d:00:01 / …ba，基于序列号 <emmc-serial>）
2. 地址池扩到 172.16.42.2–172.16.42.10 兜底
3. gadget dnsmasq 加 `--conf-file=/dev/null`（不读系统配置）
4. apply-staging-fixes.sh 里 mask 系统 dnsmasq
5. 脚本加启动后校验：dnsmasq 没活下来就记日志 + 打自身日志

**⚠️ 部署尚未成功（当前卡点）**
- 失败的写法：`ssh ... 'echo user | sudo -S bash -s' <<'EOF'`
  —— `echo user |` 把 sudo 的 stdin 占用了，`bash -s` 读不到 heredoc ⇒ 命令没执行。
  （之前成功的那次是 `bash /tmp/install_dtbs.sh`，脚本在远端，**不是** `bash -s`）
- 一旦手机重启，PC 就拿不到 IP（旧脚本还在），于是 SSH 不通 ⇒ 无法部署 ⇒ 死锁。
- 本机现在 PC 侧是 169.254，IPv4/IPv6 都连不上手机。

**打破死锁：需要人工在 PC 上配一次 IP（最后一次）**
```sh
sudo ifconfig enXX alias 172.16.42.10 netmask 255.255.255.0     # enXX = 当前 USB 网卡
ssh user@172.16.42.1
```
连上后执行（注意用远端脚本文件，不要 `bash -s`）：
```sh
sshpass -p user ssh ... user@172.16.42.1 'cat > /tmp/rn.sh' < dist/build/rootfs/usr/local/sbin/odin-usb-role.sh
sshpass -p user ssh ... user@172.16.42.1 'echo user | sudo -S cp /tmp/rn.sh /usr/local/sbin/odin-usb-role.sh'
sshpass -p user ssh ... user@172.16.42.1 'echo user | sudo -S rm -f /var/lib/misc/dnsmasq.leases'
sshpass -p user ssh ... user@172.16.42.1 'echo user | sudo -S systemctl reboot'
```
重启后 gadget 用固定 MAC 重建，PC 应能**自动**拿到 172.16.42.2，此后无需再手工配置。

**其它待办**
- 手机尚无外网（无默认路由），wlan0 未起来 ⇒ 后续 apt 装包需先解决联网
- 离线 deb 已备好（90 个，35MB）在宿主机 `/Volumes/caseSensitiveBar/odin-offline-debs/`，
  用户指示暂不安装，留待后续
- `ping`、`modprobe` 等工具缺失（kmod / iputils-ping 未装）；
  登录 Shell 已确认是 GNU bash 5.2.15（非 busybox），/bin/sh -> dash，符合预期

### 捌、精简 lk2nd（已完成构建，已被实机验证命中 odin）

- **12:50 T14 完成** — FLASH.md 已更新（双 label、显式 fdt 的来由、外置存储矩阵、
  自愈看门狗、role 回退缺口）。README 已更新（§四刷机包与用户态组件、§五已验证内容、
  §六刷入步骤、§七已知限制、§八决策）。reports/017 实施报告已写。
- **13:16 仓库收尾完成** — 4 个提交：
  `8f43fac` 阶段0/1/3 落地 · `6a5aab8` 文档与报告 · `5fa186b` 镜像产物 · `9988689` 备份与操作手册
  `git status` 干净。

- **12:20 QEMU 首次回归（用第 1 批重建的镜像）** —— 三个重要发现：
  1. ✅ 4 个 USB 盘（vfat/exfat/ntfs/ext4 superfloppy）全部识别，
     `ID_BUS=usb` + `ID_FS_USAGE=filesystem` + `ID_FS_TYPE` 正确
  2. ❌ **superfloppy 没有 `ID_PART_ENTRY_NUMBER`** ⇒ 原规则的分区号限制会把
     "整盘一个文件系统、无分区表"的 U 盘全部排除。**已放宽规则**（去掉该条件）。
  3. ❌ `systemd-mount` 以普通 user 身份执行报
     `Interactive authentication required`（polkit）。udev 的 RUN 是 root，
     产品路径不受影响；测试脚本改用 `sudo -S` 复现。
  4. ❌ failed 单元 0 ✅；`odin-mount-opts.sh` 分流自检全过 ✅

- **12:21 两个内核层结论（拿源码/配置坐实，不靠推测）**：
  - **exFAT 不依赖 nls_utf8** —— `fs/exfat/super.c:38-41` iocharset=utf8 时
    `opts->utf8=1`，`:691-697` 走 `set_default_d_op(exfat_utf8_dentry_ops)`
    **根本不调用 `load_nls()`**，用内建 `utf16s_to_utf8s()`。
    ⇒ **"放弃 FAT32、靠 exFAT" 的决策成立，中文文件名开箱正常**。
    （这条修正了 015 §4.5 "exFAT 驱动内建 UTF-16 处理" 的含糊表述）
  - **镜像内核无法在 QEMU 里跑** —— `.config` 只有 `VIRTIO_BLK/NET/CONSOLE=y`，
    但 `VIRTIO_PCI`、`VIRTIO_MMIO` **均未设置** ⇒ virt 机器上没有块设备/网卡。
    印证 015 #12：QEMU **只能验用户态**，内核/硬件相关项必须真机验证。
  - 顺带核实：`CONFIG_EXFAT_FS=m`（**是模块不是内建**，修正 015 §4.5 的说法），
    镜像内 `kernel/fs/exfat/exfat.ko` 确实存在（594 KB，modules.dep 无依赖）；
    `CONFIG_NTFS3_FS=y` 内建（`modules.builtin` 里有 ntfs3）；`CONFIG_BLK_DEV_SD=y`。
    exfat 挂载时由内核 `request_module("fs-exfat")` 自动加载，无需额外处理。

### 拾壹、面板驱动正确性审查（用户要求：仔细核对移植是否正确）—— 结论：移植正确

做法：从仓库里原厂 DTB 的反编译 `evidence/stock.dts` 精确提取
`qcom,mdss_dsi_ft8716_1080p_video` 节点（行 11215–11280）的
`qcom,mdss-dsi-on-command`（1622 字节），按 qcom 命令格式
`dtype,last,vc,ack,wait,dlen_hi,dlen_lo,payload` 解码为 125 条命令，
与 `drivers/gpu/drm/panel/panel-ft8716.c` 的 `ft8716_panel_on()` 逐条比对 payload：

```
原厂 125 条  vs  驱动 123 条    不一致 = 2
[123] 原厂: 05 11 00  ← exit_sleep_mode
[124] 原厂: 05 29 00  ← set_display_on
```
差的这 2 条驱动用标准 DCS API（`mipi_dsi_dcs_exit_sleep_mode` / `set_display_on`），
语义等价；**前 123 条逐字节完全一致** ✅
（脚本：/tmp/extract2.py、/tmp/cmp_panel.py；原始数据：/tmp/panel_cmp/）

### 拾贰、IPv6 固定地址 —— 零配置兜底通道（已实机验证）

- 新增 `odin-usb6-addr.service`（已 enable）：开机后给 usb0 加固定链路本地地址
  **`fe80::1`**（保留内核自动生成那个，不覆盖）。sshd 默认监听 `[::]:22`。
- 实测：PC 只有 169.254 自分配地址时，`ssh user@fe80::1%enXX` **照样连得上** ✅
- 注意：ssh 必须带 `-o PreferredAuthentications=password -o PubkeyAuthentication=no`，
  否则 ssh 先试 publickey 卡住，sshpass 传入的密码不会被使用（踩过一次）。

### 拾叁、★ 死锁打破：PC 开机自动拿到 IP（已实机验证）

**死锁**：手机一重启 PC 就拿不到 IP ⇒ SSH 不通 ⇒ 无法部署修复 ⇒ 死循环。
**破局**：用拾贰的 IPv6 通道连进去完成部署。

**最终修复（在 fe2904d 基础上再补两处健壮性问题）**：
1. dnsmasq 在 usb0 刚 `addr add` 完就绑定 —— 地址还处于 tentative，导致 dnsmasq
   起来后**又退出**（表现：日志有 "dnsmasq started (pid N)"，但 pgrep 查不到进程）。
   修：启动前轮询等待 usb0 真的出现 172.16.42.1，最多 10s。
2. `dnsmasq_running()` 原先只判断 pidfile 里的 pid 是否存在 —— pid 被别的进程复用时
   会误判成"已在运行"从而永远不启动。修：额外校验 `/proc/<pid>/cmdline` 含 `--interface=usb0`。
3. `rm -f "$PIDFILE"` 改为无条件清理（原来 `-s` 判断，空 pidfile 会残留）。

**实机验证（重启后，PC 全程零配置）**：
```
en27 自动拿到 172.16.42.6
SSH(v4) 172.16.42.1 通，hostname=odin，uptime 1 分钟（刚重启）
dnsmasq pid 281 开机自启成功，监听 usb0，range 172.16.42.2–172.16.42.10
日志：bound UDC=7000000.usb → usb0=172.16.42.1/24 → dnsmasq started (pid 281)
```
⇒ **以后重启手机再也不用碰 PC 的网络设置。**
（PC 侧拿到 .4/.6 会变，但不影响使用——SSH 连的是手机侧固定的 172.16.42.1。）
（dnsmasq 日志时间戳显示 Apr 27 是手机系统时钟未同步，非故障。）

### 拾肆、⚠️ 更正：启用 GPU 是正确修复，但**没有解决面板 -EINVAL**

**更正此前判断**：上面那次"面板初始化成功"是**误判** —— 当时开着 `drm.debug`，
dmesg 环形缓冲被 vblank 日志刷爆，早期的 `Failed to initialize panel` 已被冲掉，
于是 grep 到"0 次失败"。**去掉 drm.debug 后干净日志显示：面板 -EINVAL 一直存在**，
与 GPU 无关（此前 GPU disabled 时同样失败）。

**启用 GPU 本身仍是对的**（markw 的 DTB 有完整 gpu 节点，odin.dts 漏了 ⇒ 已补，adreno 已绑定）。

**当前干净日志（去掉 drm.debug 后）**：
```
[27.330957] msm_mdp: bound 1a94000.dsi (ops dsi_ops)
[27.334418] adreno 1c00000.gpu: supply vdd not found, using dummy regulator
[27.338690] adreno 1c00000.gpu: supply vddcx not found, using dummy regulator
[27.351643] msm_mdp: bound 1c00000.gpu (ops a3xx_ops)
[27.403052] Direct firmware load for qcom/a530_pm4.fw failed with error -2   ← GPU 微码缺
[27.408603] [adreno_request_fw] *ERROR* failed to load a530_pm4.fw
[27.449170] ft8716 1a94000.dsi.0: Failed to initialize panel: -22            ← 仍未解决
[27.474164] [mdp5_irq_error_handler] *ERROR* errors: 04000000
[27.491132] fb0: sys_imageblit: framebuffer is not in virtual address space  ← 另一个问题

DSI enabled=enabled status=connected dpms=On；backlight=4095/4095；fbcon bind=1
GPU firmware 错误数=2（a530 微码缺）
```

**定位进度（判据逐个排除）**：
DSI 主机 `drivers/gpu/drm/msm/dsi/dsi_host.c:1710 dsi_host_transfer()`:
```c
if (!msg || !msm_host->power_on) return -EINVAL;   ← 静默，不打印
```
实机 grep 各判据结果（全部 0 次 ⇒ 失败来自上面这个静默分支，或另一个未打印的路径：
```
packet size is too big     : 0
cmd cannot fit into BLLP   : 0
Power on failed            : 0
failed to prepare host     : 0
create packet failed       : 0
cmd dma tx failed          : 0
```
注：`dsi_manager.c:244` 有注释 "Enable before preparing the panel, disable after unpreparing"，`dsi_mgr_bridge_power_on()` 末尾会 `msm_dsi_host_enable_irq()` 后才返回 ⇒ 理论上
`power_on` 在 panel prepare 时为 true，但实机时序显示 panel prepare(27.449) 在
host enable 之前(27.474 才出 error irq) ⇒ **bridge 链顺序仍需确认（谁先 pre_enable）。
`drm_panel_bridge` 在 msm 中的挂载点尚未找到（grep msm/ 无 `drm_panel_bridge`）。

**下一步（已明确）**
1. **重编 `panel_ft8716.ko` 加打印**，定位具体失败的第 N 条命令（驱动树已完整构建过，`make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=drivers/gpu/drm/panel modules）
2. 补 GPU 微码 `qcom/a530_pm4.fw` / `a530_pfp.fw`（Debian 无 firmware-misc-nonfree 候选，需从 pmOS 的 firmware-qcom-adreno-a530 或原厂 ROM 取
3. 查 `fb0: sys_imageblit: framebuffer is not in virtual address space（影响 fbcon 显示）
4. 若 bridge 顺序有问题，可尝试把初始化命令从 `prepare` 移到 `enable`

**教训（方法层面）**
- 用 `drm.debug` 抓日志前，先确认要抓的类别不会刷爆缓冲；否则早期错误被覆盖，会得到假结论（本次已踩两次：一次误判成功，一次误判 GPU 是根因）
- 任何"日志里没这个错误"的结论，都要先验证环形缓冲是否完整（`dmesg | head -3` 看最早记录的时间戳）
- `dd` 直接写 `/dev/fb0` 不一定刷到硬件（msm 的 fbdev 需要 damage 触发），不能作为"像素管道不通"的证据
- `default-brightness = <200>` 相对 `max 4095` 只有 5%，看起来像没开背光 ⇒ 已改 2048（50%）
- ssh 需带 `-o PreferredAuthentications=password -o PubkeyAuthentication=no`，否则 sshpass 的密码用不上
- zsh 里变量不做单词分割，`$SSHO` 会被当成单个参数 ⇒ 要么写完整选项，要么用脚本文件

### 拾伍、当前未解：面板初始化 -EINVAL（屏幕仍未亮）

### 拾肆、当前未解：面板初始化 -EINVAL（屏幕仍未亮）

```
ft8716 1a94000.dsi.0: Failed to initialize panel: -22
[drm:mdp5_irq_error_handler] *ERROR* errors: 04000000
msm_mdp 1a01000.display-controller: no GPU device was found
Unbalanced enable for IRQ 39   (WARNING，来自 wled_ovp_work 过压处理)
已修好的：/sys/class/backlight/backlight 出现；/dev/dri/{card0,renderD128}、fb0 出现
```

- 失败点：`ft8716_prepare()` → `variant->on()`。on() 里只有两个**有日志**的失败点
  （exit_sleep / display_on），但日志里没有这两条 ⇒ 是 123 条序列中某条被
  `dsi_dcs_write_seq` 宏**静默 return**（该宏不打印日志）⇒ 本质是 **DSI 主机拒收命令**。
- 已排除：供电没问题（`regulator_bulk_enable` vddio/vdd/lab/ibb 全部成功之后才失败）。

**高嫌疑：DTS 漏了启用 GPU**
- `msm8953.dtsi` 里 `gpu: gpu@1c00000` 默认 `status = "disabled"`；
  配套 `zap_shader_region: zap@81800000`、`gpu_zap_shader: zap-shader` 都在 dtsi 里。
- **odin.dts 里完全没有 `&gpu { status = "okay"; }`** ⇒ 实机 `GPU 设备不存在`、`/dev/kgsl*` 无。
- 对比 markw：DTB 里有完整 `gpu@1c00000` + zap-shader + `firmware-name = "qcom/msm8953/xiaomi/markw/a506_zap.mdt"`。
- 另：镜像里**没有任何 GPU 固件**，只装了 `firmware-atheros`。a506_zap.mdt 属 postmarketOS
  专有包（从原厂 ROM 提取），Debian 与容器里都没有 ⇒ 需从原厂 ROM 取（`refs/`、`Pro_user_V4.2.5/`）。

**下一步**
1. odin.dts 补 `&gpu { status = "okay"; }`（无需固件也能先验证 GPU 是否影响 DSI 命令）
2. 从原厂 ROM 找 a506_zap.mdt（`/firmware/image/`、`/vendor/firmware/`）
3. 若与 GPU 无关，继续查 DSI 主机拒收命令的原因（`MIPI_DSI_MODE_LPM` 标志 / host 时序）
4. 顺带：wled OVP 过压（ovp 现为 29600，备用更保守值 19600）引发的 `Unbalanced enable for IRQ 39`

### 待清理清单（最后统一做，中途不删）
- `/Volumes/caseSensitiveBar/.dtbbuild/`（DTB 标定临时目录，仓库外）
- 容器内 `/tmp/dtbbuild`、`/tmp/dtbcal`、`/tmp/asf.sh`
- 容器内 `/mnt/src`、`/mnt/src-qemu`（旧镜像只读挂载取证点，仍挂着 loop）
- 容器内 `/mnt/chk`（本次核查挂载点，仍挂着 `dist/odin-debian.img`）
- 宿主 `/tmp/odin-*.log`、`/tmp/odin-md5.txt`


### 拾陆、★ 成功：屏幕点亮 + DHCP 稳定（两个长期问题都解决）

**A. 屏幕不亮 —— 根因：面板初始化命令发得太早**

drivers/gpu/drm/msm/dsi/dsi_host.c:1710 dsi_host_transfer() 开头：
    if (!msg || !msm_host->power_on) return -EINVAL;     ← 静默，不打印任何日志

而 panel-ft8716.c 的 drm_panel_funcs 原来只有 prepare/unprepare/get_modes（**没有 enable**），
初始化 DCS 命令全在 prepare 发。实机时序证明 panel prepare 发生在 DSI 主机上电之前 ⇒ 每条命令
-EINVAL，所以日志里只有一句 "Failed to initialize panel: -22"，极具迷惑性。

关键时序（已去掉 drm.debug 的干净日志）：
    [27.822154] bound 1c00000.gpu (ops a3xx_ops)
    [27.879968] [adreno_request_fw] failed to load a530_pm4.fw
    [27.919011] FT8716 DBG: cmd[0] len=2 reg=0x00 ret=-22    ← 第一条就失败
    [27.945115] [mdp5_irq_error_handler] errors: 04000000      ← 之后主机才 enable

修复（已提交 patches/0008-drm-panel-ft8716-send-init-sequence-in-enable-not-prepare.patch）：
  - on() 移到新增的 ft8716_enable()；off() 移到 ft8716_disable()
  - prepare 只保留上电 + reset
  - 定位手段：临时给 dsi_dcs_write_seq 宏加打印（已 revert，实测 FT8716 DBG 残留 = 0）

**B. DHCP 不稳定 —— 双重根因**
1. **MAC 固定失效（我脚本的 bug）**：
   旧代码 `[ -f host_addr ] || echo $MAC > host_addr`，但 configfs 的 host_addr/dev_addr 文件
   **总是存在**（内核填随机值）⇒ 判断恒真 ⇒ 永远跳过写入 ⇒ 每次重启新 MAC。
   且绑定 UDC 后这两个属性不可写（Permission denied）。
   改为 usb0 出现后 `ip link set usb0 address`（实测生效：02:00:0d:1d:00:02）。

2. **地址池被旧租约占满**：每次新 MAC 一条 12h 租约，九个地址（.2~.10）耗尽 ⇒ 新客户端
   "no address available"。

修复（采纳用户思路：永远只连一台电脑，不按 MAC 区分）：
  - 地址池改为**单地址** 172.16.42.2~172.16.42.2（任何 MAC 都分到同一个 IP）
  - 每次重建 gadget 前 `rm -f /var/lib/misc/dnsmasq.leases`
  - 租约 12h → 1h

**C. 最终实机状态（存档：evidence/device-probe/STATE-DISPLAY-OK.txt）**
```
Failed to initialize panel = 0
DSI enabled=enabled status=connected dpms=On
backlight = 4095/4095
fb0 = 1080,1920   fbcon bind=1
GPU = adreno（a530 微码仍缺，不影响显示）
usb0 MAC = 02:00:0d:1d:00:02
usb0 IP  = 172.16.42.1/24
dhcp-range=172.16.42.2,172.16.42.2,1h
DHCPACK(usb0) 172.16.42.2 <pc-hostname>     ← PC 自动拿到固定 IP
cmdline: console=ttyMSM0,115200n8 ... console=tty0     ← 控制台上屏
/ = 111G，已用 916M
```

**D. 这轮用到的两个关键技巧（可复用）**
- **IPv6 链路本地兜底通道**：当 IPv4 DHCP 挂了，手机仍可用 `ssh user@fe80::<EUI64>%enXX` 连上。
  实际地址不是 fe80::1（我加的固定地址服务没生效），而是由 MAC 推导的 EUI-64：
  MAC 02:00:0d:1d:00:02 ⇒ fe80::67ff:fedb:feba。
  发现方法：`ping6 -c 2 ff02::1%<iface>` 看谁回应。
- **定位"静默失败"的通用手段**：给判据处的宏/函数临时加打印，重编**单个模块**（`make M=drivers/... modules`），
  scp 到设备覆盖 .ko + depmod，重启看日志；定位完 revert 重编干净版。

### 待办（下一轮）
1. GPU 微码固件 `qcom/a530_pm4.fw` / `a530_pfp.fw` 仍未装（Debian 无 firmware-misc-nonfree 候选，pmOS 的 firmware-qcom-adreno-a530 才有）
2. `fb0: sys_imageblit: framebuffer is not in virtual address space`（影响 fbcon 显示质量）
3. 修复 odin-usb6-addr.service（fe80::1 固定地址没生效，改用 EUI-64 发现即可，或修服务让它真的加上）
4. 待最终清理：仓库根目录的空文件 power_on（我的 shell 误操作产物）
5. 尚未刷入：dist/ 镜像未重刷到手机（当前手机系统是之前刷的 + 增量部署的模块与配置）；
   若要从零复现，需用 fastboot 重刷 dist/lk2nd.img + dist/odin-debian-sparse.img
6. 考虑把 dist/lk2nd.img 换成精简版（去掉 markw）：需要刷 boot 分区（有风险，需确认）

