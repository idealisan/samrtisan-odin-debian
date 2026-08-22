# 分析文档 004 — pmbootstrap 原版工作流程详解

| 项目 | 内容 |
|------|------|
| 文档编号 | ODIN-DOC-004 |
| 日期 | 2026-08-22 |
| 对象 | **原版** pmbootstrap 3.0.0_alpha（本地树仅含 macOS 移植小改动，已剔除；核心流程与上游一致）+ 原版 pmaports master（HEAD 817ed870e，v24.12-era） |
| 目的 | 为后续修改（ODIN 设备包、内核包、lk2nd 定制）提供准确的"原版动作地图"，确保修改时每一步插入位置正确 |
| 调查方式 | 直接阅读 `pmb/` Python 源码与 pmaports APKBUILD，关键结论均给出文件/函数/行号依据 |

---

## 一、总体流程图

```
pmbootstrap init          ──► ~/.config/pmbootstrap_v3.cfg (用户选择持久化)
        │
        ├─ clone pmaports ──► $WORK/cache_git/pmaports (按 channel 切分支)
        ▼
pmbootstrap build <pkg>   ──► chroot 内 abuild ──► $WORK/packages/<channel>/<arch>/*.apk
        │                        (内核: 拉 msm8953-mainline/linux tarball)
        │                        (lk2nd: 拉 msm8916-mainline/lk2nd tag, arm-none-eabi 编译)
        ▼
pmbootstrap install       ──► chroot_rootfs_<device>: apk 安装 device 包+内核+UI…
        │                        ├─ apk trigger: mkinitfs + boot-deploy ──► /boot/boot.img
        │                        └─ 手动再跑一次 mkinitfs(写入 UUID)
        │                  ──► truncate <device>.img + parted 分区 + 拷贝 rootfs
        │                        (+ img2simg 稀疏化) ──► chroot_native/home/pmos/rootfs/
        ▼
pmbootstrap flasher / export
        ├─ flash_lk2nd   : fastboot flash boot $BOOT/lk2nd.img     ← 先刷
        ├─ flash_kernel  : fastboot flash boot $BOOT/boot.img
        └─ flash_rootfs  : fastboot flash userdata <device>.img
```

---

## 二、`pmbootstrap init`：提问序列与记录位置

### 2.1 配置文件物理位置

- 配置：`$XDG_CONFIG_HOME/pmbootstrap_v3.cfg`（默认 `~/.config/pmbootstrap_v3.cfg`）
  —— `pmb/config/__init__.py:78-82`（defaults["config"]），TOML 格式，
  由 `pmb/config/file.py` 的 `load()/save()` 读写。
- 工作目录默认 `~/.local/var/pmbootstrap`
  —— `pmb/core/config.py:80`（`work: Path = .../.local/var/pmbootstrap`）。
- aports 默认克隆到 `$WORK/cache_git/pmaports`
  —— `pmb/core/config.py:48`；init 中若自定义 aports 则重置为该路径
  （`pmb/config/init.py:687-690`）。

### 2.2 提问顺序（pmb/config/init.py frontend()，行 677–791）

| # | 问题 | 函数 | 写入 Config 字段 | 备注 |
|---|------|------|------------------|------|
| 0 | work 路径 | ask_for_work_path(:65) | work | 先于一切（chroot 需要它） |
| 1 | channel（release 通道） | ask_for_channel(:117) | channel | 读 pmaports/channels.cfg；**选完立即把 cache_git/pmaports 切到对应分支**（switch_to_channel_branch）；通道名本身不存 cfg（存的是分支状态）|
| 2 | vendor → codename | ask_for_device(:392) | device | 已有端口→列出 codenames；新端口→`pmb.aportgen.generate("device-…"/"linux-…")` 自动生成模板包 |
| 3 | kernel 类型 | ask_for_device_kernel(:349) | kernel | 数据源见 §2.3；单内核设备返回 None 不提问 |
| 4 | provider 选择 | ask_for_provider_select(:276) | providers{} | 对 device/postmarketos-base/UI 各包的可替换依赖（如 mesa 变体）|
| 5 | 键盘布局 | ask_for_keymaps(:238) | keymap | 仅 deviceinfo 有 keymaps 时 |
| 6 | 用户名 | ask_for_username(:48) | user | 禁止 "root" |
| 7 | UI | ask_for_ui(:155) | ui | 列出 postmarketos-ui-* |
| 8 | UI 附加包 | ask_for_ui_extras(:194) | ui_extras | |
| 9 | systemd/openrc | ask_for_systemd(:210) | systemd | |
| 10 | 附加选项 | ask_for_additional_options(:469) | locale/timezone/hostname/ssh_keys 等 | 含镜像选择 |
| 11 | extra packages | 内联(:753-761) | extra_packages | 逗号分隔追加进 rootfs 的包 |
| 12 | 构建过期包? | ask_build_pkgs_on_install(:631) | build_pkgs_on_install | |

