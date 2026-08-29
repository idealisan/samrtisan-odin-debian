# 015 — USB 角色自动切换与 OTG 文件系统能力补全实施计划

日期：2026-08-29　状态：**计划稿，尚未实施**（本文件只做规划，未改动任何产物）

前置报告：`reports/013`（镜像重建与产物实测）、`reports/014`（角色切换问题定稿与本计划的前身）

---

## 零、本计划的证据基础

本计划所有前提均由本次实测得出，不沿用历史文档的结论。关键实测点：

| # | 结论 | 证据 |
|---|---|---|
| 1 | 开机默认就是 device 模式，UDC 不依赖 CC 判定 | `drivers/usb/dwc3/drd.c:505-512`：DTS 有 `usb-role-switch` 且无 `role-switch-default-mode` → 落到 `USB_DR_MODE_PERIPHERAL` → `dwc3_set_mode(DWC3_GCTL_PRTCAP_DEVICE)` |
| 2 | legacy glue 的 VBUS override 只在 probe 设一次 | `dwc3-qcom-legacy.c:806-810`（dr_mode=otg≠HOST 时 enable）+ `:164`（无 extcon 直接 return 0，notifier 不注册）。本 DTB 全文无 extcon |
| 3 | FUSB301 有 IRQ，插拔会驱动角色切换 | `drivers/usb/typec/fusb301.c:372` threaded_irq → `fusb301_irq_thread` → `fusb301_attach/detach` → `fusb301_set_role():143-165` → `usb_role_switch_set_role()` |
| 4 | FUSB301 角色判定方向与原厂一致，未反转 | 原厂 `refs/fusb301-5.10.c:1191-1194`（注释 "The partner is a source/sink"）→ `:941 set_role(DEVICE)` / `:981 set_role(HOST)`；移植版 `type & FUSB301_TYPE_SNK` → HOST 分支同为 USB_ROLE_HOST |
| 5 | UDC 重绑必须"先空后名" | `drivers/usb/gadget/configfs.c:295`：configfs 保留 `udc_name`，UDC 回来后直接写名字返回 `-EBUSY`；`:289-291` 写空串才走 unregister |
| 6 | dwc3 的 role switch 允许用户态覆盖 | `drd.c:518` `allow_userspace_control = true` → `/sys/class/usb_role/<sw>/role` 可写 |
| 7 | OTG 数据通路与供电全内建 | `modules.builtin`：`usb-storage.ko` `uas.ko` `sd_mod.ko` `scsi_mod.ko`；DTS `otg-vbus` = `qcom,pmi8950-smbchg-otg` 5V，驱动 `CONFIG_REGULATOR_QCOM_SMBCHG_OTG=y` |
| 8 | 缺 UTF-8 编码器 | `CONFIG_NLS_UTF8 is not set`，`CONFIG_NLS_DEFAULT="iso8859-1"`，`CONFIG_FAT_DEFAULT_UTF8 is not set`；镜像 nls 目录只有 `nls_ucs2_utils.ko` |
| 9 | 用户态工具只覆盖 ext2/3/4 | 镜像 `/usr/sbin` 只有 `mkfs.ext2/3/4`、`fsck.ext2/3/4` 及 util-linux 的 `mkfs.bfs/cramfs/minix` |
| 10 | 内核可增量重建 | 源码树 `/Volumes/caseSensitiveBar/linux-msm8953` 有完整 `.config` + `vmlinux` + `Image` + `Module.symvers`（8/21-8/22 构建）；`CONFIG_MODVERSIONS` 未开启 |
| 11 | 装包可行 | 镜像 `/etc/apt/sources.list` = Debian bookworm（含 non-free）；**`polkitd` 已安装**（udisks2 的主要重依赖） |
| 12 | QEMU 无法验证本计划的任何核心项 | `odin-qemu/Image` 是另一个内核（6.19.0 / Debian gcc 12.2 / 8-23），与镜像内核（6.19.0-postmarketos-qcom-msm8953 / Alpine gcc 13.2 / 8-21）不同源，且无 UDC、无 Type-C 控制器 |

**由 #12 推出的硬约束：本计划的主线（角色切换）在真机之前无法被验证。** 因此阶段划分的第一原则是——任何一步都不得让"已登录"这个状态退化成"再也登不进去"。

