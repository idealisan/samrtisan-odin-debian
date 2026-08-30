# AGENTS.md — odin-work 工作准则

本文件是这个仓库里 **给 AI agent 与协作者看的唯一权威规则**。开工前先读完。
它继承并扩展上级目录 `/Volumes/caseSensitiveBar/AGENTS.md` 的时间戳要求。

---

## 0. 项目一句话

坚果 **U2 Pro（Smartisan ODIN，msm8953/SDM450）** 的 **主线 Linux 6.19 + Debian 12 bookworm(arm64)** 移植工作区。
真机已点亮屏幕、USB 网络/SSH 稳定、QEMU 回归通过；当前阶段是**可复现性与发布工程**。

**仓库原则（README.md:8-14）**：本仓库**只放源码与文档**，二进制产物（镜像、lk2nd、DTB、.ko）一律不入库，
统一作为 **GitHub Release 资产**发布。仓库里留下的是"能从零重建出这些东西的全部脚本"。

---

## 1. 铁律（用户拍板，优先级最高，不得变通）

### 1.1 每个命令前必须打印时间戳

沿用上级 `AGENTS.md` 的规则：任何 Bash 命令前先用 `date` 打时间戳，便于判断耗时与卡死。

```sh
date '+[%F %T] 开始:<动作说明>' && <实际命令> ; date '+[%F %T] 结束:<动作说明>'
```

长耗时/可能阻塞的命令（git clone/pull、内核编译、debootstrap、镜像打包、批量拷贝）**必须**带；
极短查询（ls、cat、grep）至少在开头带一次。**本规则同样适用于所有 subagent 下达的命令。**

### 1.2 完成一点工作，立即提交并推送

**不要攒着。** 每完成一个可独立描述的小成果（修好一个脚本、写完一篇报告、验证完一个结论），
就地 `git add` → `git commit` → `git push origin main`。

理由：防止工作丢失。当前工作树就是唯一工作副本，任何中断都不该造成内容损失。

推送前自检：`git status` 干净、无 `.img`/`.dtb`/`.ko` 等被 `.gitignore` 拦住的产物被误加、
无绝对路径泄进文档（见 1.5）。

### 1.3 只增不删 —— 复制而非删除

**任何情况下都不要主动删除或清理文件**，包括但不限于 `rm`、`git clean`、`git gc --prune`、
`find -delete`、清空回收站式的整理。

正确做法：

- 需要"只留一部分"时 → **把需要的文件复制一份到 `tmp/` 下再处理**，把不需要的**排除掉**；
- 需要"重建某个目录"时 → 在 `tmp/` 下搭新的，验证通过后**覆盖式拷贝**过去；
- 需要保留旧版本 → 原地复制成 `*.odin-bak`（真机上的既有约定），而不是删掉原文件。

理由：删除类操作会触发权限警告与危险提示，拖慢效率，且不可逆。

**所有清理统一留到最后**，作为独立的一轮工作，且**必须先跟用户确认清单**再执行。

### 1.4 制品一律以 CI 构建为准

**最终确认状态的制品，必须是 CI（`.github/workflows/release-build.yml`）构建出来的那一版。**

- 本地构建、直接改目标环境（真机 / 镜像内 / staging 目录）里的文件 → **都只是开发过程中的尝试**，
  可以用来探路、验证假设、复现问题，但**不能作为最终结论，不能据此确认"已修好"**；
- 任何"修好了"的判断，都要有一次 CI 构建 + 真机验证的闭环证据；
- 本地产物与 CI 产物不一致时，**以 CI 为准**，并追查差异原因（见 §5 可复现性边界）。

### 1.5 项目自包含 —— 不再依赖仓库外的任何目录

**从今往后，这个项目只依赖两样东西：本文件夹内的内容 + 在线仓库。**

不得再引用或依赖这些历史位置：

| 曾经依赖 | 现在怎么办 |
|---|---|
| `/Volumes/caseSensitiveBar/linux-msm8953`（内核源码树） | 由 `tools/ci/fetch-kernel.sh` 现取到 `KDIR`（默认 `/tmp/linux-msm8953`），钉死 SHA |
| `/Volumes/caseSensitiveBar/odin-port/`（旧工作副本） | **已废弃**，本仓库 `odin-work` 是主工作区 |
| `/Volumes/caseSensitiveBar/refs/`、`Pro_user_V4.2.5/`（原厂 ROM 与参考源码） | 需要时重新下载或向用户索取，不要写死路径 |
| `/Volumes/caseSensitiveBar/pmaports/`、`pmbootstrap/` | 仅历史调研用，与构建无关 |
| 容器内 `/mnt/debian`（8/23 陈旧 staging） | **禁用**，不含后续改动，拿它重建会丢东西 |
| `~/.config/odin-port/replacements.txt`（脱敏规则） | 唯一刻意保留在仓库外的文件，因为它内含要隐藏的原字符串 |

