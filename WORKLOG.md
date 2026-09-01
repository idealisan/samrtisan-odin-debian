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


---

## 拾柒 [2026-08-29 22:30] 需求：整理成「从原生 Fastboot 从头刷入」的完整可复现流程

用户原话：「我们需要给它整理成能够从头刷入的脚本和镜像。从头刷入的意思是，从设备自带的
原生的 Fastboot 开始，刷入 LK2ND，然后再执行的一系列操作，到能够连接 SSH。成功使用这个
系统，这样一个完整的流程……先说说你准备怎么做？」

### 现状盘点（22:26 实测）
| 产物/资源 | 路径 | 状态 |
|---|---|---|
| 内核树 | `/Volumes/caseSensitiveBar/linux-msm8953`（分支 odin-wip） | 在，含 0001-0008 |
| 补丁 | `patches/0001..0008` | 齐（0008=面板 init 挪到 enable） |
| DTB | `dts/*.dtb` × 4 | 齐（含背光 2048/GPU 修复） |
| lk2nd 原版 | `dist/lk2nd.img` 366608 B + `lk2nd/bin/emmc_appsboot.mbn` | 已真机验证可启动 |
| lk2nd 精简版 | `dist/lk2nd-nomarkw.img` 364560 B（去掉 markw 条目） | **未经真机验证** |
| Debian 镜像 | `dist/odin-debian.img` 2GiB + `-sparse.img` 660MB | 8/29 12:46 批次，**不含** 0008/背光/DHCP 三项修复 |
| rootfs overlay | `dist/build/rootfs/`（6 个文件） | 含最新 odin-usb-role.sh（单地址池） |
| staging 修复 | `dist/build/apply-staging-fixes.sh` | 含 §4/§5/§6 |
| 镜像导出 | `tools/build-image.sh` | 含全量回读校验 |
| 构建容器 | docker `odin-build`（debian:bookworm，Up 27h） | 在 |
| 主机 fastboot | `/opt/homebrew/bin/fastboot` 36.0.0 | 在 |

### ⚠️ 关键判断
**现有 dist/ 镜像落后于真机**：手机现在跑的是「早期镜像 + 增量部署的 .ko / DTB / 脚本」，
而 `dist/odin-debian.img` 是 12:46 生成的，之后的三项关键修复（0008 面板、DTB 背光+GPU、
odin-usb-role.sh 单地址池）**都没烘焙进去**。直接拿它从头刷 ⇒ 必然黑屏 + DHCP 不稳。
⇒ 所以「从头刷入」的第一步不是刷机，而是 **先重跑一遍构建管线，产出一个与真机等价的镜像**。

### 计划（待用户确认后执行）

**A. 构建侧 —— `tools/build-all.sh`（一条命令重建全部产物）**
1. 校验内核树：确认 0001-0008 已 apply（`git -C linux-msm8953 log/diff`）
2. 重编 `panel-ft8716.ko`（容器内 `make ARCH=arm64 M=drivers/gpu/drm/panel modules`）
3. `dts/build-dtb.sh` → 4 个 DTB
4. 以**当前真机系统**为基线建 staging（SSH + rsync/tar 拉回，而非用旧的 /mnt/debian），
   再套 `apply-staging-fixes.sh` 打 overlay + 新 .ko + 新 DTB + extlinux.conf
5. `tools/build-image.sh` → `odin-debian.img` + `-sparse.img`，全量回读校验
6. 生成 `dist/MANIFEST.sha256`，记录每个产物的 md5/大小/来源

**B. 刷机侧 —— `flash/flash-all.sh`（原生 fastboot → SSH 可用，可重入）**
拆成带序号的阶段脚本，任何一步失败都能从那一步重跑：
```
00-precheck      本机 fastboot/镜像/md5 校验、SSH 可达性、备份提醒
10-backup        经 SSH 备份真机关键文件（/extlinux /usr/local/sbin /etc/udev
                 /lib/modules/.../panel-ft8716.ko /etc/systemd 自研单元）
20-fastboot      轮询等待设备进入原生 fastboot（引导用户按 音量减+电源）
30-flash-boot    fastboot flash boot <lk2nd>
40-flash-data    fastboot flash userdata odin-debian-sparse.img（失败回退 raw，带重试）
50-boot          fastboot reboot，等待 USB NCM 网卡出现
60-usbnet        等 PC 拿到 172.16.42.2（DHCP 优先，超时则静态兜底）
70-ssh           等 22 端口可达，SSH 登录
80-verify        跑 12 项验收（内核/面板/背光/DRM/usb0/dnsmasq/扩容/…）
90-handoff       提示切 l0 完整版、OTG、GPU 微码等后续项
```
配套：`flash/lib/common.sh`（日志/重试/超时/时间戳）、`flash/rescue.sh`（IPv6 EUI-64 /
initramfs telnet / 串口 三条兜底通道）、`flash/STATE.md`（状态机 A/B/C/D 与循环策略）。

**C. 需要用户拍板的两件事**
1. 首刷用哪个 lk2nd：原版（已验证，但可能命中 markw 条目 ⇒ 无屏）/ 精简版（强制命中 odin，
   理论上必亮屏，但从未刷入过真机）
2. 刷 userdata 会清空手机全部数据 —— 是否需要先做一次 userdata 全量备份

### 待办（延续）
（见上一节 1-6 项，另加：本轮新增的构建/刷机脚本）

---

## 拾捌 [2026-08-29 22:50] 全量备份 + 发布准备

### A. 真机全量备份（已完成）
产物在**手机上**：`/root/odin-backup/rootfs-full.tar`（953 MB，16392 条目，tar rc=0，
`DONE` 标记已落）。脚本 `flash/stages/10-backup.sh`，三个子命令：
- 无参数：在手机上打包（nohup 后台 + 每 5s 轮询大小，只用一条 stat，hub 繁忙也安全）
- `--status`：看进度
- `--fetch`：HTTP 拉回（`python3 -m http.server` 绑 172.16.42.1，`curl -C -` 断点续传）

**踩坑 1（重要）**：最初写成 `ssh 设备 tar -cf - / | gzip > 本机`，两次都在 ~14s/~110MB
处断，设备随后 30s 完全不响应 ping。分离测试证明**不是网络问题**——纯流量压测
400MB 用 20s 跑完（约 20MB/s）。是设备端 tar 边读边往外吐时 USB NCM 会 stall。
⇒ 大批量数据先在设备本地落盘，传输阶段只做顺序大文件拷贝。

**踩坑 2**：`/root` 是 0700，用 `odin_ssh`（user 身份）去 `tar -tf` 只得到空输出，
差点把一份完好的备份判成"截断"。⇒ 涉及 /root 一律用 `odin_sudo*`。
已把这条写进 `flash/lib/common.sh` 的注释。

**踩坑 3**：bash 在 C locale 下把紧跟在 `$VAR` 后面的中文字符当变量名的一部分
（`DEVICE_IP）——先确认` ⇒ `DEVICE_IP\uFFFD: unbound variable`）。
⇒ 所有脚本里变量一律写成 `${VAR}`。

### B. 关键事实修正：boot 分区里不是我们的 lk2nd
实测 `/dev/disk/by-partlabel/boot` 的 bootimg 头 `kernel_size=339260`，
既不是 `dist/lk2nd.img`(352980) 也不是 `lk2nd-nomarkw.img`(351316) ⇒
**boot 分区至今仍是 pmOS 原版 lk2nd 21.0**（当时只用 `fastboot boot` 内存启动验证过精简版）。
- 备份 `evidence/live-device-backup/boot-partition.img` 与实时分区**逐字节一致**（md5 相同）
  ⇒ 有可靠回滚路径。
- 屏幕之所以亮，靠的是 DTB 里写死 `compatible="smartisan,odin-ft8716"`，
  与 lk2nd 选中哪个条目无关。所以刷精简版 lk2nd 是"再加一道保险"，不是雪中送炭。

### C. 发布前的安全修复：SSH 主机密钥
`git grep "BEGIN ... PRIVATE KEY"` 在两个刷机镜像里命中 —— 镜像带着一把固定的
SSH 主机私钥，公开发布等于所有设备共用同一身份（可 MITM）。
- `tools/build-image.sh` §2 干净化：删除 `/etc/ssh/ssh_host_*`
- `dist/build/apply-staging-fixes.sh` §2b：新增 `odin-ssh-hostkeys.service`
  （`Before=ssh.service`，`ssh-keygen -A` 只补缺失的类型，尾部 `exit 0` 保证失败也不挡 SSH）
- 不能用 ssh.service 的 ExecStartPre drop-in：Debian 自带 `ExecStartPre=/usr/sbin/sshd -t`，
  而 drop-in 的 ExecStartPre 是**追加**在其后，无密钥时 `sshd -t` 直接退出，轮不到生成动作。

### D. extlinux.conf 与 DTB 对齐真机
真机验证可用的是 `*-ft8716*.dtb`（面板写死），仓库里却指向自动识别版，且 append 少了
`console=tty0`（控制台上屏开关）。已同步：
- `dist/build/rootfs/extlinux/extlinux.conf` 两个 label 都改指 ft8716 变体 + 补 `console=tty0`
- `apply-staging-fixes.sh` §4 改为部署**四个** DTB（主用 ft8716 对，自动识别对留作换屏退路）

### E. 准备公开仓库（进行中）
- 安装 `git-filter-repo` 2.47.0
- 审计结果：730 个二进制文件 / 5.18 GB 已入库，`.git` 达 4.7 GB
  （2GB 刷机镜像、660MB sparse、147MB 内核模块树、40MB busybox、2.2GB QEMU 测试盘、
  evidence 下解出来的整个 initramfs 树）
- 隐私扫描：无私钥/无 `/Users/xxx` 路径；有设备侧 MAC（由 eMMC 序列号派生）与
  PC 主机名（DHCP 日志里的 `<pc-hostname>`）
- `.gitignore` 已加上 `*.img/*.dtb/*.ko/*.mbn/*.tar*/*.cpio.gz/*.bin/*.elf` 等规则
- 计划：在 `/tmp` 的克隆副本上跑 filter-repo 清历史（**不动源仓库**），
  验证干净后再推 `git@github.com:idealisan/samrtisan-odin-debian.git`

---

## 拾玖 [2026-08-29 23:24] 公开仓库已推送

地址：https://github.com/idealisan/samrtisan-odin-debian （PUBLIC，仓库名沿用用户给的拼写）

### 结果
| 项 | 前 | 后 |
|---|---|---|
| `.git` | 4.7 GB | 772 KB |
| 跟踪文件 | 908（含 728 个二进制 / 5.18 GB） | 181（纯文本） |
| 提交 | 31 | 31（全部保留） |
| 最大文件 | 2 GB 刷机镜像 | 199 KB 内核 config |

