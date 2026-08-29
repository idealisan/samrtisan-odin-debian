# 文档导航

Smartisan U2 Pro（ODIN，msm8953 / SDM450）主线 Linux 6.19 + Debian 12 (bookworm) 移植项目
的使用说明。

| 文档 | 内容 |
|---|---|
| [01-复现构建.md](01-复现构建.md) | 从零重建全部产物：钉死的外部依赖（内核 / lk2nd / Debian）、本地五步手工构建、CI 流水线、**可复现性的边界** |
| [02-刷入指南.md](02-刷入指南.md) | 从原生 fastboot 到 SSH 可用：`flash/flash-all.sh` 的 00→90 阶段、远程进 fastboot 的原理、双 label 引导 |
| [03-系统使用.md](03-系统使用.md) | 日常用法：WiFi（`nmcli`）、网络管理与两个实测坑、U 盘自动挂载、USB 救援通道 |

## 我该看哪一篇？

- **想自己编一份镜像** → [01](01-复现构建.md)。推荐直接发一个 pre-release 走 CI，
  本地跑一遍要有 arm64 交叉工具链 + 能 chroot 的 Linux 环境。
- **手上有一台要刷的机器** → [02](02-刷入指南.md)。**先看完开头的备份一节** ——
  刷 userdata 会清空手机全部数据。
- **机子已经跑起来了** → [03](03-系统使用.md)。

## 三条最重要的事

1. **刷 userdata 会清空设备全部数据**，先跑 `flash/stages/10-backup.sh`。
2. **首刷默认进 `l0-safe`**（USB 固定 device、无 OTG，但 SSH 一定可用）。
   确认整机可用后再 `sudo sed -i 's/^default .*/default l0/' /extlinux/extlinux.conf && sudo reboot`。
3. **不要删 `/etc/NetworkManager/conf.d/99-odin-usb0.conf`**，否则 NM 会清掉
   `usb0` 的 `172.16.42.1`，SSH 失联。

## 仓库里的其它资料

| 位置 | 内容 |
|---|---|
| `README.md` | 补丁清单、多面板自动选择机制、USB 外接存储链路、已知限制 |
| `WORKLOG.md` | 按时间的工作日志，含大量实测记录与踩坑 |
| `reports/` | 各类分析报告；`018-真机刷入循环操作手册.md` 是刷机状态机与救援的权威参考 |
| `dist/FLASH.md` | 早期版本的刷入指南（历史产物，以 `docs/` 为准） |
| `dist/build/rootfs/` | 用户态组件的源码（改这里，不要直接改镜像内文件） |
| `tools/ci/` | 五个复现构建脚本 |
| `.github/workflows/release-build.yml` | Release 触发的构建流水线 |

## 二进制产物在哪

仓库**只放源码与文档**，刷机镜像、lk2nd 固件、DTB、内核模块一律作为
**GitHub Release 资产**发布，到仓库的 Releases 页面下载。
`docs/` 三篇讲的是"怎么把这些东西造出来"和"怎么用"。