**已知待修**：`dts/build-dtb.sh:19` 仍硬编码 `KDIR="${KDIR:-/Volumes/caseSensitiveBar/linux-msm8953}"`。
跑它时**必须显式传 `KDIR`**；走 CI 路径 `tools/ci/build-dtb.sh` 则不受影响。
新增脚本时，默认路径一律不得指向 `/Volumes/...`、`/mnt/...` 或任何仓库外绝对路径。

### 1.6 临时文件放本文件夹的 `tmp/`，不用系统 `/tmp`

- 临时工作目录：**`<仓库根>/tmp/`**（已加入 `.gitignore`）。
- **不要**用 `/tmp`、`$TMPDIR`、`/var/folders/...` 等系统临时目录。
- `tmp/` 下按任务建子目录，如 `tmp/dtbbuild/`、`tmp/imgcheck-<日期>/`。
- 需要"只留一部分文件"的场景（见 1.3），一律复制到 `tmp/` 下操作。

注意：`tools/ci/*.sh` 里 `KDIR`、`ROOT`、`SRC` 等**环境变量的默认值仍是 `/tmp/...`**，
这是在线 CI 的既有约定，跑 CI 路径时保持原样；**手工在本机跑时**要显式覆盖成 `tmp/` 下的路径。

### 1.7 任何联网 IO 一律走后台任务 + 短轮询

**凡是涉及网络 IO 的操作，一律用后台任务（Background Task）执行，不要让前台阻塞。**

包括但不限于：`git clone` / `git fetch` / `git pull` / `git push`、`gh` 命令、
`curl` / `wget` 下载、内核源码拉取（fetch-kernel.sh）、debootstrap 装包、
apt/pip/npm 安装、Release 上传、任何访问远端仓库或外部站点的动作。

检查后台任务状态时：

- **轮询间隔不得超过 15 秒**（用 `TaskOutput` 的 `timeout` 参数控制，最大给 15000 ms）；
- **不要**用若干分钟的长等待一次等到底；
- 靠多轮短轮询逐步收集输出，随时可以判断是否需要中止或改道。

理由：联网操作耗时不可预测，前台长等待既卡住会话，也无法在中途根据输出做判断；
短轮询能在任务完成的第一时间接上，也能及早发现卡死。

---

## 2. 目录地图

| 目录 | 放什么 | 备注 |
|---|---|---|
| `patches/` | 内核补丁 0001–0008 | `From:` 统一 `odin-port <odin@port.local>` |
| `lk2nd/` | lk2nd 补丁 0001–0004 + 设备树 | 版本钉死 tag 23.1 |
| `dts/` | 设备树源码与 `build-dtb.sh` | 完整版 `msm8953-smartisan-odin.dts` 由 patches/0007 注入内核树，不在本仓库 |
| `dist/` | 刷机包与**用户态组件源码** | `dist/build/rootfs/` 是唯一该改的地方 |
| `tools/ci/` | 5 个构建脚本（无 Makefile） | 构建入口全是 `bash tools/ci/*.sh` |
| `tools/` | 镜像导出、打包、校验等辅助脚本 | |
| `flash/` | `flash-all.sh` 阶段状态机（00→90） | 支持 `--from <阶段>` 与 `--dry-run` |
| `odin-qemu/` | QEMU 回归测试台 | **只能验用户态**，不能验 msm8953 硬件链路 |
| `evidence/` | 真机取证数据（116 个文件） | 含原厂 aboot 逆向结果 |
| `reports/` | 专题分析报告 001–020 | 见 §4 |
| `docs/` | 四篇正式文档 + 导航 | `docs/04-排障.md` 优先于翻 WORKLOG |
| `WORKLOG.md` | 流水账（961 行），**追加式** | 每步完成后就地追加 |
| `tmp/` | 临时工作区（git 忽略） | 见 1.6 |

