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

### 待清理清单（最后统一做，中途不删）
- `/Volumes/caseSensitiveBar/.dtbbuild/`（DTB 标定临时目录，仓库外）
- 容器内 `/tmp/dtbbuild`、`/tmp/dtbcal`、`/tmp/asf.sh`
- 容器内 `/mnt/src`、`/mnt/src-qemu`（旧镜像只读挂载取证点，仍挂着 loop）
- 容器内 `/mnt/chk`（本次核查挂载点，仍挂着 `dist/odin-debian.img`）
- 宿主 `/tmp/odin-*.log`、`/tmp/odin-md5.txt`