最后 `pmb.config.save()` 持久化，并询问是否 zap 旧 chroot（设备变了必须 zap）。

### 2.3 内核选项从哪来

`pmb.parse._apkbuild.kernels(device)` 扫描设备 APKBUILD 的 **`subpackages="$pkgname-kernel-<type>"`**
（如 fairphone-fp3 的 `-kernel-downstream`/`-kernel-mainline`），返回 {类型: 描述} 字典；
install 时由 `get_kernel_package()`（pmb/install/_install.py:87-111）映射回
`device-<vendor>-<codename>-kernel-<type>` 子包安装。

> msm8953 社区设备（mido/daisy/vince…）**不使用子包机制**，直接
> `depends="linux-postmarketos-qcom-msm8953"` → init 不出现内核问题。

---

## 三、工作目录结构（$WORK = ~/.local/var/pmbootstrap）

| 路径 | 内容 | 产生者 |
|------|------|--------|
| `cache_git/pmaports/` | pmaports git 克隆（channel 分支） | init |
| `chroot_native/` | 主机架构 Alpine chroot（x86_64/arm64 host） | 首次命令 |
| `chroot_buildroot_aarch64/` | 目标架构构建 chroot | 需要 buildroot 时自动建 |
| `chroot_rootfs_<vendor>-<codename>/` | 目标设备根文件系统（安装产物原型） | install |
| `packages/<channel>/<arch>/` | **本地编译包仓库**（.apk + APKINDEX.local.tar.gz） | 每次 build |
| `cache_ccache/`、`cache_http/`、`cache_distfiles/` | ccache / 下载缓存 / 上游源码 tarball 缓存 | abuild |
| `img/`（旧版）/ 实际在 `chroot_native/home/pmos/rootfs/` | 最终 `<device>.img` | install |
| `log.txt`、`pmb.cfg` 快照 | 日志 | 全程 |

chroot 命名规则：`pmb/core/chroot.py` — `chroot_{native|buildroot_<arch>|rootfs_<device>}`；
本地包仓库以 bind-mount 出现在每个 chroot 的 `/mnt/pmbootstrap/packages/<channel>`
（`pmb/helpers/repo.py:73-76`，`pmb/chroot/apk.py:158-224` 用作 `--repository`）。

---

## 四、`pmbootstrap build`：编译体系逐环节

入口 `pmb/build/_package.py: packages()`（:428 起）：

1. **依赖解析与构建队列**：读 APKBUILD 的 depends/makedepends/subpackages，
   缺失或过期的依赖先入队（BUILDQUEUE 日志，:410-414），保证先构建被依赖者。
2. **交叉编译判定** `pmb/build/autodetect.py: crosscompile()`（:97-107）：
   - 用户未开 `--cross` → None（纯 qemu-user 模拟，全部在 buildroot chroot 里原生编）；
   - 目标 arch 与主机相同 或 APKBUILD 有 **`pmb:cross-native`** → `"native"`
     （在 native chroot 用交叉编译器编，内核/lk2nd 都是这种）；
   - 其余 → `"crossdirect"`（native 工具链注入 foreign chroot PATH）。
3. **安装编译器** `pmb/build/init.py: init_compiler()`（:114-133）：
   native chroot 装 `gcc-aarch64/g++-aarch64`（gcc4/gcc6 变体按 makedepends）、
   `ccache-cross-symlinks`；lk2nd 这类 bare-metal 包则在其 APKBUILD
   `makedepends="gcc-arm-none-eabi"` 中自带工具链。
4. **执行 abuild** `pmb/build/backend.py: run_abuild()`（:182-330）：
   - 把 pmaports 中的 aport 拷入 chroot `/home/pmos/build`；
   - `/home/pmos/packages/pmos → /mnt/pmbootstrap/packages/<channel>` 软链；
   - 环境变量：
     - cross=native 时 `CROSS_COMPILE=aarch64-alpine-linux-musl-`、`CC=<hostspec>-gcc`；
     - ccache 开启时 RUSTC_WRAPPER=sccache、GOCACHE=…；
   - 命令：`abuild -D postmarketOS [-r|-d] [-f]`（`-r`=abuild 自管依赖/strict，
     默认 `-d` 且依赖由 pmbootstrap 预装，:268-283）；
   - `pmb.chroot.user(cmd, suffix, "/home/pmos/build", env)` 执行。