`config-postmarketos-qcom-msm8953.aarch64` 是内核 `.config` 基线，`tools/ci/build-kernel.sh:45` 用它。

---

## 3. 构建与发布

### 3.1 本地流水线（无 Makefile，靠目录约定串联）

```sh
bash tools/ci/fetch-kernel.sh     # 三级回退取内核到钉死 SHA
bash tools/ci/build-dtb.sh  out/dtb
bash tools/ci/build-kernel.sh out/kernel
bash tools/ci/build-lk2nd.sh out/lk2nd
sudo -E bash tools/ci/build-rootfs.sh out/rootfs out/kernel out/dtb
```

常用环境变量覆盖：`KDIR`、`KERNEL_SHA`、`CROSS`、`JOBS`、`LK2ND_VER`、`SRC`、`ROOT`、`SUITE`、`KOUT`、`DOUT`。

### 3.2 CI

`.github/workflows/release-build.yml` **只在 `release: [prereleased, released]` 与 `workflow_dispatch` 时触发**，
刻意不挂 push/PR（内核几十分钟 + debootstrap，每次提交跑是浪费）。

五个 job：`dtb`、`lk2nd`、`kernel` → `rootfs`（needs 前两者）→ `publish`（汇总、算 SHA256SUMS、`gh release upload`）。

### 3.3 三个钉死的外部输入

| 项 | 值 | 位置 |
|---|---|---|
| 内核 commit | `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b` | `.github/workflows/release-build.yml:40` |
| lk2nd | `23.1`（**YAML 里必须加引号**，否则被解析成浮点数） | `:43` |
| Debian | `bookworm` / `http://deb.debian.org/debian` | `tools/ci/build-rootfs.sh:38-44` |

### 3.4 版本号：严格递增，永不重用、永不修改

**版本号一旦发布就作废，只能往上开新号。** 不允许：

- 删除已发布的 Release / tag 再拿同一个号重发；
- 移动已发布的 tag 指向别的提交；
- 就地改写某个已发布版本的资产（哪怕内容"只是补了个文件"）。

**小修与非破坏性的修复，直接开新的 patch 号递增上去**（`v0.9.2` → `v0.9.3` …），
不要回头改旧版本。开新号的代价是一次 CI 构建，比"某个号到底对应哪一版"说不清
便宜得多；而 Release 资产是要被刷进真机的，号与内容必须一一对应，
否则"我这台机器上跑的是哪一版"就永远无法回答。

发现刚发布的版本有问题时的标准动作：

1. 立刻 `gh run cancel <run-id>` 掐掉正在跑的、已知会产出坏制品的构建（省 runner 时间）；
2. 提交修复并推送；
3. **开新版本号**重新发布；
4. 在**新版本**的说明里写明旧版本为什么作废（旧版本自身的说明不要再改）。

作废的旧 Release 先留着，删除统一放到最后的清理轮次，并先跟用户确认清单（§1.3）。

### 3.5 开发中的版本：正式号后面加时间戳

**在一个目标版本（比如 `v0.9.4`）真正成功之前，中间所有尝试都用带时间戳的号：**

```
v0.9.4.<YYYYMMDDHHmm>      例：v0.9.4.202608301437
```

规则：

- 中间版本一律是 **Pre-release**，用来跑 CI、下载、真机验证；
- **只有最终验证通过、要对外正式发布的那一次，才用干净的 `v0.9.4`**；
- 时间戳用本地时间 `%Y%m%d%H%M`（12 位，可排序、无歧义）；
- 发现中间版本有问题 → 修 → **再开一个新的时间戳号**，同样不回头改；
- 正式版 `v0.9.4` 的说明里要交代「经过哪几个时间戳版本才收敛」以及各自踩了什么坑。

这样做的好处：`v0.9.4` 这个名字**永远只对应那个验证通过的、能刷进真机的版本**，
不会有人拿到一个"v0.9.4 但是坏的"。而中间的失败尝试也全部留痕，可回溯。

**Why**：本项目的制品会被刷进真机，而真机只有一根 USB 线可救（§7）。
版本号与内容一旦对不上，"这台机器跑的是哪一版"就无从判断，排障成本极高。

---

## 4. 文档与提交规范

### 4.1 提交信息：Conventional Commits + 长中文正文

前缀小写：`fix:` / `docs:` / `feat:` / `perf:` / `chore:`（偶带作用域如 `fix(CI):`）。