### 清理手段（已固化为 `tools/prepare-public-repo.sh`）
```sh
tools/prepare-public-repo.sh /tmp/odin-clean ~/.config/odin-port/replacements.txt
```
1. 剔除全部二进制（file(1) 判定非 text 的）+ 剔除 >250KB 的 blob（清掉历史里误入库的 2GB 镜像）
2. 脱敏：`--replace-text`（文件内容）+ `--replace-message`（**提交信息**）
   —— 只做前者会漏：最初扫历史仍命中 3 处，全在 commit message 里
3. **源仓库完全不动**，输出是一个独立的、历史已重写的克隆

脱敏规则文件放在仓库**外面**（`~/.config/odin-port/replacements.txt`）：
规则里必然写着要替换的原串，一旦入库等于把想藏的东西又写回公开仓库。

### 脱敏掉的
- eMMC 序列号 `<emmc-serial>` → `<emmc-serial>`
- 由序列号派生的 gadget MAC `02:00:0d:1d:00:02/:b9` → `02:00:0d:1d:00:01/02`
  （`odin-usb-role.sh` 里原本写死的是本机派生值，已改为通用占位，可用环境变量覆盖）
- PC 主机名 → `<pc-hostname>`（DHCP 日志片段）

### 脚本本身踩的三个坑（macOS 自带 bash 3.2）
1. **bash 3.2 解析不了 `$( )` 里带 `;;` 的 case** —— macOS 默认 shell 就是 3.2，
   最小复现都报 `syntax error near unexpected token ';;'`。把判定抽成 `is_binary()` 函数解决。
2. `set -e` 下 `is_binary "$f" && printf ...` 遇到文本文件返回 1，作为 while 最后一条
   命令会把整个子 shell 带崩（脚本静默退出）。改用 if/then/fi。
3. 私钥自检命中了脚本自己那行 grep 模式 → 加 `grep -v` 过滤自引用。

### 待办
- **Release 资产尚未发布**：`dist/` 里的 Debian 镜像还是 8/29 12:46 批次，缺 0008/背光/GPU/
  DHCP 四项修复。等 `tools/build-all.sh` 重建出与真机等价的新镜像后，再一次性发布 v0.1，
  含 lk2nd 两个版本 + 4 个 DTB + 新镜像 + MANIFEST。现在发只会发布一个必然黑屏的镜像。

---

## 贰拾 [2026-08-30 00:06] GitHub Actions 构建流水线

### 触发条件（按用户要求）
只挂 `release: [prereleased, released]`。
**不要用 `published`** —— GitHub 发布 prerelease 时同时发 `published` 与 `prereleased`，
实测一次发布触发了两个 run（33261492532 / 33261492105）。prereleased 覆盖预发布、
released 覆盖正式版，两者不重叠。

### 五个 job
`dtb` / `lk2nd` / `kernel` / `rootfs(needs kernel+dtb)` / `publish(全部产物挂 Release)`

### ★ 关键更正：lk2nd 的上游不是 msm8953-mainline
我们的补丁路径是 `lk2nd/device/dts/msm8953/...`，而 msm8953-mainline/lk2nd 的设备树在
`dts/`、设备表在 `dts/rules.mk` —— 完全对不上。
真实上游是 **msm8916-mainline/lk2nd tag 19.0**（postmarketOS 用的就是这个版本，
设备上 `lk2nd:version : 21.0-r0-postmarketos` 即由此打包）。
- 构建目标：`make TOOLCHAIN_PREFIX=arm-none-eabi- PROJECT=lk2nd-msm8953`
- 产物：`build-lk2nd-msm8953/lk2nd.img`
- 本地源码在 `/Volumes/caseSensitiveBar/refs/lk2nd`（非 git 仓库，是从 pmaports 解出来的）

新增 `lk2nd/0004`：从 QCDT 设备表去掉 `msm8953-xiaomi-markw` 与 `sdm450-xiaomi-rosy`，
强制 lk2nd 命中 odin。这一步原先是手改 rules.mk 做的，CI 里无法复现，固化为补丁。

### 首轮 CI 三个 job 全败（rc1），根因
1. **dtb/kernel：`upload-pack: not our ref af739964a952`**
   钉的 SHA 是本地 `odin-wip` 的 HEAD —— 它已经含我们的 0007 补丁，不是上游提交。
   应钉上游基线 `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b`（Linux 6.19，master）。
2. **lk2nd：`LK2ND_VER: 19.0` 在 YAML 里是浮点数**，GitHub 传进来成了 `19`，
   下载 URL 404 → `gzip: stdin: not in gzip format`。已加引号。
3. **`git fetch --depth 1 origin <sha>` 只对 ref tip 有效**：基线一旦被 master 甩开就被拒。
   新增 `tools/ci/fetch-kernel.sh` 三级回退（按 SHA 直取 → `--shallow-since=<基线前一天>`
   → 整支 master），每级结束校验 HEAD == 目标 SHA。钉不住宁可失败，
   也不悄悄编一个"上游最新版"——那样就失去可复现的意义了。

### 待跟进
- rc2（run 33262051573）是修完后的第一轮，结果待看
- `kernel` 与 `rootfs` 两个 job 从未跑通过，属首次验证

---

## 贰拾壹 [2026-08-30 00:52] ★ WiFi 打通（WCNSS / wcn36xx）

### 根因
实机上根本没有 wlan0：`msm8953.dtsi` 里 `wcnss: remoteproc@a204000` 默认
`status = "disabled"`，我们的设备树此前也没启用它。模块（`wcn36xx.ko`、
`qcom_wcnss_pil.ko`）和 WCNSS 固件（`wcnss.mdt` + .b00/.b01/.b02/.b04/.b06/.b09
~.b12）其实都在，只是设备树没开门。

### 配置来源（照抄能正常用 WiFi 的 markw）
反编译 `evidence/live-device-backup/pmos-diag/boot/msm8953-xiaomi-markw.dtb`
拿到它的实际配置，再用脚本把 phandle 解成节点名：
```
&wcnss      status=okay  vddpx  -> l5 (1.8V)
&wcnss_iris compatible="qcom,wcn3660b"
            vddxo -> l7   (1.8V)
            vddrfa-> l19  (1.3V)
            vddpa -> l9   (3.3V)
            vdddig-> l5   (1.8V)
```
交叉验证：原厂 DTB（evidence/stock.dts）声明的 iris 四路电压正是
1.8V / 1.3V / 3.3V / 1.8V，与本文件各 LDO 的量程区间吻合。

### 还差一块：板级校准数据
`WCNSS_qcom_wlan_nv.bin`（wcn36xx 的 WLAN_NV_FILE =
`wlan/prima/WCNSS_qcom_wlan_nv.bin`）**原先没有**。它是每台机器不同的射频
校准数据，任何 Debian 包都不提供，也不该进版本库。
在 **persist 分区（mmcblk0p24，我们唯一没动过的原厂分区）** 里找到了：
- WCNSS_qcom_wlan_nv.bin (31723 B)
- WCNSS_wlan_dictionary.dat
- wlan_mac.bin / wlan_random_mac.bin

⇒ 新增 `odin-wlan-nv.service` + `odin-wlan-nv.sh`：开机从 persist 现取到
`/lib/firmware/wlan/prima/`；若驱动已先加载，重新 modprobe 让它读到。
取不到最坏只是没 WiFi，不会拖挂启动。

### 实机验证
```
wcn36xx: firmware WLAN version 'WCN v2.0 RadioPhy vIris_TSMC_4.0 with 48MHz XO'
wlan0 出现、rfkill 未阻塞、扫描到 31 个网络
连上 AP 拿到 192.168.3.165；ping deb.debian.org 3 发 3 收，0% 丢包
路由：默认走 wlan0(metric 600)，172.16.42.0/24 仍走 usb0 ⇒ USB SSH 不受影响
```

### 顺带踩的两个坑
1. **DNS**：该路由器广播 DNS 192.168.3.1，但它根本不应答 UDP 53 ⇒
   能 ping 通 IP 却解析不了域名。装 `systemd-resolved` 才有按序尝试后续
   服务器的能力；连接级可用
   `nmcli con modify <名> ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1,8.8.8.8"` 覆盖。
2. **时钟**：设备无 RTC，时钟差几个月 ⇒ apt 拒绝 Release 文件
   （`Release file ... is not valid yet`）。装 `systemd-timesyncd` 联网自动校时。

### 交互式管理（用户要求"命令行就能扫描连接，不要改配置文件"）
`nmcli` 本身就是交互式 CLI：
```
nmcli dev wifi list                       # 扫描
nmcli dev wifi connect <SSID> password <密码>   # 连接（自动建持久连接）
nmcli dev status / nmcli con show         # 查看
nmcli con up|down|delete <名>             # 管理
nmtui                                     # 文本界面
```
网络调试工具已按"正常 Debian 服务器"标准装齐：iputils-ping / curl / wget /
bind9-dnsutils / net-tools / traceroute / tcpdump / iperf3 / ethtool / mtr-tiny。

### CI 进展（ci-fixer 主导）
- **lk2nd ✅ / dtb ✅ 已变绿**，kernel 仍在编（约 22 分钟），rootfs 未开始
- ci-fixer 找出两个我漏掉的根因：
  1. `patches/0007` 是坏补丁：hunk 头声明 383 行、正文却有 385 行（手工改过
     compatible 却没同步行数），GNU patch 按 383 行截断 ⇒ dts 少两行没闭合
  2. lk2nd 该钉 **tag 23.1** 而不是 19.0（0002 的 rules.mk 上下文是 23.x 的设备表）
- 我修的：kernel job 其实是**编译成功**后死在 `cp out/kernel/vmlinuz` ——
  脚本 `cd` 进内核树后 $OUT 相对路径失效；四个脚本的 $OUT 统一转绝对路径
- 构建日志已全部改成 `tee` 双写，CI 页面能实时看到编译过程

---

## 贰拾贰、v0.9.1 发布与真机基准验证（2026-08-30）

### 背景与目的
此前真机跑的系统是 8/30 12:01–12:04 手工摆上去的（`/boot/vmlinuz` 时间戳 12:01、
`/boot/dtbs/qcom/*.dtb` 12:04，`uname` 显示 `6.19.0-postmarketos-qcom-msm8953+`），
**不是 CI 制品**，按 AGENTS.md §1.4 只能算开发尝试，不能作为基准。
本轮目的：用 CI 构建的 v0.9.1 完整刷一遍，把验证结果定为后续开发的基准线。

### 13:12 发布 v0.9.1（Pre-Release）
- 基准提交 `4706103`；相对 v0.9.0 只有 3 笔提交（f6feac1 / ea7275f / 4706103）
- CI `release-build` run `33294177252` 五个 job 全绿：
  dtb 34s、lk2nd 50s、kernel 1m42s、rootfs、publish → **completed / success**
- 8 个资产：lk2nd.img / lk2nd-nomarkw.img / 4× dtb / odin-debian.img /
  odin-debian-sparse.img / SHA256SUMS

