# AGENTS.md — odin-work 工作准则

本文件是**给 AI agent 看的规则**，每次会话都会被加载，因此刻意只保留**规则 + 指针**。
细节（怎么做、为什么）一律放 `docs/05-构建与发布.md`，需要时再去读，不要往本文件里加。

开工前必读：本文件 §1（铁律）与 §7（真机安全红线）。

---

## 0. 项目一句话

坚果 **U2 Pro（Smartisan ODIN，msm8953/SDM450）** 的
**主线 Linux 6.19 + Debian 12 bookworm(arm64)** 移植工作区。
真机已点亮屏幕、USB 网络/SSH 稳定、WiFi 打通；当前阶段是**可复现性与发布工程**。

仓库**只放源码与文档**；二进制产物（镜像、lk2nd、DTB、.ko）不入库，
统一作为 **GitHub Release 资产**发布。

当前基线：**v0.9.3**（首个真机验收 16/16 全通过的正式版）。

---

## 1. 铁律（用户拍板，不得变通）

1. **每个命令前用 `date` 打时间戳**：
   `date '+[%F %T] 开始:<动作>' && <命令> ; date '+[%F %T] 结束:<动作>'`
   长耗时命令必带，短查询至少开头带一次。**适用于所有 subagent。**
   目的：事后可判耗时、卡死时能对照、能发现异常耗时的步骤。

2. **完成一点工作就立即 commit + push**，不要攒着。理由：防工作丢失。

3. **只增不删**：禁止 `rm` / `git clean` / `git gc --prune` 等删除与清理操作。
   需要"只留一部分"时**复制**到 `tmp/` 再排除不需要的；需要保留旧版本就原地复制成
   `*.odin-bak`。**所有清理统一留到最后，经用户确认清单再执行。**

4. **制品一律以 CI 构建为准**。本地构建、直接改目标环境（真机/镜像内/staging）的文件
   都只是开发尝试，可以用来探路、验证假设，但**不能据此确认"已修好"**。

5. **项目自包含**：只依赖本文件夹 + 在线仓库。
   不再依赖 `/Volumes/caseSensitiveBar/linux-msm8953`、`odin-port/`、`refs/`、
   `pmaports/`、容器内 `/mnt/debian` 等历史位置。新增脚本的默认路径不得指向仓库外。

6. **临时文件放本文件夹的 `tmp/`**，不用 `/tmp`、`$TMPDIR`。按任务建子目录。

7. **任何联网 IO 一律走后台任务**，状态检查用 **≤15 秒短轮询**，不要分钟级长等待。
   （git push/pull、`gh`、curl/wget、apt/pip、debootstrap、Release 上传…）

8. **需要用户动手时，用 `say` 语音提醒**：
   `say -v 'Ting-Ting' "<要他做什么>"`
   用户在旁边但不是一直盯着屏幕，听到就会过来操作。
   **凡是需要人工介入的时刻都要喊**（按住电源键进 fastboot、看屏幕读报错、
   回答选择题…），不要只在文字里等。

> 补充：从 GitHub 下大文件要**显式去代理**（`env -u http_proxy -u https_proxy`），
> 快 4.7 倍。详见 `docs/05` 第五节。

---

## 2. 目录地图

| 路径 | 内容 |
|---|---|
| `Makefile` | **构建入口** | `make help` / `make all`，见 `docs/05` |
| `tools/ci/` | 2 个构建脚本（取内核、装 rootfs） | 其余构建步骤已迁进 Makefile |
| `tools/` | 镜像导出、打包、校验 |
| `patches/` | 内核补丁 0001–0008 |
| `lk2nd/` | lk2nd 补丁 0001–0004 + 设备树 |
| `dts/` | 设备树源码与 `build-dtb.sh` |
| `dist/` | 刷机包与**用户态组件源码**（`dist/build/rootfs/` 是唯一该改的地方） |
| `flash/` | `flash-all.sh` 阶段状态机（00→90），支持 `--from` 与 `--dry-run` |
| `odin-qemu/` | QEMU 回归台（**只能验用户态**） |
| `evidence/` | 真机取证数据 |
| `reports/` | 专题报告 001–021，编号必须连续 |
| `docs/` | 正式文档；`docs/04-排障.md` 优先于翻 WORKLOG |
| `WORKLOG.md` | 流水账，**追加式**，不要重写 |
| `tmp/` | 临时工作区（git 忽略） |