---

## 一、总体策略与阶段划分

```
阶段 0  钉死登录通道 ──── 必须先于一切（014 的 A3/A4）
   │
   ├──> 阶段 1  文件系统工具 + 自动挂载     纯用户态 · 低风险 · QEMU 可验
   │
   ├──> 阶段 2  nls_utf8                  需重编模块 · 中风险 · QEMU 可验
   │
   └──> 阶段 3  角色自动切换（用户态驱动）  高风险 · 仅真机可验
            │
            └──> 阶段 4  内核层根治（可选） 视阶段 3 的真机结果决定
```

- 阶段 1、2 彼此独立，可与阶段 3 并行推进；但**只有阶段 0 完成后才允许上真机**。
- 阶段 3 强制附带"自愈看门狗"与"一键回退"，见 §4.5、§4.6。

---

## 二、阶段 0：先把登录通道钉死（前置，不可跳过）

这是 `reports/014` §五的 A3/A4，也是本报告所有后续工作的前提——**你不能在无法登录的设备上调试登录通道**。

| 编号 | 动作 | 交付物 |
|---|---|---|
| 0.1 | 以现有内核 DTS 为底，复制出 `msm8953-smartisan-odin-norolesw.dts`：删除 `usb-role-switch` 属性、`dr_mode` 由 `"otg"` 改为 `"peripheral"`、删除 `ports/port@0` 端点与 fusb301 的 `connector/ports` | `patches/` 下新增或直接在 build 脚本里生成 |
| 0.2 | 编译为 `msm8953-smartisan-odin-norolesw.dtb`，放进镜像 `/boot/dtbs/qcom/` | 镜像内多一个 dtb |
| 0.3 | `extlinux.conf` 增加第二个 label `l0-safe`，`fdt /boot/dtbs/qcom/msm8953-smartisan-odin-norolesw.dtb`；**首刷把 `default` 设为 `l0-safe`** | `/extlinux/extlinux.conf` |
| 0.4 | 同步更新 `dist/FLASH.md`（首刷默认走安全版、拿到 SSH 后如何切回完整版） | 文档 |

**取舍说明**（已在 014 §五论证，此处重申）：安全版 = USB 网络永远在、彻底放弃 OTG host。它的作用是**把首刷的行为对齐到"不依赖 UDC 是否存在"的确定性状态**，让阶段 3 万一失败时仍有一条能登录的路。

**验证**：阶段 0 本身不需要真机验证（安全版只是删属性，行为只会更简单）。但要在 QEMU 之外做一件事——确认新增的 dtb 能被 `dtc` 编译通过、且 `fdt` 指令能被 lk2nd 解析（`lk2nd/boot/extlinux.c:278-279` 的 `CMD_FDT` 分支）。

---

## 三、阶段 1：文件系统工具与自动挂载（纯用户态）

### 3.1 装包

在容器 staging（`/mnt/stage`）里执行：

```sh
chroot /mnt/stage apt-get update
chroot /mnt/stage apt-get install -y --no-install-recommends \
    dosfstools \      # mkfs.vfat / fsck.fat
    exfatprogs \      # mkfs.exfat / fsck.exfat
    ntfs-3g \         # NTFS 读写（FUSE），作为 ntfs3 的补充与 fsck 来源
    btrfs-progs \
    xfsprogs \
    f2fs-tools
```

依据：#9、#11。这几个包都是纯用户态，不动内核、不动 systemd 单元拓扑，风险最低。

**关于 ntfs-3g**：内核已有内建 `ntfs3`（读写），但 ntfs3 **不提供 fsck**。ntfs-3g 带来 `ntfsfix`，仅此一项就值得装。注意它会同时提供 `mount.ntfs`，可能覆盖 ntfs3 优先挂载——需在验证时确认 `mount -t ntfs3` 仍可用。

**不要装 udisks2**（理由见 §3.3）。

### 3.2 自动挂载：采用 systemd mount unit，而非 udisks2

**推荐方案**：udev 规则打 `systemd` 标签，由 systemd 生成 `.mount` unit。