### 13:36 制品下载与校验（落在 tmp/release-v0.9.1/）
- `shasum -a 256 -c SHA256SUMS` 已下载 7 个全部 **OK**（raw 版 odin-debian.img 未下，仅作回退）
- 本机 md5 存档：
  ```
  1e482a89404cb722c22293150d1323f1  lk2nd-nomarkw.img
  cca537d6140531ffc4ec6a69a858545c  lk2nd.img
  47d2e0017e5882633eef8d23e535f454  odin-debian-sparse.img
  92dbbb8c83b2d6e6235399974120a02f  msm8953-smartisan-odin-ft8716-norolesw.dtb
  9a32ce00d5f7d2c8db521281e8bb9637  msm8953-smartisan-odin-ft8716.dtb
  b67413fc2651536d27dadaec3ac604a8  msm8953-smartisan-odin-norolesw.dtb
  ca210736fe68e615bb091035c2494bd3  msm8953-smartisan-odin.dtb
  ```

### 踩坑：GitHub 下载必须显式去掉代理
本机默认带 `http_proxy`/`https_proxy=http://127.0.0.1:3030`（给别的功能用的），
走它下载 GitHub Release 资产只有 **0.81 MB/s**；直连是 **3.8 MB/s（4.7 倍）**。
实测手法（同一 URL 取前 20 MB 对比）：
```sh
curl -sL -o /dev/null -w '%{speed_download}\n' -r 0-20971519 "$U"      # 走代理
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl ...  # 直连
```
**注意**：不加 `-L` 时测出来是 0 B/s（GitHub 会 302 到 objects.githubusercontent.com，
那 4.2s vs 1.2s 的差只是重定向响应耗时，不是带宽）。以后凡是从 GitHub 下大文件，
一律 `env -u http_proxy -u https_proxy ... curl -L`。

### 设备现状记录（刷之前的取证）
- 状态 C：Debian 12 运行中，SSH `user@172.16.42.1` 可达
- `/dev/mmcblk0p57`（PARTLABEL=`userdata`，LABEL=`pmOS_root`）挂载为 `/`
- `/extlinux/extlinux.conf` 在**根下**（不是 `/boot/extlinux/`），`default l0-safe`，两个 label l0 / l0-safe
- **GPT 里没有 `lk2nd` 分区标签**，`/dev/disk/by-partlabel/` 只有 aboot/boot/recovery/
  persist/system/userdata 等原厂名字；但 fastboot 层会导出 `lk2nd`
  （`fastboot getvar all` 报 `partition-size:lk2nd: 0x80000` = 512 KB）
  ⇒ 设备侧看不到、fastboot 侧能刷，这两件事并不矛盾
  ⇒ 设备侧看不到、fastboot 侧能刷，这两件事并不矛盾

### 13:37–13:40 真机刷入 v0.9.1（`flash/flash-all.sh --from 20`）
用户拍板：**完整刷（含 lk2nd）**，**跳过备份**（此前已备份多次，且当前系统
只是开发中的测试系统、无有价值数据；它疑似是 0.9.0 的 CI 版，但不确定，
本轮正是为了确认）。

| 阶段 | 结果 |
|---|---|
| 20 fastboot | ok（40s，改名 extlinux.conf 后重启落进 fastboot） |
| 30 boot | ok `Sending 'lk2nd' (356 KB) OKAY` → `Writing 'lk2nd' OKAY` |
| 40 data | ok（sparse 40s，未用 raw 回退） |
| 50 reboot | USB 网卡 10s 出现 |
| 60 usbnet | PC 拿到 172.16.42.2 |
| 70 ssh | SSH 可达（30s） |
| **80 verify** | **15 项通过 / 1 项失败** |

通过项：hostname、内核版本、面板驱动 ft8716、DSI connected、DSI enabled、
DRM 节点、面板初始化失败数 0、背光 2048、usb0 地址、wcn36xx 已加载、
sshd active、resize2fs 成功、扩容标记、根分区 112G、modprobe 可用。
失败项：**wlan0 不存在**（实际只有 lo / usb0）。

### 13:44–13:51 查 wlan0：真因是时序，且旧补救动作重载错了对象
- `/lib/firmware/` 下 10 个 `wcnss.*` **其实是齐的**（开机 03:49:16 已全部取到），
  我第一次 `ls /lib/firmware/ | head` 只看到前 10 行（ar3k/ath* 开头），
  `wcnss.*` 排在后面被截断，一度误判成"固件没取到"——**记这个坑：别用 head 看目录**
- 真正在的是：
  ```
  [   10.230706] remoteproc remoteproc0: Direct firmware load for wcnss.mdt failed with error -2
  [   25.899417] EXT4-fs (mmcblk0p24): mounted filesystem ...   ← late service 这时才去取
  ```
  内核 **10.230s** 就索要固件，late service **25.9s** 才动手，晚了 15 秒；
  `request_firmware` 失败后 remoteproc 停在 `offline`，补文件也不会重试
- 旧脚本的补救是 `modprobe -r wcn36xx; modprobe wcn36xx`，**但 wcnss.mdt 是
  remoteproc 读的、不是 wcn36xx 读的**，所以那个补救从来没生效过
- 手工验证（确认判断，不作为修法）：
  `echo start > /sys/class/remoteproc/remoteproc0/state` → `Booting fw image wcnss.mdt`
  → `remote processor is now up`（WCNSS Version 1.5 1.2）；
  再 `modprobe -r wcn36xx; modprobe wcn36xx` → **wlan0 出现**，
  nmcli 显示 `wlan0:wifi:disconnected`，固件 `WCN v2.0 RadioPhy vIris_TSMC_4.0`

### 13:58–14:06 修法：把供给动作放进 initramfs（不做事后补救）
用户要求"最合理正确的修复，像一个正常的 Linux 系统，而不是 Workaround"。
按启动时序，正确落点是 **`switch_root` 之前**：那时真正的根已挂载、
systemd 尚未起来、驱动（约 10s 才索取固件）也还没动作。

- 新增 `dist/build/initramfs/sbin/odin-wlan-fw.sh`（POSIX sh；initramfs 是
  busybox ash，**没有 bash**）
  - 目标根以参数接收，另支持 `--check`
  - 用 `/sys/class/block/*/uevent` 里的 **`PARTNAME`** 定位分区 —— initramfs 里
    没有 udev，`/dev/disk/by-partlabel/` 那套符号链接不存在
  - `cmp -s` 幂等（wcnss.b06 有 3.2MB，不必每次开机重写闪存）
- `dist/build/initramfs/init` 在 `switch_root` 前调用；`--check` 判定缺文件时
  才 `remount,rw`，取完 `sync` 立刻 `remount,ro` ⇒ 绝大多数开机根全程只读
- `initramfs-applets.txt` 补 **`cp` 与 `cmp`** —— 原名单里竟然没有 `cp`
- 不再安装 / enable `odin-wlan-fw.service`；`dist/build/rootfs/` 下那两个文件
  留到统一清理轮次再删（apply-staging-fixes.sh 只拷贝、不 enable，留着无副作用）

**真机实测（假根，不动真 `/lib/firmware`）**：12 个文件全部取出，
与旧服务产出的文件 **md5 全部一致** ✅

### 新增 reports/021 —— 固件与驱动的供给策略
把这个坑固化成规范：固件必须在驱动第一次索取之前就位 ⇒ 落点是 initramfs
而非 late service；附"补一个新外设的实施清单"（查谁在要/何时要 → 确认来源分区
→ 判时序 → 写脚本 → 补 applet → **真机假根验证后再发版** → 确认模块加载时机），
以及"禁止的做法"表（late service / modprobe -r 补救 / 硬编码 mmcblk0pNN 等）。

### 顺带记下的事实
- modem 分区（mmcblk0p52）是 **vfat**、persist（mmcblk0p24）是 **ext4**，
  两者都是内核内置（`/lib/modules/*/kernel/fs/` 里找不到它们）⇒ initramfs 可直接挂
- `wcn36xx` / `qcom_wcnss_pil` 在 `/etc/modules-load.d/odin-wlan.conf`，
  由 `systemd-modules-load` 在 `basic.target` 之前加载 ⇒ 固件已在位，首次加载即成功

---

## 贰拾叁、v0.9.3 真机验收 16/16 全通过（2026-08-30）

### v0.9.2 作废、改用 v0.9.3 的经过
v0.9.2 发布后立刻自查发现：`a1fe79f` 声称"initramfs-applets.txt 补 cp 与 cmp"，
**但那个文件根本没进提交** —— `git add -A dist/build/initramfs ...` 只匹配到
**目录** `dist/build/initramfs/`，而 `dist/build/initramfs-applets.txt` 是它的
**同级文件**（名字以 initramfs- 开头），不在那个目录下。既没 add、也没报错，
提交照样成功。没有 cp ⇒ initramfs 里的固件供给会**静默失败**（脚本失败不致命）。

处置（按 §3.4 新写入的版本号准则，未删旧版本）：
1. `gh run cancel` 掐掉 v0.9.2 正在跑的构建
2. 补提交 `ae85275`
3. **开新号 v0.9.3** 重新发布
4. 在 v0.9.3 说明里写明 v0.9.2 为何作废

v0.9.2 的 Release 先留着，删除放统一清理轮次。

### v0.9.3 CI 与刷入
- CI run `33296547668`，**7m19s completed/success**，8 个资产
- 7 个已下载文件 `shasum -a 256 -c SHA256SUMS` 全部 OK
  （odin-debian-sparse.img md5 `4aa736d5567379938624924779d79c22`）
- **下载踩坑**：直连在中途 `connection reset`（只下了 62MB/855MB）。
  `gh release download` 不支持续传，改用
  `curl -L -C - --retry 8 --retry-all-errors --speed-time 30 --speed-limit 1024`
  断点续传救回。**以后下大文件一律带 `-C -` 与重试**。
- 刷入（含 lk2nd，用户已确认）：20 fastboot 30s → 30 lk2nd ok → 40 userdata 40s
  → 50 reboot（USB 网卡 10s）→ 60 usbnet ok → 70 ssh 40s → **80 verify 16/16，失败 0**

### WiFi 修复的决定性证据（这次是真的修好了）
```
[   11.673944] remoteproc remoteproc0: Booting fw image wcnss.mdt, size 7324
[   13.847119] remoteproc remoteproc0: remote processor a204000.remoteproc is now up
[   34.823256] wcn36xx: firmware WLAN version 'WCN v2.0 RadioPhy vIris_TSMC_4.0 with 48MHz XO'
```
- **那句 `failed with error -2` 彻底消失** —— 驱动第一次索取就拿到了
- 时序对比：
  | | 供给时刻 | 索取时刻 | 结果 |
  |---|---|---|---|
  | 修前（v0.9.1） | 25.9s | 10.230s | 失败，且永不重试 |
  | 修后（v0.9.3） | **~4s**（initramfs） | 11.673s | **首次即成功** |