5. **产物落盘**：abuild 产出 apk → chroot 内 `/home/pmos/packages/pmos/<arch>/`，
   即宿主 `$WORK/packages/<channel>/<arch>/`；`finish()` 生成/更新本地
   `APKINDEX.local.tar.gz`。源码 tarball/git 由 abuild fetch 下载到
   `chroot_*/var/cache/distfiles/`（对应宿主 `$WORK/cache_distfiles` 经挂载共享）。

### 4.1 内核包的实际编译（结合原版 pmaports）

包：`pmaports/device/community/linux-postmarketos-qcom-msm8953/APKBUILD`

```sh
pkgver=6.11.1 ; _tag="$pkgver-r0"
url="https://github.com/msm8953-mainline/linux"
source="$pkgname-v$_tag.tar.gz::$url/archive/v$_tag.tar.gz
        config-$_flavor.aarch64"
options="!strip !check !tracedeps pmb:cross-native pmb:kconfigcheck-community"
prepare() { default_prepare; cp "$srcdir/config-$_flavor.$arch" .config; }
build()   { unset LDFLAGS; make ARCH=arm64 CC="${CC:-gcc}" KBUILD_BUILD_VERSION=…; }
package() { make zinstall modules_install dtbs_install INSTALL_PATH=$pkgdir/boot
            INSTALL_MOD_PATH=$pkgdir INSTALL_DTBS_PATH=$pkgdir/boot/dtbs …
            install …/kernel.release $pkgdir/usr/share/kernel/$_flavor/ }
```

要点：
- **数据来源**：GitHub release tarball（tag 即版本，无额外 patch 列表）——下载进
  distfiles 缓存后解压到 `$srcdir/linux-v6.11.1-r0`；
- **配置来源**：APKBUILD 同目录的 `config-postmarketos-qcom-msm8953.aarch64` 被
  `cp` 成 `.config`，之后就是普通增量 `make`（无 defconfig、无下游脚本）；
- `pmb:kconfigcheck-community` 使 pmbootstrap 在构建前后用
  `pmaports/kconfigcheck.toml` 校验 .config（pmb/parse/kconfig.py）；
- 产物：`linux-postmarketos-qcom-msm8953-*.apk`（内含 /boot/vmlinuz、
  /boot/dtbs/qcom/*.dtb、/lib/modules/…、/usr/share/kernel/*/kernel.release）；
- 本仓库 odin-port 的 `config-….aarch64` 正是该 config 文件的修改版。

### 4.2 lk2nd 的实际编译

包：`pmaports/main/lk2nd/APKBUILD`（pkgver=19.0）

```sh
url="https://github.com/msm8916-mainline/lk2nd"
makedepends="dtc gcc-arm-none-eabi python3 py3-libfdt py3-pycryptodome …"
source="$pkgname-$pkgver.tar.gz::…/archive/refs/tags/$pkgver.tar.gz + 2 patches"
options="!check !archcheck !tracedeps !strip pmb:cross-native"
build() {
    _build lk2nd-msm8953                                        # 普通
    _build lk2nd-msm8953 BOOTLOADER_OUT=msm8953-signed SIGN_BOOTIMG=1   # 签名版
}
# _build ≈ make LK2ND_VERSION="$pkgver-r$pkgrel-postmarketos" TOOLCHAIN_PREFIX=arm-none-eabi- <project>
msm8953()          { install -Dm644 build-lk2nd-msm8953/lk2nd.img -t "$subpkgdir"/boot; }
msm8953_signed()   { … msm8953-signed/build-lk2nd-msm8953/lk2nd.img … }
```

