# 031 — 软件包清单与 core / gui 两个变体的关系

> 目的：把"哪些包装进镜像、core 与 gui 差在哪"一次性写清楚，并钉死一条
> **不变式：任何在 core 中的软件包，都必须存在于 gui 当中。**

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| 包清单结构 | **三层**：debootstrap `--include` → 基础清单 → GUI 增量清单 |
| 构建方式 | core 与 gui **并行独立构建**，各自的 debootstrap、各自一份 staging 目录 |
| 不变式 | **core ⊆ gui**（gui = core 全部 + 自己的增量） |
| 分层是否等于"gui 建在 core 之上" | **不是**。清单是分层的，构建是并行的 —— 见 §2 |

---

## 1. 三层清单

### 第 0 层：debootstrap `--include`（两变体共用，**与变体无关**）

`tools/ci/build-rootfs.sh:80`

```
busybox-static, udev, ssh, sudo, systemd, iproute2, dnsmasq, parted, e2fsprogs
```

这层的产物只由 suite / arch / `--include` 决定，所以 CI 会对它单独做缓存
（缓存键 = suite + arch + debootstrap 版本 + 本列表）。

### 第 1 层：基础清单（**core 与 gui 都装**）

`dist/build/setup-rootfs.sh:280-289`

| 分组 | 包 |
|---|---|
| 内核模块工具 | `kmod` |
| 网络 / WiFi | `network-manager` `wpasupplicant` `iw` `wireless-tools` `rfkill` `firmware-atheros` |
| 网络诊断 | `iputils-ping` `curl` `wget` `bind9-dnsutils` `net-tools` `traceroute` `tcpdump` |
| 测速 / 链路 | `iperf3` `ethtool` `mtr-tiny` |
| 系统基础 | `systemd-resolved` `systemd-timesyncd` `util-linux-extra` `fake-hwclock` `cron` |
| 电源 | `upower` `policykit-1` |
| 蓝牙 | `bluez` |
| 交互工具 | `brightnessctl` `htop` |
| 防火墙 | `nftables` |

> `udev` 在 `setup-rootfs.sh:76` 又单独装了一次 —— 与第 0 层的 `--include=udev`
> 重复，无害（apt 幂等），保留是为了明确"镜像里必须有 systemd-udevd"。

### 第 2 层：GUI 增量清单（**仅 gui**）

`dist/build/setup-rootfs.sh:365-376`

| 分组 | 包 |
|---|---|
| 桌面 | `plasma-mobile` `plasma-mobile-tweaks` |
| 显示管理 | `sddm` |
| X11 | `x11-utils` `xinput` |
| 网络管理（Qt 前端） | `plasma-nm` |
| 浏览器 | `firefox-esr` |
| 编辑 / 传输 | `vim` `nano` `less` `file` `unzip` `zip` `rsync` `tmux` `screen` |
| 监控 | `htop` `btop` `iotop` `sysstat` |
| 开发 | `git` `build-essential` |
| 音频 | `pipewire` `pipewire-pulse` `wireplumber` `pipewire-alsa` |
| 蓝牙扩展 | `bluez-obexd` `libspa-0.2-bluetooth` |
| 字体 | `fonts-noto-cjk` `fonts-noto-color-emoji` |

> `htop` 同时出现在第 1 层与第 2 层。第 1 层那份是必需的（core 也要有）；
> 第 2 层那份是**刻意保留**的，为的是让 gui 这份清单**自成一体** ——
> 读清单的人不必回头查基础清单才知道 gui 里有什么。apt 对重复名字是幂等的。

### 刻意**不装**的包

| 包 | 原因 |
|---|---|
| `ffmpeg` `v4l-utils` | 用户 2026-09-03 拍板：视频工具不进默认镜像（ffmpeg 会拖进一大堆依赖）。需要的人 `sudo apt install ffmpeg v4l-utils`。venus 的驱动与固件供给不受影响，去掉的只是用户态入口 |
| `mesa-venus` | 那是 VirtIO-GPU 的 Vulkan 驱动（给虚拟机用的），与裸机 qcom venus **同名不同物** |
| `udisks2` | 自动挂载走 systemd mount unit，见 `reports/017` |

---

## 2. 清单分层 ≠ 构建叠加

这两件事容易混为一谈，必须分开看：