```sh
# /etc/udev/rules.d/99-odin-automount.rules
# 只处理 USB 总线的分区，避免误挂内部存储
SUBSYSTEM=="block", ACTION=="add", ENV{ID_BUS}=="usb", \
  ENV{ID_FS_USAGE}=="filesystem", ENV{ID_FS_TYPE}!="", ENV{ID_PART_ENTRY_NUMBER}!="", \
  TAG+="systemd", ENV{SYSTEMD_MOUNT_WHERE}="/run/media/%k"

# 卸载交给 systemd（设备消失时自动 stop mount unit），只补一条同步刷盘
SUBSYSTEM=="block", ACTION=="remove", ENV{ID_BUS}=="usb", \
  RUN{program}="/usr/bin/systemctl stop --no-block run-media-%k.mount"
```

**关键实现细节——挂载选项必须按文件系统分流**。这是本方案最容易写错的地方：

| fstype | 能接受的选项 | 不能给的 |
|---|---|---|
| vfat | `uid=` `gid=` `fmask=` `dmask=` `iocharset=utf8` `utf8` | — |
| exfat | `uid=` `gid=` `fmask=` `dmask=`（**不支持 iocharset**） | `iocharset` 会报错 |
| ntfs3 | `uid=` `gid=` `umask=` `iocharset=` | `fmask/dmask` 语义不同 |
| ext4 / f2fs / btrfs / xfs | 靠 POSIX 权限，挂载后 `chown` | `uid=` 会被拒绝 |

因此把选项决策放到一个脚本里，而不是硬塞进 udev 规则：

```sh
# /usr/local/sbin/odin-mount-opts.sh <fstype>   → 打印挂载选项
case "$1" in
  vfat)  echo "noatime,uid=1000,gid=1000,fmask=0133,dmask=0022,iocharset=utf8" ;;
  exfat) echo "noatime,uid=1000,gid=1000,fmask=0133,dmask=0022" ;;
  ntfs3) echo "noatime,uid=1000,gid=1000,umask=0022" ;;
  *)     echo "noatime" ;;   # POSIX 文件系统靠 chown，见下
esac
```

配合一条 systemd 挂载后置钩子处理 ext4 等：

```sh
# /etc/systemd/system/odin-fixperm@.service
[Unit]
Description=Fix permissions on %i
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'chown -R user:user "%i" 2>/dev/null || true'
```

> `uid=1000` 是假设 `user` 的 uid 为 1000 —— 实施时要先 `id -u user` 确认，不要写死。

**为什么不用 udisks2**（#11 显示 polkitd 已在，装它成本不高，但仍不推荐）：
- 引入 D-Bus + polkit 交互层，对无屏单用户设备是纯粹的复杂度
- udisks2 会接管设备事件，与阶段 3 的角色切换脚本争抢同一批 uevent，调试难度陡增
- 不装新包 = 不改变已被 QEMU 验证过的服务拓扑

**备选方案**（若 systemd mount unit 在真机上不生效）：装 udisks2 并放一条 pkla 放行规则 `/var/lib/polkit-1/localauthority/50-local.d/50-odin.pkla`：
```
[Local Users]
Identity=unix-user:user
Action=org.freedesktop.udisks2.*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
```

### 3.3 验证（QEMU 可覆盖）

```sh
# 造一个带 vfat 分区的 U 盘镜像，从 hostfwd 侧插给 QEMU
truncate -s 64M /tmp/otg.img
mkfs.vfat -F 32 /tmp/otg.img
# 挂进 QEMU（usb-storage），在 guest 内：
ls -l /run/media/            # 应出现挂载点
mount | grep sda             # 应带 uid=1000,iocharset=utf8
touch /run/media/sda/中文测试.txt   # 写入与列目录都要正常
```

注意区分：QEMU 能验证的是**用户态挂载链路**（#12），不是 msm8953 的 OTG 通路。

---

## 四、阶段 2：补 UTF-8 编码器（nls_utf8）

### 4.1 为什么必须动内核

#8 已实测：`CONFIG_NLS_UTF8 is not set`。后果是 vfat 默认按 `iso8859-1` 解释文件名，且 `mount -o iocharset=utf8` 会直接失败。这不是配置问题，内核里没有这个编解码器，必须编出来。

### 4.2 做法