- `/var/log/odin-wlan-fw.log` 时间戳是 `1970-01-01 00:00:04` —— 开机第 4 秒，
  那时还没有 systemd、时钟也没同步，正是 initramfs 阶段，与预期完全吻合
- `remoteproc0/state = running`，`wlan0` 在 `ip link` 与 `nmcli` 里都在

### 一个每次重刷都会撞到的小坑
刷完后 SSH 报 `REMOTE HOST IDENTIFICATION HAS CHANGED` —— 新 rootfs 会重新生成
sshd 主机密钥，PC 上 known_hosts 里的旧记录失效。
处置：`ssh-keygen -R 172.16.42.1`（旧记录自动留档为 `known_hosts.old`），重连即可。

### v0.9.3 已转正式 Release
`gh release edit v0.9.3 --prerelease=false` → 作为阶段性标志与后续开发基准。

### 下一版目标（用户指定）：lk2nd 反复重启
**现象**：刷入 Linux 系统镜像之前，lk2nd 会反复重启，必须人工按住电源键才能停下，
否则一直重启 ⇒ 无法自动接着刷入系统镜像 ⇒ 开发/调试循环不能完全自动走完。
定位方向（尚未验证，仅为待查）：lk2nd 找不到可启动配置后的 reboot 策略 /
看门狗 / `boot_into_fastboot` 未置位。见 reports/018 §零 的状态机 B 态。

---

## 贰拾肆、v0.9.4 目标（2026-08-30，用户指定）

两个目标：**① lk2nd 反复重启需人工按电源键**、**② 构建改用 Makefile**。
历史 Release 与旧文件按用户指示**一律不清理**，留着即可。

版本号规则也按用户要求改了：目标版本成功前用 `v0.9.4-<简述>` 的 Pre-release
（如 `-lk2nd-reboot`、`-makefile`），只有最终验证通过才用干净的 `v0.9.4`。
（用户最初提时间戳，随后改成简述后缀 —— 理由是时间戳记不住"这版在试什么"。）

### ① 现象与链路
刷入 Linux 系统镜像之前（即改名 extlinux.conf 让 lk2nd 落 fastboot 那一步），
设备**反复重启**，必须人工按住电源键才能停 ⇒ 无法自动接着刷 ⇒ 开发循环断在这里。

### 已查到的事实（lk2nd 23.1 源码 + 真机核对）
1. **`lk2nd_scan_devices()` 找到不启动项时只是打一行日志就返回**
   （`lk2nd/boot/boot.c:63`："Bootable file system not found. Reverting to android boot."）
   —— 它**不会**置 `boot_into_fastboot`。
2. 随后 aboot 走 `retry_boot:` → `boot_linux_from_mmc()`
   （`app/aboot/aboot.c:5687`），失败才落到 `fastboot:` 标签（`aboot.c:5723`）。
3. **boot 分区偏移 512KB 处还留着一个原厂 Android 引导镜像** —— 真机实测：
   ```
   offset 0      : A N D R O I D !     ← lk2nd 本体（lk2nd 也是个 Android boot image）
   offset 524288 : A N D R O I D !     ← 残留的原厂 Android 引导镜像
   ```
   分区布局：`lk2nd` = 0…512KB（`getvar` 报 0x80000），`boot` = 512KB…64MB（0x3f80000），
   两者合起来正好是 mmcblk0p21 的 64MB。

⇒ **真因（待最后确认）**：lk2nd 找不到可启动 fs → 回退引导那个残留的 Android 镜像
→ Android 起不来 → 重启 → 回到 lk2nd → **循环**。
这解释了两件事：为什么会重启（不是停在 fastboot）、以及为什么按住电源键能停
（`is_user_force_reset()` 分支，`aboot.c:5580` 会 `goto normal_boot`）。

### 备选修法（尚未定，也未实机验证）
- **A. `fastboot erase boot`** 清掉残留 Android 镜像 ⇒ `boot_linux_from_mmc()` 失败
  ⇒ 干净落到 `fastboot:`。一次性改动，且 `lk2nd` 分区（0…512KB）不受影响；
  evidence/live-device-backup/boot-partition.img 有全量备份可回退。
  属设备侧改动，按 §7 需用户单独确认。
- **B. 改 lk2nd** 让它在找不到可启动 fs 时直接进 fastboot，而不是回退 Android。
  影响面大（改上游行为），但可随 CI 产物交付。
- **C. 让 Linux 侧能 `reboot bootloader`** —— 真机有 `pon@800`，
  `reboot_mode` + `qcom_pon` 驱动已加载，`/sys/kernel/reboot/mode` 存在但只有
  cold/warm/hard；DT 里**没有** reboot-mode 子节点，需要补节点与魔数。
  这条路最"正常 Linux"，但要先把 lk2nd 期望的魔数核对清楚。

### ② Makefile（下一步做）
当前构建入口全是 `bash tools/ci/*.sh`，无 Makefile。

### lk2nd 循环重启：第一轮排查结论（详见 reports/022）

**推翻了两条假设，都没成立：**

1. **"回退引导残留 Android 镜像"** —— 据此写了 `lk2nd/0005`。
   `strings` 对比证实补丁**确实进了镜像**：
   v0.9.3 是 `Reverting to android boot.`，新版是 `Reverting to fastboot.`
   **但真机行为毫无变化，仍然循环。**
   教训：补丁"进没进镜像"（strings 能验）和"有没有用"（行为变没变）是两回事，
   只验前者会得出虚假的安全感。
   另注：0005 写在 `#if WITH_LK2ND_BOOT` 块里，而该宏全树只在 aboot.c 出现 4 次、
   没有任何 .mk 定义它 —— 若为假则补丁是死代码，这是下一步优先要确认的点。

2. **"panic 重启 + 原因读不回来"** —— 查证后发现**读回路径是完整的**：
   `msm_shared/reboot.c:84` 有 `check_hard_reboot_mode()` 的真实实现
   （读 `PON_SOFT_RB_SPARE`，`(v & 0xFC) >> 2`，读后擦除），且 reboot.o 确实编译
   （`ENABLE_REBOOT_MODULE := 1` 在 msm8953.mk:127/144）。

**过程中的两个自我纠偏：**
- 早期日志里"设备进入 fastboot (30s)"那几次，其实是**用户按了电源键**的结果，
  我之前当成自动流程跑通了 —— 这是后面一连串误判的源头。
- 查 `check_hard_reboot_mode` 时加了 `grep -i 8953` 过滤，把真正实现所在的
  `platform/msm_shared/reboot.c` 滤掉了，一度误判"只有弱实现"。
  **查东西别用想当然的过滤条件先剪枝。**

**下一步：诊断构建。** 把 `lk2nd/project/lk2nd.mk:20` 的
`PANIC_REBOOT_MODE ?= FASTBOOT_MODE` 改成 `NO_REBOOT`，
`platform_halt()` 就会打印后停住不重启，panic 原因能留在屏幕上让用户读到。
代价是这版会卡死、只能纯诊断用。

**为什么迭代慢**：每验证一次 lk2nd 都要先进 fastboot，而进 fastboot 正是坏的
⇒ 每次都要用户按电源键。修它和用它互相卡住。

---

## 贰拾伍、容器化构建环境 + gui 变体（2026-08-30，用户指定）

用户给的三件事：① Dockerfile 定义编译专用镜像并用它起容器（旧 `odin-build`
容器整只放弃，不看、不抄）；② Makefile 增加 gui 变体、保留 core；
③ CI 两个变体都编，本地只编 gui（core 是 gui 的子集）。

- **18:59 未提交的那份 gui 草稿丢弃** —— 用户确认不要。按 §1.3 只增不删的原则，
  先 `git diff` 留档到 `tmp/gui-wip/setup-rootfs-gui-uncommitted.patch`，再
  `git checkout` 回去。GUI 内容按用户"真机上手工验证过的那套"重写，不沿用草稿代码。
  - **草稿有三个致命问题**（这也是判断"它没被执行过"的依据）：
    1. 调用了未定义的 `say()` —— `setup-rootfs.sh` 顶部没这个函数，脚本是
       `set -e` ⇒ `ODIN_VARIANT=gui` 时第一条 `say` 就 command not found，
       exit 127，apt 一行都还没跑。
    2. `ODIN_VARIANT` 根本没接线：`build-rootfs.sh` 只传 `ODIN_ROOTFS`。
    3. `apt-get ... 2>&1 | tail -5 || echo WARN` 会吞掉失败（管道退出码取
       `tail` 的，且没开 pipefail）。

- **19:03 CI 缓存"恢复成功但完全用不上"—— 真因找到了**
  - 现象：kernel job 从不到 10 分钟退化到 29 分钟；日志里
    "Cache hit for: kernel-ccache-<sha>-<patchhash>"、恢复 235 MB 看着一切正常，
    但 `ccache -s` 是 **Hits: 89 / 4399 (2.02%)**。
  - **别把"缓存恢复成功"当成"缓存生效"** —— 那只说明文件下载下来了。要看得看
    `Hits` 行。这是这次最大的教训。
  - 真因是两条 ccache 默认值叠加：
    1. `compiler_check` 默认 `mtime` ⇒ 编译器二进制的 mtime 计入哈希。
       CI 每个 job 都全新 `apt-get install` 交叉编译器 ⇒ mtime 每次都变
       ⇒ 全量未命中。**主因。**
    2. `hash_dir` 默认 `true` ⇒ 带 `-g` 时把 CWD 计入哈希。本内核
       `CONFIG_DEBUG_INFO=y`，而 `KDIR` 从旧脚本的 `/tmp/linux-msm8953`
       迁到 Makefile 的仓库内 `tmp/` ⇒ 历史缓存整体作废。
  - **验证方式：不靠推理，做了个 10 秒的小实验**（debian:bookworm-slim 容器，
    ccache 4.7.5，`gcc -g` 编同一个文件）：
    | 场景 | 默认配置 | content + hash_dir=false |
    |---|---|---|
    | 同目录重编 | 100% | 100% |
    | 换目录（CWD 变） | **0%** | 100% |
    | touch 编译器（模拟重装） | **0%** | 100% |
  - 修法：`ccache --set-config compiler_check=content` +
    `hash_dir=false`，max_size 2G→5G。CI 与容器镜像都改。
  - **已知的一次性代价**：改配置会让既有缓存条目全部失效（哈希规则变了），
    下一次构建仍是全量，再往后才稳定命中。已触发一次 CI 建新缓存。