本仓库最鲜明的风格是**正文很长**，逐条列出「真因 / 修法 / 实测证据」。不要写"修复了 bug"这种空话，
要写清楚：真正的原因是什么（往往是第二层原因）、改了哪几处、实测看到了什么（md5、字节数、dmesg、`/sys` 节点值）。

错误结论要在提交里**显式更正**（先例：`7d42dc4` 更正"设备无 RTC"、`a3dc9eb` 更正"无蜂窝基带"）。

### 4.2 reports/ 编号必须连续

格式 `NNN-标题.md`，**001 起连续，不得跳号**。
先例：提交 `6a3575b` 专门把 `022` 改回 `019`（"022 是我随手起的，跳过了 019/020/021"）。
新报告先 `ls reports/` 看当前最大编号。

报告可以被后续报告推翻，且**要明确记录推翻关系**（如 `README.md:38` 指出 reports/010 推翻了早先认知）。

### 4.3 WORKLOG.md 是追加式流水账，不要重写

条目格式：`- **HH:MM T<n> 完成** — 一句话结论`，下挂 `- 要点` 与 `**踩坑**：…`。
大节用中文数字编号。只追加，不整理、不删除。
（注：现有 `:512`、`:570`、`:572` 处"拾肆"编号重复了，是历史遗留，不必特意去修。）

---

## 5. 可复现性边界（实测结论，别被表象骗了）

| 产物 | 结论 |
|---|---|
| **DTB** | **逐字节一致（md5 相同）—— 真正可复现** |
| **lk2nd** | 尺寸一致，**md5 不同** |
| **内核 / 模块** | 尺寸一致，**md5 不同** |
| rootfs 镜像 | 含时间戳/machine-id 等天然变量，不做逐字节比对 |

lk2nd 差 376 字节 payload，但因 2048 字节页对齐填充，**总大小一模一样** →
**只看 `ls -l` 会误以为复现成功，必须比 md5**。
根因：本地与 `ubuntu-latest` 的 `gcc-arm-none-eabi` / `gcc-aarch64-linux-gnu` 版本不同。

---

## 6. 改代码前先确认落点

- **用户态组件**（脚本、udev 规则、systemd unit、extlinux.conf）→ 改 `dist/build/rootfs/` 下的源码，
  由 `apply-staging-fixes.sh` 幂等部署。**不要直接改镜像内或 staging 目录里的文件。**
- **设备树** → 改 `dts/*.dts`；完整版由 `patches/0007` 提供。
- **内核** → 改 `patches/`。改了补丁内容，CI 的 ccache 键会失效（键里含 `hashFiles('patches/*.patch')`，
  这是刻意的，不为命中率牺牲正确性）。
- 镜像打包参数 → `tools/build-image.sh`（lk2nd 的 ext2 驱动只接受 `ro_compat ⊆ {sparse_super, large_file}`，
  mke2fs 参数不能随便动）。

---

## 7. 真机安全红线

摘自 `WORKLOG.md:16-22`，**不突破**：

1. **不对真机做任何刷写**（`fastboot flash` 一律不做），除非用户单独、明确地要求。
2. 真机改动分两级：
   - **可逆**：`/etc`、`/usr/local/sbin`、`/etc/systemd` 下的用户态文件 —— 改前备份成 `*.odin-bak`；
   - **不可逆**：替换 `/boot` 里的 DTB、或改 `extlinux.conf` 的 `default` 并重启 —— **必须先跟用户单独确认**。
3. 真机当前是**唯一 SSH 生命线**，任何可能导致重启后失联的操作都视为高风险。

---

## 8. 已知历史坑

- 仓库远程名有拼写错误 **`samrtisan`**（应为 `smartisan`）—— 上游既定事实，**不要顺手改**。
- `README.md:16`、`:58` 仍用旧仓库名 `odin-port/` 指代本仓库目录，是 stale 引用。
- `.gitignore:27` 声明忽略 `dist/stage/modules/`，但其中两个文件**已在 git 索引里**（先跟踪后加规则）。
- `odin-qemu/Image` 是另一个内核（defconfig virt 变体），**不代表真机内核**。
- `setup-rootfs.sh:5` 默认 `ODIN_ROOTFS=/mnt/debian`（陈旧 staging），手工跑**必须显式覆盖**。
- `dts/build-dtb.sh:29-31`：dtc 1.6.x 不认 `-Wno-interrupt_map`，脚本已做版本识别。