```sh
cd /Volumes/caseSensitiveBar/linux-msm8953
# 1) 只加模块，不改成内建 —— 保持 vmlinuz 与 modules.builtin 不变，改动面最小
scripts/config --module CONFIG_NLS_UTF8
# 顺带可加（按需，非必需）
scripts/config --module CONFIG_NLS_CODEPAGE_936   # 若需要 GBK 老盘

# 2) 增量编译模块（不要 make -j$(nproc) all，不需要重编整个内核）
make olddefconfig
make -j$(nproc) modules

# 3) 只取需要的 .ko，不要 make modules_install（会带出全部模块）
cp fs/nls/nls_utf8.ko /mnt/stage/usr/lib/modules/6.19.0-postmarketos-qcom-msm8953/kernel/fs/nls/
chroot /mnt/stage depmod -a 6.19.0-postmarketos-qcom-msm8953
```

### 4.3 工具链一致性的取舍（要决策）

原内核由 Alpine gcc 13.2 编出（镜像内 `Linux version` 串），容器 `odin-build` 是 Debian gcc 12.2。

- 由于 #10 显示 `CONFIG_MODVERSIONS` 未开启，模块加载只比对 vermagic 字符串（`6.19.0-postmarketos-qcom-msm8953 SMP preempt mod_unload aarch64`），**不含编译器版本** → 混编模块理论上可加载。
- 但这是"理论可加载"，不是"已验证可加载"。

**推荐**：优先用仓库里的 `pmbootstrap/` 环境重建，保证同源；若该环境已不可重建，则退而用容器编译，并把"首次 `modprobe nls_utf8` 成功"作为必须实测的验收项（写在 §4.4）。

### 4.4 验收

```sh
modprobe nls_utf8 && lsmod | grep nls_utf8     # 必测：验证 vermagic 兼容
mount -t vfat -o iocharset=utf8 /dev/sda1 /mnt && ls /mnt   # 中文文件名正常
```

同时更新 `dist/FLASH.md` 的已知限制小节，把"vfat 中文乱码"从限制改为"需 `iocharset=utf8`"。

### 4.5 一个更省事的替代路径（供决策）

如果阶段 2 的重编成本被认为过高：**不改内核，改用 exFAT**。实测 `CONFIG_EXFAT_DEFAULT_IOCHARSET="utf8"`，exFAT 驱动内建 UTF-16 处理，不依赖 nls_utf8，中文文件名开箱正常。ntfs3 同理。

代价是"插 FAT32 老盘仍然乱码"。是否接受，由你定。

---

## 五、阶段 3：USB 角色自动切换（核心，高风险）

### 5.1 设计目标

| 场景 | 期望行为 |
|---|---|
| 开机插 PC | device 角色，usb0 + 172.16.42.1 + dnsmasq，SSH 可用 |
| 开机未插任何东西 | 同左（#1 保证默认 device），之后插 PC 也能起来 |
| 运行时拔 PC 插 U 盘 | 切 host，U 盘出 `/dev/sda1` 并自动挂载（阶段 1） |
| 运行时拔 U 盘插回 PC | UDC 回来 → 重新绑定 gadget → 172.16.42.1 恢复 → **SSH 恢复** |
| UDC 始终不出现 | 脚本退出 0，不留 failed 单元，看门狗继续重试 |

### 5.2 内核层已经给了什么（#3、#6）

- 插拔 → FUSB301 IRQ → `usb_role_switch_set_role()` → dwc3 切角色：这条链**已经存在**，不需要改内核。
- `/sys/class/usb_role/<sw>/role` 可写（#6）：这是紧急强制切回 device 的手动后门。
- UDC 增删会发 uevent（`udc/core.c` 的 `device_add` 与 `usb_del_gadget` 里的 `KOBJ_REMOVE`）：udev 有钩子。

### 5.3 需要写的用户态（三个文件）

**(a) `/usr/local/sbin/odin-usb-role.sh`** —— 唯一入口，必须幂等、可重入