- **19:09 Dockerfile 与容器就位**
  - 依赖清单逐条来自 CI 四个 job 的 apt 行，不是现编的；基础镜像钉 digest
    （`debian:bookworm@sha256:813017…`）不钉 tag，本地已有该层 ⇒ 实测
    `docker build` **没有走网络**（这是用户明确要求，免得网络故障添乱）。
  - 构建 92 秒。容器 `odin-dev` 已起：`--privileged` + 三个挂载
    （仓库 → /work/odin-work、`odin-ccache` 卷 → `/var/cache/odin-ccache`、
    `odin-kernelsrc` 卷 → /work/src）。
  - **内核源码树挂容器自己的卷而不是仓库的 bind mount**：几万个小文件的编译
    走 macOS bind mount 会慢一个量级。ccache 同理挂卷，重建容器不丢缓存。
  - 冒烟验证过：工具链 19 个命令全部就位，ccache 两条配置生效，
    `make print-config` 在容器内正常。

- **19:16 Makefile 变体落地** —— `ODIN_VARIANT ?= gui`，模式规则
  `$(STAMPS)/rootfs-%`（`%` = core/gui）用 `$*` 传变体名，两个变体不抄两遍 recipe。
  - 变体相关路径一律递归展开（`=` 不是 `:=`）：`ODIN_VARIANT` 在 recipe 运行时
    才确定，`:=` 会把解析期默认值钉死 ⇒ 两个变体串台。
  - 戳文件、输出目录、`debootstrap` 的 staging 根目录**都按变体分开**。
    staging 共用会表现为"编了 gui，出来的却是 core"（第二个变体直接复用
    第一个已摆好的根，因为 build-rootfs.sh 是按 `[ ! -d "$ROOT/etc" ]` 判断的）。
  - 镜像名：core 沿用 `odin-debian.img`（flash-all.sh 与文档都按这个名字取默认
    路径，改名没收益），gui 用 `odin-debian-gui.img`。

- **踩坑**：`make -n` 里想用 `$(subst $(space),$(comma),$(VARIANTS))` 拼提示文字，
  但 `space`/`comma` 这两个变量在本 Makefile 里并不存在 —— 直接写死 "core 或 gui"
  了事，别为一行提示文字造变量。

- **19:23 待办 / 下一步**
  - 本次触发的 CI（run 33308322764）跑的是旧 job 定义（单 rootfs），
    只用来验证 ccache 修复；**下一次** CI 才会带上 core/gui 两条 matrix job。
  - gui 变体的包清单从未在 CI 上跑过（只在真机手工装过），第一次 CI 大概率会
    在 `apt-get install plasma-mobile` 处暴露问题。
  - 本地完整构建还没跑过（内核 20+ 分钟），等 CI 结果确认缓存生效后再跑。
  - **本地跑 `make dtb` 与 `make kernel` 必须用两棵不同的内核树**
    （`KDIR=/work/src/linux-dtb` 与 `/work/src/linux-kernel`）：dtb 只打 0007、
    kernel 打 0001-0008，共用一棵树时 kernel 会撞上"0007 已应用"，
    `patch --forward` 跳过并返回 1 ⇒ `set -e` 下直接失败。CI 上是两个 runner
    各自 fetch，永远遇不到。

---

## 贰拾陆、GUI 变体实刷真机 + 缓存/RTC/触摸 三条线（2026-08-30 晚）

上文（贰拾伍）搭好容器化环境与变体之后，本地 GUI 全流程跑通并**实刷真机**，
验收 16/16 全过，Plasma Mobile 起来（屏上有鼠标光标）。随后围绕三个问题推进。

### 1. CI 缓存：连修三处，但**仍未证明有效**（用户 22:00 叫停，先放一放）

| 轮次 | kernel 耗时 | 命中率 | 说明 |
|---|---|---|---|
| 第 1 轮 | 31.5 分钟 | 0.75% | 改了 ccache 规则，旧缓存整体作废，冷编 |
| 第 2 轮 | ~30 分钟 | 0.75% | 恢复的还是那份 235 MB，**纹丝不动** |
| 第 3 轮 | 31m53s | — | v2 新 key，冷编并**存下**缓存 |
| 第 4 轮 | 31m25s | — | 与第 3 轮**并行**跑了，拿不到第 3 轮的缓存 |
| 第 5 轮 | （取消） | — | RTC 配置改动后触发，仍恢复旧缓存 |

三处修复：
1. `compiler_check=content` + `hash_dir=false`（贰拾伍已做）。
2. **缓存键补编译器身份**（版本 + 二进制 md5）—— 关键教训：actions/cache
   **精确命中时跳过上传**，于是 key 不变 ⇒ 缓存永远冻结在第一份快照上。
3. **缓存键补内核配置哈希** —— 同一类问题：改 .config 会改 autoconf.h，
   但 key 不含配置 ⇒ 精确命中旧缓存（用不上）且不回传。

未验证的原因：这几轮要么彼此并行、要么夹着配置变更，始终没有出现
"上一轮存好缓存、下一轮独占跑"的干净对照。**下一轮单独触发即可判定。**

### 2. RTC：修完并已编译进内核（待真机复验）

真机时间错的完整链路：
- 内核 **HCTOSYS/SYSTOHC 两个选项 pmOS 默认关着**（正常 Debian 是开的）⇒
  开机不读 RTC（时钟从 1970 起步，被 systemd 顶到它内置的 epoch = 4 月）；
  NTP 校正后也不回写 RTC ⇒ 一重启就回到错误时间。
- 已开 `CONFIG_RTC_HCTOSYS/SYSTOHC=y`（rtc0 = rtc-pm8xxx），
  并确认 `rtc_hctosys_ret` 符号已在 vmlinux 中。
- 另补两处短板：timesyncd 加国内可达的 NTP 候选（原来一直 "Idle."）、
  装 util-linux-extra（原来连 hwclock 都没有）；时区改 Asia/Shanghai。

### 3. 触摸屏：卡在一个**反直觉的发现**上

- 证据链是完整的：原厂 ROM 的 boot.img 里解出 DTB，触摸在
  **i2c@78b7000（主线 &i2c_3）**，地址 0x38，reset gpio64 / irq gpio65；
  MoKee 的 ueventd.rc 也指向 78b7000，候选地址 0x20 / 0x38 / 0x4b。
- 但**只要启用 &i2c_3，真机就无限重启**（lk2nd 起不来 Linux ⇒ 反复重启）。
  不是触摸节点的问题：单独只开 i2c_3、不带任何设备节点，一样循环。
- DTB 本身是干净的：反编译后与基线的差异**只有一行** `status: disabled → okay`
  （44125 → 44121 字节，字符串表少 4 字节，属正常）。
- 怀疑方向：msm8953 上部分 BLSP QUP 受 TrustZone 保护，主线驱动去访问会触发
  复位 —— 仓库里 daisy/vince 的 DTS 就有"因为 BLSP 被 TZ 保护而改用 GPIO 模拟"的注释。
  **需要用 ramoops（/sys/fs/pstore）里的崩溃日志坐实**，尚未取到。

### 过程中的几个坑（值钱的部分）

- **内核树里的改动不持久**：在 `tmp/linux-dtb`、`tmp/linux-kernel` 里改完 DTS，
  过一会儿会被还原/被打补丁覆盖。补丁必须改 `patches/`，改完要
  `git apply --check` 并在干净树上验证产物。
- **重新生成的补丁不可信**：用 `git diff` 重新生成的 0007 会让 DTB 悄悄变样
  （比原版小 4 字节）。后来改成在**原始补丁文本**上精确插入 + 逐字节验证。
- **相对路径会写进 worktree**：编辑工具把相对路径解析到
  `.codebuddy/worktrees/bg-d58d0c38/`，与主仓库不是同一份文件，踩了两次。
  改文件一律用绝对路径。
- **续行里不能插 `#` 注释**：反斜杠续行会把各行拼成一行，`#` 之后全被吃掉
  （差点漏装 util-linux-extra 与 nftables）。
- **打补丁必须可重跑**：`patch --forward` 遇"已应用过"返回 1，set -e 直接中断
  ⇒ 改配置重编内核根本干不了。已抽成 `tools/ci/apply-patches.sh`，
  三种情形分别判定（含"新建文件被后续补丁改过"这种 0005/0008 的情形）。

### 附带

- 刷机前把当时可用的一套产物存档到 `tmp/release-gui-local-known-good/`
  （含 4.6G 镜像、DTB、lk2nd、校验和），已用于两次回滚。
- 仓库里出现过一份并非我创建的 `dts/msm8953-smartisan-odin-touch.dtsi`
  （含触摸节点，被两个变体 .dts include）。用户说没在并行改，按指示删除，
  内容留档在 `tmp/dts-test/touch.dtsi.存档`。

### 贰拾柒：RTC —— 按 pmOS 的完整流程梳理后改用 fake-hwclock

- **23:18 完成** — 时钟用户态一环改用 Debian 自带的 fake-hwclock（commit `21322f0`），
  报告见 `reports/023-RTC-postmarketOS的完整流程与本机改造.md`
- 要点
  - 干净克隆了三个 pmOS 仓库做对照（`tmp/pmos-refs/`）：pmaports、
    linux-postmarketos-qcom-msm8953、swclock-offset。
  - 关键证据：`device/community/soc-qcom-msm8953/APKBUILD` 里
    `depends="$pkgname-ucm swclock-offset"` —— 方案挂在 SoC 包上，
    markw 等全系 msm8953 机型都会装；全仓共 14 处依赖。
  - pmOS 的流程是四层：内核不读不写（HCTOSYS/SYSTOHC 都关）→ 设备树不加
    allow-set-time → 用户态 swclock-offset 关机存「系统时间 − RTC」的偏差、
    开机 RTC + 偏差还原 → 联网靠 NTP。
  - 本机实测与之吻合：不加 allow-set-time 写 RTC 是 -ENODEV；
    加了则 `hwclock --systohc` 把整机挂死（进程不可中断）。
  - 没照搬它的自制脚本，改用 Debian 的 fake-hwclock：存绝对时间，
    `/etc/fake-hwclock.data`，sysinit 早期 load、关机 save。
  - 补了 pmOS 参考实现缺的一块：fake-hwclock 的每小时存盘靠
    `/etc/cron.hourly/fake-hwclock`，要 cron 才跑，所以一并装 cron ——
    手机很少干净关机，只靠关机存盘一硬复位就全丢。
- **踩坑**：fake-hwclock 的数据文件是 **`/etc/fake-hwclock.data`**，
  不是 `/var/lib/…`（`/sbin/fake-hwclock` 第 14 行 `FILE=` 写死的默认值）。
  之前注释里写错了路径，已更正。
- **踩坑**：bookworm 的 util-linux-extra **没有** hwclock-save.service
  （只有 `/etc/init.d/hwclock.sh` 与 udev 的 hwclock-set，两者开头都是
  `[ -e /run/systemd/system ] && exit 0`）。之前那句 `systemctl mask`
  是照 pmOS 的思路想当然加的，撤掉。