---

## 3. 构建与发布（细节见 `docs/05-构建与发布.md`）

**入口：`make`**（不要再手敲 `bash tools/ci/*.sh`）。常用：
`make help`、`make dtb`、`make kernel`、`make lk2nd`、`make rootfs`、`make clean`。

- **能写成直线命令的写进 Makefile，有真逻辑的留脚本**：
  dtb / kernel / lk2nd 已在 Makefile 里；`fetch-kernel`（三级回退重试）、
  `build-rootfs`（debootstrap 流水线）、`build-image`（20+ 项校验）仍是脚本。
- CI 也走 make（rootfs 那个 job 用 `-o kernel -o dtb` 表示"产物来自 artifact，别重编"）。
- CI 只在 `release: [prereleased, released]` 与 `workflow_dispatch` 触发。

三个钉死的外部输入：

| 项 | 值 |
|---|---|
| 内核 commit | `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b` |
| lk2nd | `23.1` |
| Debian | `bookworm` |

**版本号**：严格递增、永不重用或修改；小修直接递增 patch 号。
开发中用 `v0.9.4-<简述>` 后缀（如 `-lk2nd-reboot`），只有最终通过才用干净的 `v0.9.4`。
完整规则与出事后的标准动作见 `docs/05` 第三节。

---

## 4. 文档与提交规范

- **提交信息**：Conventional Commits（小写前缀 `fix:` / `docs:` / `feat:` /
  `perf:` / `chore:`，偶带作用域如 `fix(CI):`）+ 长中文正文。
  正文要写**真因 / 修法 / 实测证据**（md5、字节数、dmesg、`/sys` 节点值），
  不要写"修复了 bug"。错误结论要在提交里**显式更正**。
- **reports/ 编号必须连续**（`NNN-标题.md`，001 起不跳号）。报告可被后续报告推翻，
  但要明确记录推翻关系。
- **WORKLOG.md 是追加式流水账**，条目格式 `- **HH:MM T<n> 完成** — 一句话结论`，
  下挂 `- 要点` 与 `**踩坑**：…`。只追加，不整理。

---

## 5. 可复现性边界

| 产物 | 结论 |
|---|---|
| DTB | **逐字节一致，真正可复现** |
| lk2nd / 内核 | 尺寸一致，**md5 不同** |

⚠️ lk2nd 差约 376 字节但被 2048 字节页对齐填充掩盖，**只看 `ls -l` 会误判，必须比 md5**。
详见 `docs/05` 第四节。

---

## 6. 改代码前先确认落点

- 用户态组件（脚本 / udev 规则 / systemd unit / extlinux.conf）→ 改 `dist/build/rootfs/`
- 设备树 → 改 `dts/*.dts`（完整版由 `patches/0007` 提供）
- 内核 → 改 `patches/`
- 镜像打包参数 → `tools/build-image.sh`
- **固件要在驱动索取它之前就位 ⇒ 落在 initramfs 的 `switch_root` 之前，
  不是 late systemd service。规范见 `reports/021-固件与驱动的供给策略.md`。**

---

## 7. 真机安全红线（不突破）

1. **不对真机做任何刷写**（`fastboot flash` 一律不做），除非用户单独、明确要求。
2. 改动分两级：
   - **可逆**：`/etc`、`/usr/local/sbin`、`/etc/systemd` 下的用户态文件 —— 改前备份成 `*.odin-bak`
   - **不可逆**：替换 `/boot` 里的 DTB、或改 `extlinux.conf` 的 `default` 并重启
     —— **必须先跟用户单独确认**
3. 真机当前是**唯一 SSH 生命线**，任何可能导致重启后失联的操作都视为高风险。

---

## 8. 已知历史坑

见 **`docs/05-构建与发布.md` 第五节**（远程名拼写 `samrtisan` 不要改、
手工改 patch 要同步 hunk 行计数、重刷后要 `ssh-keygen -R`、下载要去代理等）。