```
apply_device():
    1) 等待 UDC 出现，轮询至多 60s（每秒一次）
    2) 若 configfs gadget 目录已建且已绑定 → 直接返回 0（幂等）
    3) 建 gadget（idVendor/idProduct/ncm.usb0/configs.c.1）
    4) 【关键】先 echo "" > $CFG/UDC 解绑，再 echo <udc> > $CFG/UDC
       —— configfs.c:295 保留 udc_name，不先解绑会 -EBUSY（#5）
    5) ip link set usb0 up; ip addr add 172.16.42.1/24 dev usb0
    6) 起 dnsmasq（已有 --pid-file，起前先按 pid 停旧的，避免重复）
    7) 无论成败 exit 0（不留 failed 单元，失败由看门狗重试）

apply_host():
    1) echo "" > $CFG/UDC        # 解绑
    2) 按 pid 停 dnsmasq
    3) ip addr flush dev usb0 2>/dev/null
    4) exit 0

主流程：读 /sys/class/typec/port0/data_role
    device|""|文件不存在 → apply_device
    host               → apply_host
```

**必须遵守的三条硬约束**（都是实测得出，不是经验之谈）：
1. **先空后名**（#5）—— 否则 UDC 重出现后绑定必失败，这正是当前脚本修不好的根本原因。
2. **退出码恒为 0** —— 当前 `odin-usb-gadget.sh` 的 `set -e` + `Type=forking` 是"一次失败永久 failed"的根源（014:44-48）。新脚本在任何分支都 `exit 0`。
3. **删除 `set -e`** —— 改为显式检查返回值。

**(b) `/etc/udev/rules.d/99-odin-usb-role.rules`**

```
# UDC 出现/消失是主触发器（内核一定会发，#5 已确认）
SUBSYSTEM=="udc", ACTION=="add",    RUN{program}+="/usr/local/sbin/odin-usb-role.sh"
SUBSYSTEM=="udc", ACTION=="remove", RUN{program}+="/usr/local/sbin/odin-usb-role.sh"

# Type-C data_role 变化为辅触发器（真机上需确认 typec 子系统是否发 uevent）
SUBSYSTEM=="typec", ACTION=="change", RUN{program}+="/usr/local/sbin/odin-usb-role.sh"
```

> udev 的 `RUN{program}` 有 60s 超时上限，因此脚本内的 UDC 等待窗口必须 < 60s（取 45s 更稳妥），长等待交给看门狗。

**(c) `/etc/systemd/system/odin-usb-role.timer` + `.service`** —— 自愈看门狗

```ini
# odin-usb-role.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/odin-usb-role.sh
```
```ini
# odin-usb-role.timer
[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
[Install]
WantedBy=timers.target
```

**这是整个阶段 3 的安全网**：即使 udev 事件丢失、脚本竞态、FUSB301 误判，30 秒内一定会被拉回正确状态。没有它，一次误判就是永久失联。

### 5.4 服务形态改造

把 `odin-usb-gadget.service` 从：
```ini
Type=forking
ExecStart=/usr/local/sbin/odin-usb-gadget.sh
```
改为 `Type=oneshot` + `RemainAfterExit=yes`，`ExecStart` 指向新脚本。旧脚本保留为 `odin-usb-gadget.sh.deprecated` 或直接删除（删除前确认无其他引用）。

### 5.5 已知风险与内核层缺口（#2）

**legacy glue 的缺口是真实的，但不阻断阶段 3 的落地**：
- `qcom,msm8953-dwc3\0qcom,dwc3` 实际绑定 `dwc3-qcom-legacy.c`（`:917` 只匹配 `qcom,dwc3`），该驱动无 `glue_ops`，`dwc3_pre_set_role()` 是空操作
- 它的 QSCRATCH VBUS override 依赖 extcon（`:164`），本 DTB 无 extcon → **角色切换时 `UTMI_OTG_VBUS_VALID` 不再 toggling**
- 后果（据上游 lkml 讨论）：disconnect 事件不生成、dwc3 的 connected 标志卡住、影响 suspend 与**重新枚举**

**也就是说：阶段 3 之后，"第一次插 PC 能连上"大概率没问题（#1 默认 device），"拔掉再插回来能否重新枚举"是有风险的。** 这必须在真机上验证，且验证时保持串口在线。

### 5.6 回退

- **回退到阶段 0 的安全版**：改 `extlinux.conf` 的 `default` 为 `l0-safe`，重启。安全版没有 `usb-role-switch`，dwc3 走 `dr_mode=peripheral`，UDC 恒在。
- **单次强制切回 device**（无需重启）：
  ```sh
  echo device > /sys/class/usb_role/*/role    # #6 允许
  /usr/local/sbin/odin-usb-role.sh
  ```