- **踩坑**：本仓库有**另一个会话在并行改同一批文件**。我 23:14 改
  `setup-rootfs.sh` 时它 23:06 刚改过；并发写入把我写入的一行弄坏了
  （混进 `2m` 前缀），已修复。改文件前先看 mtime，改完立刻 commit + push。
- **踩坑**：OrbStack 的 Docker 守护进程会无响应（负载高时更明显），
  `docker` 命令全部挂住；`orbctl stop && orbctl start` 可恢复，
  但会杀掉容器里正在跑的构建。
- **踩坑**：写文件用相对路径会被解析到 `.codebuddy/worktrees/bg-d58d0c38/`
  而不是主仓库（WORKLOG 早先记过，又踩了一次）；报告最后是 `cp` 过去的。

---

## 2026-08-30 23:50 · RTC：照 postmarketOS 的完整流程改造（报告 023）

### 起因

真机时间一直是错的：显示 2026-04-27（systemd 的打包日期，无 RTC 时 systemd
兜底用的就是这个），联网校正后一重启又回去。用户要求：先用**干净克隆**的
postmarketOS 源码做对照分析，把它的完整流程搞清楚，再照着改我们这一套。

### 干净克隆的参考仓库（都在 tmp/pmos-refs/）

| 仓库 | 说明 |
|---|---|
| pmaports（161M，全量） | device-xiaomi-markw、soc-qcom-msm8953、官方内核配置 |
| swclock-offset（全量，24 个提交） | 官方"存文件"方案的实现，不在 pmaports 里，是独立仓库 |
| msm8953-mainline/linux（全量） | **pmOS 的 linux-postmarketos-qcom-msm8953 实际就是从这个仓库构建的**（APKBUILD 里 `url="https://github.com/msm8953-mainline/linux"`）。gitlab.com 上并没有这个仓库，一开始按 gitlab 地址克隆必然 401。 |

### pmOS 的完整流程（四层）

1. **SoC 包把方案钉死**：`device/community/soc-qcom-msm8953/APKBUILD` 写着
   `depends="$pkgname-ucm swclock-offset"` —— markw 等整系 msm8953 机型都会装上。
   全仓共 14 个设备/SoC 包依赖它。
2. **内核不读不写 RTC**：官方配置里 `RTC_HCTOSYS` / `RTC_SYSTOHC` 都关着，
   `RTC_DRV_PM8XXX=m`。与我们基线的 RTC 部分逐项一致。
3. **设备树不加 allow-set-time**：主线所有 msm8953 机型都没有（只有 pmp8074 用过）。
4. **用户态 swclock-offset**：关机把「系统时间 − RTC」存进
   `/var/cache/swclock-offset/offset-storage`，开机 `RTC + 偏差` 还原；
   服务位置是 fsck 之前 load、关机时 save。包描述原文：
   *"Keep system time at an offset to a non-writable RTC"*。

### 本机实测：RTC 只能读，不能写

- 不加 `allow-set-time`：`rtc-pm8xxx` 的 `set_time` 走 `pm8xxx_rtc_update_offset()`，
  它要设备树里名为 `offset` 的 nvmem cell，本机没有 ⇒ `return -ENODEV` ⇒
  `hwclock --systohc` 报 `ioctl(RTC_SET_TIME) ... No such device`。
- 加 `allow-set-time` 让它真写寄存器：`hwclock --systohc` 把整机**挂死**
  （进程卡在不可中断状态，设备端的 `timeout` 都杀不掉）。
- 之前开 `CONFIG_RTC_HCTOSYS/SYSTOHC=y` 的那版，真机出现 5–12 分钟一次的
  周期性硬复位 —— 已撤销，本次需复验确认消失。

### 改造：照流程走，但用户态用 Debian 自带的

既然两边都是"写文件、读文件"，就不自己移植 swclock-offset，改用 bookworm 的
`fake-hwclock`（0.12+nmu1，已解包逐字核对）。额外补的两处：

1. **数据文件路径写错**：是 `/etc/fake-hwclock.data`，不是注释里原先写的
   `/var/lib/…`（`/sbin/fake-hwclock` 里 `FILE=` 写死）。
2. **装上 cron**：fake-hwclock 自带的 `/etc/cron.hourly/fake-hwclock` 要 cron
   才跑得起来，而 minbase 不带 cron。手机很少干净关机，只有关机存盘的话
   一掉电或长按电源硬复位就全丢 —— 这正好补上 pmOS 参考实现的短板
   （它只在关机时存一次）。

顺带撤掉一处想当然的屏蔽：`systemctl mask hwclock-save.service` ——
bookworm 的 `util-linux-extra` 根本没有这个 unit，它只带
`/etc/init.d/hwclock.sh` 与 udev 的 `hwclock-set`，两者开头都是
`[ -e /run/systemd/system ] && exit 0`，systemd 下压根不会去写 RTC。

### 过程中的坑

- **两个会话在改同一个仓库**：对方提交了 `0d8841c`/`eb54960`/`328e50d`，
  报告 023 也是同一时段出现的同名文件。我改 `setup-rootfs.sh` 时撞上并发写入，
  被混入一行 `2m` 前缀的坏行（已修，`bash -n` 通过）。**同时刷机是真实风险**，
  已语音提醒用户关掉一个会话。
- **编辑工具把相对路径解析到 `.codebuddy/worktrees/bg-d58d0c38/`**：
  报告 023 第一次就写进了 worktree，得再复制回主仓库（这个坑贰拾陆里记过）。
- **OrbStack 会被高负载拖垮**：JOBS 用满时 docker 守护进程反复挂掉，
  内核编到一半就断。改用 `JOBS=4` 后稳定。
- **容器里 `git fetch` 会卡死**：取内核那步 20 分钟零增长；
  在 Mac 侧绕代理直接克隆则正常（3.4MB/s）。构建改指向已有的
  `tmp/linux-kernel-pmos`（已在新基线 `770e10fa1` 上）来避开这一步。
- **工作区里有一份未提交的 `allow-set-time` 实验补丁**（对方会话加的），
  与"写 RTC 会挂死"的结论冲突。为保证产物可预期，改用 `git archive HEAD`
  导出的干净副本构建（`tmp/build-head`）。

### 状态

- 分析与代码改动已完成并推送（`21322f0`、`acaebd9`）。
- 完整刷机包正在从 HEAD 干净副本构建（内核 → DTB → rootfs → 汇总）。
- 待真机复验：联网后时间正确；重启后时间停在上次存盘点附近而非 2026-04-27；
  `/etc/fake-hwclock.data` 在更新；连续静置 ≥15 分钟无周期性重启。

### 4. RTC：查到底了，结论是**本机用不了 RTC**（不是没修对）

- 现象：手动把系统时间设对之后，`hwclock --systohc` 依然失败
  `ioctl(RTC_SET_TIME) to /dev/rtc0 ... failed: No such device`。
- 真因（drivers/rtc/rtc-pm8xxx.c）：set_time 有两条路径 ——
  真写寄存器（需要设备树 `allow-set-time`），或把"偏差"存进名为 offset 的
  nvmem cell。后者第一句就是 `if (!nvmem_cell && !use_uefi) return -ENODEV;`。
  **本机 /sys/bus/nvmem/devices/ 是空的**，没有任何 nvmem 设备。
- 参照 pmOS 官方（完整克隆 gitlab.com/postmarketOS/pmaports，见
  tmp/pmos-pmaports）：markw 用的是共享内核包 linux-postmarketos-qcom-msm8953，
  其配置里 `RTC_HCTOSYS` / `RTC_SYSTOHC` **两个都是关的**，
  `CONFIG_RTC_DRV_PM8XXX=m`。即 pmOS 给 msm8953 **也不用 RTC 对时**，靠 NTP。
  另外主线里没有任何 msm8953 机型用 allow-set-time。
- 实测：加上 allowing RTC（allow-set-time + 两个内核开关）之后，
  设备开机约 2 分钟、5 分钟各重启一次（期间没执行任何写 RTC 的命令，
  pstore 为空＝硬复位、无 panic/OOM）；**撤掉之后连续运行 39 分钟以上不重启**。
  用户的一句判断很关键：掉电不可能"立刻重启"，而它是立刻重启 ⇒ 不是掉电。
- 于是撤掉这两处（提交 f137e04），内核配置回到与 pmOS 逐项一致。
  保留的用户态改动：timesyncd 国内可达 NTP 候选、时区 Asia/Shanghai、
  util-linux-extra（hwclock）。
- 遗留：NTP 能否真的校时还需设备联网后复验。

### 5. 另外两件值得记的

- **换用 pmOS 那棵内核树（tmp/linux-kernel-pmos，commit 770e10fa1）的构建失败**：
  编到 drivers/usb/gadget/udc 与 wireguard 时中断（Error 123/1）。
  但同一时段 **OrbStack/Docker 崩了两次**（把编译进程直接杀掉），
  所以更像是环境中断而非代码问题，需要重跑才能定论。
- **OrbStack 在本机不稳定**：这轮崩了两次，docker 守护进程消失，
  需要用 `open -a OrbStack` 拉回；之后 `docker start odin-dev`。
  长时间构建期间要留意这一点。

### 补充（同一篇，重编之后又发现两条）

**坑 4：rootfs 的 staging 目录跨构建复用且从不重置。**
`tools/ci/build-rootfs.sh` 里 `ROOT=${ROOT:-/tmp/odin-rootfs-$VARIANT}`，
靠 `if [ ! -d "$ROOT/etc" ]` 决定是否重跑 debootstrap —— 也就是说
**这个根只会 debootstrap 一次，之后一直复用**。后果：撤掉某个安装步骤之后，
它当初留下的文件与 `systemctl enable` 的符号链接**仍然留在下一次的镜像里**。
这次就撞上了：撤掉 odin-swclock-offset 之后，镜像里
`sysinit.target.wants/odin-swclock-offset-boot.service` 与
`timers.target.wants/odin-swclock-offset-save.timer` 都还在，
于是 fake-hwclock 与 swclock-offset **两套同时开机设时间**，谁后跑谁说了算。
判定方法：挂载镜像看 `.wants/` 下的符号链接，而不是只看包有没有装。
修法：`rm -rf /tmp/odin-rootfs-gui` 后重编（deb bootstrap 约 15 分钟）。
注意 dist/build/rootfs/ 下的同名文件会被 overlay 拷进镜像，但只要没被 enable
就是惰性的 —— 所以"文件还在"不等于"会生效"，要看 .wants。

**坑 5：换内核基线会把设备树一起带坏，而且失败信息不在内核侧。**
切到 pmOS 的 6.19.5/main 之后，DTB 编不过：
`msm8953-smartisan-odin.dts:393 Label or path usb3_dwc3 not found`。
原因：旧树（6.19 tag）的 `msm8953.dtsi:1479` 有 `usb3_dwc3: usb@7000000`，
新树把这个 label 去掉了（USB 节点还在，只是没有这个 label）。
⇒ 只比对内核配置是不够的，**设备树的 label 也是基线的一部分**。
另外 `make dtb` 用的是裸 `patch --forward`（不是 apply-patches.sh），
遇到"已打过"会返回非零并在 set -e 下中断；重编前要先
`git checkout -- arch/arm64/boot/dts/qcom/Makefile` 并删掉生成的 .dts。