**清单是分层的**：`setup-rootfs.sh` 先跑第 1 层（两个变体都跑），然后
`if [ "$ODIN_VARIANT" = "gui" ]` 再跑第 2 层。所以从包的角度，
gui = 第 0 层 + 第 1 层 + 第 2 层，core = 第 0 层 + 第 1 层。

**构建是并行的**：`tools/ci/build-rootfs.sh:32`

```sh
ROOT=${ROOT:-/tmp/odin-rootfs-$VARIANT}
```

两个变体各用各的 staging 目录、各跑各的 debootstrap。
**gui 不是在 core 那个 rootfs 上继续装东西。**

注释里也写明了为什么必须分开：

> 两个变体共用一个目录时，第二个变体会直接复用第一个已经摆好的根
> —— 表现为"编了 gui，出来的却是 core"。

CI 上同样如此：rootfs 是一个 **matrix**（`core` / `gui` 两条 job），
共用同一份 kernel / dtb artifact，但各自出各自的镜像。

---

## 3. 不变式：core ⊆ gui

> **任何在 core 中的软件包，都必须存在于 gui 当中。**

当前结构**天然满足**这条：core 与 gui 都完整跑第 0 层和第 1 层，
gui 只是多跑一层。所以：

- 往**基础清单**加包 ⇒ 两个变体同时获得，**不动** gui 清单。
- 往 **gui 增量清单**加包 ⇒ 只有 gui 获得，core 不受影响。

**给改清单的人的操作纪律**：

1. 想让两个变体都有 ⇒ 加进**基础清单**（`setup-rootfs.sh:280` 那段）。
   **不要**同时去 gui 清单里删"重复项" —— 那会让 gui 隐性依赖基础清单，
   基础清单一变 gui 就跟着变，这不是 gui 该有的耦合。
2. 只给 gui ⇒ 加进 gui 增量清单（`setup-rootfs.sh:365` 那段）。
3. 删包前先确认它在另一层的引用。

---

## 4. 一个相关的坑：服务的启用不属于"装包"

包装进去了，服务不代表就启用了。2026-09-03 查出一个真 bug：

`odin-swap.service` 的 unit 文件在 `dist/build/rootfs/`，而那棵树由
`apply-staging-fixes.sh` 部署 —— 它跑在 `setup-rootfs.sh` **之后**。
于是 `setup-rootfs.sh` 里那句 `systemctl enable odin-swap.service` 在文件还
不存在时执行，必然失败，又被 `2>/dev/null || true` 吞掉 ⇒ swap 从来没建过
（真机 `Swap: 0`、`/swapfile` 不存在）。

**现在的规则**：

- unit 文件在 `dist/build/rootfs/` 的服务 ⇒ 启用动作写在
  `apply-staging-fixes.sh` 的 `阶段 5b`（覆盖树部署之后），建 wants 符号链接，
  并且 **不吞失败**（文件缺失会明确报"跳过 <unit>"）。
- unit 文件由 `setup-rootfs.sh` 内联 `cat >` 生成的 ⇒ 可以在本脚本里直接 enable
  （如 `odin-usb-gadget.service`，`setup-rootfs.sh:109` 生成、`:145` 启用）。

当前各服务的启用状态：

| 服务 | 启用 | 说明 |
|---|---|---|
| `odin-swap.service` | ✅ sysinit.target | 2026-09-03 修好，首启建 5 GiB swapfile |
| `odin-backlight.service` | ✅ multi-user.target | 2026-09-03 新增，开机设背光 500 |
| `odin-usb-gadget.service` | ✅ + 30s 看门狗 | 另有 udev 规则（UDC/typec/extcon change）触发 |
| `odin-venus-fw.service` | ❌ 刻意不启用 | 正确时序已由 initramfs 覆盖；且兜底会重建 probe，真机踩过卡死事故（reports/029 §7） |
| `odin-wlan-fw.service` | ❌ 刻意不启用 | 同上，initramfs 已覆盖 |
| `odin-dnsmasq@.service` | static | 不参与开机事务，由 `odin-usb-role.sh` 按需 start |

---

## 5. 已发布版本与本清单的对应

| 版本 | 清单变化 |
|---|---|
| `v0.9.4-venus-usable` | 基础清单加 `user`→`video` 组（不是包，但决定硬件编解码能否用） |
| `v0.9.4-backlight-swap` | 基础清单加 `brightnessctl`、`htop` |
| （更早） | ffmpeg / v4l-utils 从基础清单移出 |