- **串口始终是最后一道**：`serial-getty@ttyMSM0` 已启用（013:23）。

### 5.7 真机验证清单

```sh
# 依次执行，每步都要看结果
cat /sys/class/typec/port0/data_role   # device / host
ls /sys/class/udc                      # 非空 = device 就绪
systemctl status odin-usb-role.service # 必须是 active/exited，不得 failed
ip -4 addr show usb0                   # 172.16.42.1/24
nmcli device status                    # usb0 = unmanaged（013 的 P0-2 修复）
ssh user@172.16.42.1                   # 能登录

# 抽屉场景：拔 PC → 插 U 盘 → 拔 U 盘 → 插回 PC，SSH 必须恢复
ls /run/media/                         # U 盘自动挂载
journalctl -u odin-usb-role -f         # 看门狗的每次重试都要有日志
```

---

## 六、阶段 4：内核层根治（可选，视真机结果决定）

只在阶段 3 真机验证发现"重新枚举失败"时才启动。

| 方案 | 做法 | 风险 |
|---|---|---|
| 4-A（推荐先试） | 把 DTS 从 `qcom,msm8953-dwc3, qcom,dwc3` 改成扁平化 `qcom,snps-dwc3`，启用带 `glue_ops` 的 `dwc3-qcom.c` | **高**。新 binding 对 clocks / regulator / interconnect 的命名要求可能与现 DTB 不同，改完可能直接不工作；且无法在真机外验证 |
| 4-B | 给 `dwc3-qcom-legacy.c` 补 `glue_ops`（`pre_set_role` / `pre_run_stop`） | 中。需改内核驱动并重编，改动局部 |
| 4-C | 保持 legacy，在用户态切换时手动写 QSCRATCH 或补一个 `extcon` 子节点 | 中偏下。属于绕过，不干净 |

**建议顺序**：4-C（最快见效）→ 4-B（最正统的局部修复）→ 4-A（最彻底但风险最高）。

---

## 七、交付物清单

| 文件 | 阶段 | 备注 |
|---|---|---|
| `msm8953-smartisan-odin-norolesw.dts` + 编译产物 | 0 | 放 `/boot/dtbs/qcom/` |
| `/extlinux/extlinux.conf`（双 label） | 0 | 首刷 default = `l0-safe` |
| `apt` 包：dosfstools / exfatprogs / ntfs-3g / btrfs-progs / xfsprogs / f2fs-tools | 1 | 纯用户态 |
| `/etc/udev/rules.d/99-odin-automount.rules` | 1 | |
| `/usr/local/sbin/odin-mount-opts.sh` | 1 | 按 fstype 分流挂载选项 |
| `/etc/systemd/system/odin-fixperm@.service` | 1 | ext4 等 POSIX 文件系统的权限修正 |
| `nls_utf8.ko`（+ 可选 `nls_cp936.ko`） | 2 | 放入模块目录并 depmod |
| `/usr/local/sbin/odin-usb-role.sh` | 3 | 核心脚本，幂等 + 先空后名 + exit 0 |
| `/etc/udev/rules.d/99-odin-usb-role.rules` | 3 | |
| `odin-usb-role.service` / `.timer` | 3 | 看门狗是安全网，不可省 |
| `reports/016-*` | 全部 | 每个阶段一份实测记录 |
| `dist/FLASH.md` 更新 | 1、2、3 | 已知限制、首刷后切回完整版的步骤、救援命令 |

---

## 八、需要你先拍板的三个决策

1. **阶段 2 走哪条路**：重编 `nls_utf8`（成本：动内核、动模块树，收益：FAT32 中文正常），还是只推 exFAT（成本：零，收益：覆盖新盘，老 FAT32 盘仍乱码）？
2. **自动挂载用哪套**：systemd mount unit（轻、不引新包，我推荐），还是 udisks2（重、标准、与阶段 3 争抢事件）？
3. **阶段 0 的安全版是否接受"首刷期间完全没有 OTG"**：这是用它换确定性的代价。若你更想要首刷就能试 OTG，那阶段 0 的 `default` 要设为完整版，风险自负。

---
*计划结束 — odin-port 系列 №015*