---

## 电池与温度适配（2026-09-01 凌晨）— 参数已落地、CI 全绿、刷入后失联

### 做了什么

1. **设备树**（`patches/0007`）补三个节点，四个 DTB 全部获得电量能力：
   `/ { battery: battery { compatible = "simple-battery"; ... }; }`
   + `&pmi8950_fg`（monitored-battery / power-supplies / status=okay）
   + `&pmi8950_smbcharger`（monitored-battery / status=okay）。
   数值来自原厂安卓包的下游 DTB（reports/025）：3500 mAh / 3.4 V / 4.4 V / 100 mA。
   `constant-charge-current-max-microamp` 取 1500000，**不抄**原厂 3500 mA
   （那是 PMI8950 SMBC + SMB1351 并联的能力，主线没有 smb1351 驱动）。
2. **内核配置**：`CONFIG_BATTERY_PMI8994_FG=y`、`CONFIG_HWMON=y`、
   `CONFIG_THERMAL_HWMON=y`。
3. **用户态**：`setup-rootfs.sh` 补装 `upower` + `policykit-1`
   （内核有 psy、没有 upower 就一个都看不到）。
4. **顺带修两个换基线的后遗症**（都是编译 blocker，见下）。

### 顺带修掉的两处（都不是这次电池改动引起的）

**A. 换基线带坏设备树（WORKLOG 坑 5 的正式解法）**
新基线 `msm8953.dtsi` 把 dwc3 合并进了 `usb3` 单节点
（`compatible = "qcom,msm8953-dwc3","qcom,snps-dwc3"`），`usb3_dwc3` 不再存在，
而 `usb_dwc3_hs` 这个端点标签**由 dtsi 内建提供**。
改法照上游写法（同 `qrb2210-rb1.dts`）：`&usb3` 上加 `dr_mode = "otg"`，
端点改用 `&usb_dwc3_hs { remote-endpoint = <&usb_con_hs>; }`。
`dts/msm8953-smartisan-odin-norolesw.dts` 的 `&usb3_dwc3` 一并改指 `&usb3`。

**B. `KERNEL_SHA` 散在五处、只同步了一处（CI 自换基线起一直是红的）**
`eb54960` 把 Makefile 的 SHA 改成 `770e10fa`（分支 `6.19.5/main`），
但 workflow 的 `env.KERNEL_SHA`、`fetch-kernel.sh` 默认值、
AGENTS.md / docs/01 / docs/05 都还写着旧值 `05f7e89`。
make 的 `?=` 不会覆盖环境变量 ⇒ workflow 的旧值静默生效 ⇒ CI 取的是另一棵树
⇒ 补丁 0004（R69006 面板）在旧树上打不上，kernel job 卡在"应用补丁"。
五处已全部对齐，并在 workflow 注释、fetch-kernel.sh、docs/05 第六节各写了
"这四处必须一起改"。

### 坑（这次踩的，都实测过）

- **dtc 1.6.1 不接受"根节点闭合之后的顶层节点"**：
  `battery: battery { ... };` 直接 `syntax error`。必须包进 `/ { ... };` 根覆盖块。
  最小复现验证过：包进根覆盖块正常合并。
- **`make dtb` 用的 GNU patch 会 fuzz，CI 用的 git apply 不会** —— 这是"本地绿、CI 红"的根源。
  0007 的 `dts/qcom/Makefile` hunk 上下文缺了新基线多出来的
  `markw / oxygen / ysl` 三条，GNU patch 靠 fuzz 2 蒙过去（还打印
  "Hunk #1 succeeded at 94 with fuzz 2"），git apply 直接失败。
  ⇒ 以后别把那句 fuzz 提示当噪音。
- **换基线后验证补丁的快办法**（比等 30 分钟 CI 快得多）：
  从 HEAD 把 8 个补丁涉及的原始文件抽到临时目录、`git init` 成临时仓库，
  再按 0001→0008 顺序逐个 `git apply --check` 并落盘。本次用它一次找出了 0007。
- **手工改 patch 必须同步 hunk 行计数**：0007 的 dts 部分 449 → 489 → 501 → 494，
  每次增删都要重数。
- 重编前要恢复内核树的 Makefile 与已生成的 .dts（`git checkout --` + 改名备份）。

### CI 结果（run 33411566563，commit 3b509cb）

dtb ✅ / kernel ✅ / lk2nd ✅ / rootfs-core ✅ / rootfs-gui ✅ / publish skipped（预期）

产物核验（下载后本地验的）：
- DTB：`battery` 节点 3500000 µAh / 3400000 µV / 4400000 µV / 1500000 µA / 100000 µA；
  `fuel-gauge@4000` = `qcom,pmi8996-fg`，status=okay，monitored-battery=0x65，
  power-supplies=0x66；`smbchager@1000` = `qcom,pmi8996-smbchg`，status=okay；
  10 个 thermal zone。
- vmlinuz 里有 `pmi8994_fg`(3 处)、`qcom-battery`、`qcom-smbchg-usb` 字符串 ⇒ 驱动已编进内核。
- 下载走 `env -u http_proxy -u https_proxy ...`，kernel+dtb 16 秒，gui 镜像 19 分钟。

### 刷入结果：镜像刷成功，但设备失联（**当前停在这里**）

- `40 data`：`fastboot flash userdata odin-debian-gui-sparse.img` 成功，
  10 个分块共 290 秒，全 OKAY。
- `50 reboot`：`Rebooting OKAY`。
- 之后 240 秒内 USB 网卡没出现；`60 usbnet` 想静态兜底配 `en0`，
  但 `sudo` 要终端密码（用户不在）⇒ 失败。
- 反复查（重启后 15 分钟内查了 4 轮）：
  `fastboot devices` 空、`ping 172.16.42.1` 全丢、
  `ioreg -p IOUSB` 里只有 "Xiaomi Type-C 5-in-1 Hub" / "Generic CDC" / RTL9210，
  **没有任何 Qualcomm VID（05c6 / 18d1）的设备**。
  镜像里也没预置 WiFi（无 *.nmconnection），所以 WiFi 这条路也不通。

#### 已排除 / 待查

- **已排除"Type-C 角色切换"这一路**：镜像的 `extlinux.conf` 里 `default l0-safe`，
  用的就是安全版 DTB（`dr_mode = "peripheral"`、`/delete-property/ usb-role-switch`、
  `/delete-node/ ports`），UDC 本应恒在、不依赖角色判定。
- 因此更可能是：设备根本没起到能起 gadget 的阶段（内核 panic / 根分区没挂上 /
  某个驱动 probe 卡住），或者 reboot 后掉电关机。
- 没有串口控制台，**无法在无物理操作的情况下进一步区分**。
  按约定（"手机状态无法操作就暂停"）停在这里。

#### 下一步（需要用户动手）

1. 长按电源关机 → 按住【音量减 + 电源】进原厂 fastboot，
   让 PC 上重新出现 `fastboot devices`。
2. 恢复手段（有备件）：
   `fastboot flash boot evidence/live-device-backup/boot-partition.img`
3. 起得来之后再定位：优先看串口/屏幕上的启动日志，
   确认是内核 panic、根分区挂载失败，还是某个驱动 probe 卡住。

### 遗留（本次故意没做）

- `CONFIG_BATTERY_QCOM_FG=y` 是本树 Kconfig 里**不存在**的失效残留
  （旧驱动名 qcom_fg.c，现为 pmi8994_fg.c），olddefconfig 静默丢弃它。
  按"只增不删"暂留，未删。
- 本次全程**没有执行任何删除/清理命令**（按用户要求），
  临时目录 `tmp/battery-probe`、`tmp/patchcheck`、`tmp/pristine-check`、
  `tmp/pristine-check2`、`tmp/ci-artifacts` 与两个 `.odin-bak` 备份都还在，
  等全部完成后再统一整理。

---

## 触摸屏：已可用（2026-09-01 晚）

### 结论

触摸芯片是 **FocalTech FT8716**，与显示集成在同一颗 TDDI 上。用主线的
`edt-ft5x06` 驱动即可，**不改内核配置、不要固件**。

### 硬件参数是从原厂 DTB 里读出来的，不是猜的

`evidence/stock-rom-battery/odin-stock.dts:6367` 的 `focaltech@38`：
i2c@78b7000（主线 `&i2c_3`，BLSP1 QUP3）地址 0x38，reset gpio64 /
irq gpio65，`vcc_i2c-supply` 由 pm8953_l6(1.8V) 供；pinctrl 的驱动强度与
上下拉逐项对齐原厂 :1808-1895（也与主线 `msm8953-xiaomi-common.dtsi:382-431`
一致）。同总线还有个 `novatek@01`，那是 NT36672 面板变体的备选，本机不用。

`edt-ft5x06.c:1530` 有 `focaltech,ft8716`；`CONFIG_TOUCHSCREEN_EDT_FT5X06`
本来就是 `=m`。改动只有 `patches/0007`：`&tlmm` 加 4 个 pin 状态 + 新增
`&i2c_3` 节点。

真机：`/dev/input/event3` 注册为 `generic ft5x06 (8d)`，划屏读到
`ABS_MT_POSITION_X=589 / Y=1504 / BTN_TOUCH=1`，坐标在 1080x1920 内。

### 两个非直觉的点（都踩到了）

**1. "触摸 probe failed" 可能是显示那边的锅。**
FT8716 是 TDDI，要面板先上电才响应。第一次试的时候 probe 失败，翻 dmesg
才看到背光那边 `qcom,wled ... invalid value for 'qcom,ovp-millivolt'` 又回来了
—— 因为我做试验 DTB 时拿的底片是**第一轮**（OVP 修复之前）的产物，
于是背光挂 ⇒ DSI 一直等它 ⇒ 触摸跟着超时。
换成修复后的底片重做，触摸 5.2 秒就 probe 成功（失败那次 31.9 秒还在重试）。

> 教训：`tmp/ci-artifacts/` 下会同时存在多个轮次的产物，**用之前先核验关键值**，
> 别默认它是最新的。这个坑让我多烧了一轮重启，还误报了一次"黑屏"。

**2. `&i2c_3` 不再导致无限重启（旧记录已订正）。**
`WORKLOG.md:1353` 记着"只要启用 &i2c_3 真机就无限重启"，怀疑 BLSP 受
TrustZone 保护。但 msm8953.dtsi 里那三条 TZ 注释说的是 `&i2c_4`
（78b8000，传感器），不是 i2c_3 —— 当时是读串了总线。
本次实测：新基线上启用 `&i2c_3` 一切正常，没有重启（真因未追溯）。