- **make 项目名是 `lk2nd-msm8953`**（不是裸 TARGET=msm8953），输出目录即我们熟悉的
  `build-lk2nd-msm8953/`，产物只打包 **lk2nd.img 到 /boot/**（无 emmc_appsboot.mbn）；
- 设备侧依赖方式：设备 APKBUILD `depends="lk2nd-msm8953"`；
- 整棵 lk2nd 树没有 per-device 定制入口——定制（如 ODIN 面板库）必须像我们一样
  以 patch 形式加入 source= 并重建 apk。

---

## 五、`pmbootstrap install`：镜像生成全流程

`pmb/install/_install.py: install()`（:1347）→ 步骤计数 4（无 --split/--recovery）：

1. **PREPARE NATIVE CHROOT**：初始化 native chroot + 安装
   `pmb.config.install_native_packages`（parted、e2fsprogs、android-tools 等）。
2. **CREATE DEVICE ROOTFS** `create_device_rootfs()`（:1243-1300）：
   建 `chroot_rootfs_<device>`，apk 安装：
   ```
   install_device_packages + ["device-"+device]
   + ["postmarketos-ui-"+ui (+ -extras)]
   + get_kernel_package(config)        ← device-<dev>-kernel-<type> 或空(直依赖)
   + get_nonfree_packages(device)      ← 自动探测 firmware-* 子包
   + extra_packages / --add
   ```
   设备包 `depends` 再拖入：linux-*、lk2nd-msm8953、firmware-*、soc-qcom-msm8953、
   msm-firmware-loader、mkbootimg 等 → **整条软件链在此一次性进入 rootfs**。
   - apk 安装过程中触发器生效：`postmarketos-mkinitfs.trigger` 检测
     `/usr/share/deviceinfo/deviceinfo` 存在即运行 `mkinitfs`；
     `boot-deploy` 触发器随后用同一 deviceinfo 组装 **`/boot/boot.img`**——
     **pmbootstrap 本身没有任何 mkbootimg 代码**（全树 grep 仅 aportgen 模板提到包名），
     Android boot image 完全由 rootfs 内的 boot-deploy 依据
     `deviceinfo_generate_bootimg / flash_offset_base/kernel/ramdisk/second/tags /
     flash_pagesize / append_dtb(dtb= qcom/msm8953-xiaomi-mido 式名字) / kernel_cmdline` 生成。
3. **PREPARE INSTALL BLOCKDEVICE** `install_system_image()`（:833 起）：
   - 尺寸估算 `get_subpartitions_size()`（boot 固定上限检查 sanity_check_boot_size）；
   - `blockdevice.create()`：非 split 时在 native chroot
     `/home/pmos/rootfs/<device>.img` 上 `truncate -s <size>M`，
     losetup 挂为 `/dev/install`（pmb/install/losetup.py；macOS 下走 MACOS_PORT.md 替代路径）；
   - `partition()` parted 建 GPT：p1 boot(size_boot, 标签 pmOS_boot)、reserve、p2 root(pmOS_root)；
   - `format()` mkfs.ext4/f2fs（--fde 则 luksFormat 加密 root）。
4. **fstab/crypttab + 重跑 mkinitfs**（:886-888）：把真实 UUID 传入 cmdline 后在
   rootfs chroot 里再执行一次 `mkinitfs` 重新生成 initramfs。
5. **FILL INSTALL BLOCKDEVICE**：`copy_files_from_chroot()` 把 rootfs 全部内容
   （除 /home）拷进镜像分区；创建 home skel；configure_apk；embed_firmware。
6. **收尾**：`--sparse`（或 deviceinfo_flash_sparse=true）时在 native chroot 用
   `img2simg` 稀疏化 `<device>.img`（:925-950）。最终文件：
   - `chroot_native/home/pmos/rootfs/<device>.img`（含分区表的完整镜像）
   - split 模式：`<device>-boot.img` / `<device>-root.img`
   - rootfs chroot 的 `/boot/`：`vmlinuz*、initramfs*、dtbs/、boot.img、lk2nd.img`
7. 结束打印 **FLASHING INFORMATION**（print_flash_info :962-1043）：按 flash_method
   与存在的文件逐条提示可用的 `pmbootstrap flasher …` 命令；其中：
   - `"flash_boot"` 动作条件：rootfs `/boot/boot.img` 存在 → 提示
     `pmbootstrap flasher flash_boot`（刷生成的 boot.img）；
   - `"flash_lk2nd"` 条件：`/boot/lk2nd.img` 存在 → 打印
     *"Your device supports and may even require flashing lk2nd. You should flash it
     before flashing anything else"*。

---

## 六、`pmbootstrap flasher` 与 `export`

### 6.1 刷写模板（pmb/config/__init__.py flashers 表 :374-400 + pmb/flasher/*)

fastboot 方法的动作模板（变量替换见下）：

```python
"flash_kernel": [["fastboot","flash","$PARTITION_KERNEL","$BOOT/boot.img$FLAVOR"]],
"flash_rootfs": [["fastboot","flash","$PARTITION_ROOTFS","$IMAGE"]],
"flash_boot":   [["fastboot","flash","$PARTITION_KERNEL","$BOOT/boot.img$FLAVOR"]],
"flash_lk2nd":  [["fastboot","flash","$PARTITION_KERNEL","$BOOT/lk2nd.img"]],
"boot":         [["fastboot","--cmdline","$KERNEL_CMDLINE","boot","$BOOT/boot.img$FLAVOR"]],
```

变量填充 `pmb/flasher/variables.py`：
- `$BOOT` = `/mnt/rootfs_<device>/boot`（rootfs chroot 的 boot 目录 bind 进 native）
- `$PARTITION_KERNEL` = `deviceinfo_flash_fastboot_partition_kernel or "boot"`
- `$PARTITION_ROOTFS` = `…_rootfs or …_system or "userdata"`
- `$IMAGE` = `/home/pmos/rootfs/<device>.img`；`$FLAVOR` 在新版 pmaports 下为空串

`flasher/frontend.py: kernel()/rootfs()`：flash_kernel 前会强制重建 initramfs
（`pmb.chroot.initfs.build`）并跑 kconfig 检查；flash_rootfs 检查
`flash_fastboot_max_size` 限制。

### 6.2 `pmbootstrap export`（pmb/export/symlinks.py）

在 `$WORK/chroot_export/` 创建指向产物的符号链接（存在才建）：
`boot.img、initramfs(-extra)、vmlinuz*、uInitrd/uImage、dtbo.img、<device>.img、
<device>-boot/-root.img、pmos-<device>.zip、lk2nd.img`。

> 注意 `pmb/export/odin.py` 是 **三星 Odin 刷机工具的 .tar.md5 导出**
> （heimdall-bootimg 设备用），与 Smartisan ODIN 只是同名巧合。

---

## 七、端到端数据流总结表（qcom-msm8953 典型设备）

| 阶段 | 输入 | 处理者 | 输出/落点 |
|------|------|--------|-----------|
| init | 用户交互 | pmb/config/init.py | `~/.config/pmbootstrap_v3.cfg`；cache_git/pmaports@master |
| build 内核 | GitHub msm8953-mainline/linux v6.11.1-r0 tarball + config 文件 | native chroot abuild（CROSS_COMPILE=aarch64-…） | `$WORK/packages/edge/aarch64/linux-postmarketos-qcom-msm8953-*.apk` |
| build lk2nd | GitHub msm8916-mainline/lk2nd tag 19.0 + 补丁 | native chroot make（arm-none-eabi-） | `lk2nd-msm8953-*.apk`（内含 /boot/lk2nd.img） |
| install | device 包+上述 apk+UI 包 | chroot_rootfs_<dev> apk | 根文件系统；trigger 生成 /boot/initramfs 与 **/boot/boot.img** |
| 镜像 | rootfs 内容 | truncate/parted/mkfs/copy/img2simg | `chroot_native/home/pmos/rootfs/<device>.img` |
| flasher | boot.img / lk2nd.img / <device>.img | fastboot（native chroot，USB 直通） | 手机 boot 分区 ← lk2nd.img 先刷；boot.img 后刷；userdata ← .img |
| export | 同上 | 符号链接 | `$WORK/chroot_export/*` 供手动 heimdall/fastboot |