顺带两条操作经验：
- **`fastboot reboot` 仍然起不来**，但系统内 `sudo reboot` 是通的
  —— 以后重启走系统内，别指望 fastboot 那条。
- **`sudo reboot` 是异步的**：命令返回后系统还活着十几秒，
  `ping` 通不代表已经重启过，要等 sshd 重新可用才算数。

### 远程进 fastboot 那条路走不通（与脚本预期不符）

`flash-all.sh` 20 阶段写的是"改名 extlinux.conf ⇒ lk2nd 找不到配置会停在
fastboot"。实测是**反复重启**，不是停下 —— 最后是人工按住
【音量减 + 电源】才停住的。这条脚本注释与文档都需要订正。

### 仍可复用的一个技巧

要在真机上快速试 DTB 改动，**不用等 40 分钟 CI**：
把 CI 编好的 DTB 反编译 → 改 → 重编译 → scp 到 `/boot/dtbs/qcom/` →
改 extlinux.conf 的 fdt 指向它 → 系统内 reboot。
（AGENTS.md 铁律 4：这只能用于探路，不能据此确认"已修好"。）

---

## rootfs 太慢：定位到解包那 9 分钟（2026-09-01 晚）

### 数据（v0.9.4-battery 那轮 CI 的 gui rootfs 日志，job 99846158676）

整段 23.6 分：

| 阶段 | 耗时 | 占比 |
|---|---|---|
| debootstrap | 106.6s (1.8 分) | 7.5% |
| udev + 基础包（setup-rootfs 前段） | 174.7s (2.9 分) | 12.3% |
| **Plasma 装包（setup-rootfs 后段）** | **850.3s (14.2 分)** | **60%** |
| build-image（mke2fs 25s + img2simg 13s + 校验 3s） | 40.7s | 2.9% |
| 其余（checkout / 装工具 / 下上轮 artifact / 上传） | 约 250s | 17.6% |

Plasma 那 850 秒内部（按分钟桶统计 dpkg 输出）：

```
11:59        约  60s   静默（fix_dns + apt-get update + 下载）
12:00–12:08  约 540s   解包 1202 个包，同期配置只有 3 个   ← 大头
12:09–12:12  约 240s   配置 1211 个包（postinst 在 qemu-arm64 下跑）
```

另外 `Processing triggers` 共 23 次，其中 sgml-base、libc-bin(ldconfig)、dbus
各 3 次 —— 三批装包各触发一轮。

### 结论：不是带宽问题，是 dpkg 逐包 flush

**解包 1202 个包花了 9 分钟、每包约 0.45 秒**，而写入量只有几百 MB。这个数字
只能由"每处理一个包就 flush 一次文件系统"解释（dpkg 的 safe I/O）。

### 改法：给三处 apt-get install 加 force-unsafe-io

统一走 `APT_OPTS="-o Dpkg::Options::=--force-unsafe-io"`。

**用命令行选项，不写 `$R/etc/dpkg/dpkg.cfg.d/`**：写文件会留在镜像里，连带影响
真机上以后 apt 升级的行为；命令行选项只在本次装包生效，镜像里不留痕迹。
掉电一致性对这一步没意义 —— 刷进真机的是 build-image.sh 后面 mke2fs 出来的
新镜像，不是这个临时 staging 目录。

### 留到下一轮的（都算过账，不是忘了）

- **合并三批装包**：能省两轮 dpkg trigger（上面那 3× 的 ldconfig/dbus/sgml-base）
  和一到两次 apt-get update。但 udev 那批必须先于后面几个 `systemctl enable`
  （serial-getty / odin-usb-gadget / odin-firstboot-resize），基础包那批又必须先于
  `systemctl enable NetworkManager/cron/fake-hwclock`，合并会打乱这些先后关系，
  风险不小。真要合，先确认 `systemctl enable` 是否真的需要对应包已安装（很可能
  不需要，它只是在建符号链接）。
- **三处 apt-get update**：sources.list 在它们之间没变过，理论上两处冗余；但 298
  行那次是防御性的（前一批 systemd-resolved 的 postinst 会把 resolv.conf 换成
  悬空链接，可能导致更早那次 update 拿到空索引）。单个收益不到 1 分钟。
- **缓存 apt 归档**：只省那 60 秒下载，性价比低。
- **缓存整个 gui staging**：5.7 GB，虽然有 10 GB 上限，但上传下载都很不划算。

### 一条方法论

这次能定位准，靠的是**先按分钟统计日志行分布**再下结论：
一眼看出 12:00–12:08 只有 Unpacking、Setting up 几乎为零，于是矛头直接指向
解包而不是"包太多"或"网络慢"。以后排查构建耗时都该先画这个分布。

---

## 麦克风/扬声器、蓝牙、GPS、视频编解码：一轮摸底（2026-09-01 深夜）

方法照旧：**先在真机上实测现状**，再对原厂 DTB 与 pmOS/主线源码，不靠猜。

### 1. 蓝牙 —— 已可用（本轮搞定）

内核侧本来就是好的，缺的只有用户态：

- 主线 `btqcomsmd` 走 SMD 通道（`APPS_RIVA_BT_ACL` / `APPS_RIVA_BT_CMD`），
  固件与 WiFi 共用 `wcnss.*`（odin-wlan-fw.sh 已取）
- DTB 里 `wcnss_bt`（`qcom,wcnss-bt`）由 msm8953.dtsi 提供、默认启用
- 真机：`hci0` 直接存在，控制器 `02:00:67:DB:FE:B8 (public)`、Powered: yes
  —— **是 public 地址，不用手动 `btmgmt public-addr`**
- 装上 bluez 后 20 秒扫描扫到 10 台周边设备（LYWSD03MMC 温湿度计、
  一台 Apple 设备 RSSI -68）

改的只有包清单：`bluez`（两变体）+ gui 的 `bluez-obexd`、`libspa-0.2-bluetooth`、
`pipewire-alsa`。**没动 DTB、没加固件、没加 udev 规则。**

### 2. 音频（内置扬声器 + 麦克风）—— 路径清楚，本轮只摸清没动手

- 现状：`cat /proc/asound/cards` → `--- no soundcards ---`；
  `devices_deferred` 里 `c0f0000.codec msm8916-wcd-digital-codec: failed to get mclk`
- 真因：**`&lpass`（ADSP remoteproc，msm8953.dtsi:3076）没启用** ⇒
  `q6afecc` 时钟控制器没注册 ⇒ codec 拿不到 mclk。
  mclk 是 LPASS 内部产生的 9.6MHz，**不是某个 GPIO** —— 所以不是 pin 配错
- 三个节点在我们 DTB 里全是 disabled：`remoteproc@c200000`(ADSP)、
  `sound-card@c051000`、`remoteproc@4080000`(modem)
- 硬件（原厂 DT）：无独立 wcd9xxx / slimbus（tasha、wcd9xxx-irq、audio_ext_clk
  全 disabled），用 PM8953 下 `8953_wcd_codec@f000`，digital 基址 `0xc0f0000`。
  **本机无耳机孔**，只有 `qcom,msm-ext-pa = "primary"` 一路外部功放
- 固件：`adsp.mdt` + `adsp.b03/b04/b05/b10/b13` 在 **modem:/image/**（不在 dsp 分区！
  dsp 分区里全是 Android 的用户态 DSP 库：DTS_HPX、DolbyMobile、fastrpc_shell…）
- 待定：内置扬声器功放是不是 AW8738。原厂只给 `ext-pa-enable = gpio132`，
  markw 用 `awinic,aw8738` 挂 gpio96 —— 要对一下

修法：启用 `&lpass` → 固件脚本取 adsp.* → 启用 `&sound_card`（model/routing/pinctrl）
→ 用户态 `alsa-ucm-conf` + `alsa-utils`。顺序不能颠倒。

### 3. 视频编解码（venus）—— 看似简单，实际卡在固件握手

- 节点 `venus@1d00000` 默认已启用，`CONFIG_VIDEO_QCOM_VENUS=m` 已开，
  模块 `venus_core` 等已加载 —— **看起来只差固件**
- 实测把 `venus.mdt` + `venus.b00~b04` 从 modem:/image/ 拷进 /lib/firmware 后，
  `venus.mdt failed with error -2` 确实消失了，**但冒出新错误**：
  ```
  qcom-venus 1d00000.venus: Unsupported property: 0
  qcom-venus 1d00000.venus: probe with driver qcom-venus failed with error -5
  ```
- `Unsupported property` 是 `hfi_parser.c:383` 的 `dev_warn_once`（只打一次，
  实际可能有多个属性不认识）；`-5` = `-EIO`，来自 `hfi.c` 的 HFI 命令封装
  ⇒ **是固件握手失败**：这版 venus 固件（2018 年 Android 7.1）的能力表/初始化
  协议与主线 venus 驱动对不上。**不是缺文件的问题**，要单独立项排查，别当"简单活"

### 4. GPS —— 大工程，不在这轮

- 主线没有 QCOM 的 GNSS 驱动（`drivers/gnss/Kconfig` 只有 MTK/SiRF/u-blox），
  本机 `CONFIG_GNSS` 也未开 ⇒ **内核 GNSS 子系统这条路不存在**
- 定位由基带跑，经 **QRTR 上的 QMI LOC 服务**暴露给 AP。
  本机 `&mpss`(modem) 未启用 ⇒ 没有 QRTR/QMI
- 需要：启用 `&mpss`（脚本注释说要 `pll-supply = <&pm8953_l7>`）+ modem 固件
  （mba.mbn、modem.mdt + b05~b20 都在 modem:/image/）+ `rmtfs`/`tqftpserv`
  + ModemManager/libqmi/geoclue。**Debian 有没有现成的 rmtfs/tqftpserv 包未确认**
- `gpsd` 不适用（没有串口 GPS，也没有 /dev/gnss*）
- 注意：pmOS wiki 说 msm8953 GPS=Works，但那次取证里 QRTR 根本没起来，
  不能当作本机已通的证据

### 5. 一条很实用的操作技巧：让设备上网

设备本身只有 USB 那条 172.16.42.0/24，没有外网。用 SSH 远程端口转发把本机的
代理给它即可（本机 10808 上有代理）：

```sh
ssh -f -N -R 10808:127.0.0.1:10808 user@172.16.42.1
apt-get -o Acquire::http::Proxy=http://127.0.0.1:10808 install bluez
```

实测 6.3 MB 走 13 秒。以后要在真机上现场装包排查都靠这个。

踩到的两个坑：
- 无网络时 `apt-get update` **不会超时退出**，会一直挂着占住
  `/var/lib/apt/lists/lock`，之后所有 apt 都报 lock 错误 —— 要 `pkill -9 apt-get`
- sshd 没设 MaxStartups（默认 10:30:60），密集轮询时会被概率性丢连接，
  表现为间歇性 `Permission denied (publickey,password)`，**不是密码错**，等一会重试即可