## 八、对我们 ODIN 移植的操作映射（后续修改时的插入点）

1. **内核替换**：我们的补丁 0001–0007 + 新 config 对应"改 APKBUILD 的 source/patches +
   config 文件"层；用 `pmbootstrap build linux-postmarketos-qcom-msm8953` 重建，
   产物自动进本地 repo，无需触碰 install 逻辑。
2. **lk2nd 替换**：两种合法插法：(a) fork main/lk2nd APKBUILD 加 odin patch（上游式）；
   (b) 手工把自编 lk2nd.img 放入 rootfs `/boot/` 以满足 flasher/export 的存在性检测
   （print_flash_info/symlinks 只查文件是否存在）。
3. **缺 device-smartisan-odin**：init 无法选中本机 → 需按 mido 模板新增
   device/testing/device-smartisan-odin（deviceinfo: dtb=qcom/msm8953-smartisan-odin、
   append_dtb=true、fastboot 偏移组同 mido；depends 含 linux-postmarketos-qcom-msm8953
   + lk2nd-msm8953 + soc-qcom-msm8953…），否则 install/flasher 全链无法走通。
4. **面板自动适配依赖链**：init 不参与；靠 lk2nd 改 DTB compatible → 内核 panel
   driver probe，因此 lk2nd.img 必须包含 odin 设备描述（报告 001 已修复占位符）。

---

*文档结束 — odin-port 系列 №004（原版流程调查，未包含本地修改逻辑）*
