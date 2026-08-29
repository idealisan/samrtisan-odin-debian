# 刷机包产物一览（dist/）

> ## 📖 **完整刷机指南见 [../docs/02-刷入指南.md](../docs/02-刷入指南.md)，以 `docs/` 为准。**
>
> 本文件只保留一份"最快上手"，细节、原理与排障一律看 `docs/`。
> 完整文档导航见 [../docs/README.md](../docs/README.md)。

---

## 最快上手（想立刻开刷）

**前提**：bootloader 已解锁、PC 装了 fastboot、电量 >30%、USB **直连**（不要走 hub）。
**⚠️ 刷 userdata 会清空手机全部数据**，先备份：`flash/stages/10-backup.sh`。

```sh
# 1) 进 fastboot：关机后按住【音量减 + 电源键】，或用 flash/flash-all.sh 的 20 阶段远程进
fastboot devices                                   # 确认能看到设备

# 2) 二级引导 → boot 分区
fastboot flash boot lk2nd-nomarkw.img

# 3) 整个 Debian 系统 → userdata 分区
fastboot flash userdata odin-debian-sparse.img     # 报 too large 就改用 odin-debian.img

# 4) 重启（首启含在线扩容，等 1–3 分钟）
fastboot reboot
```

起来后：`ssh user@172.16.42.1`（密码 `user`）。

> **顺序不能反**：先 lk2nd 后 userdata —— lk2nd 负责挂载 userdata 去找
> `/extlinux/extlinux.conf`。
>
> **刷的是 `lk2nd-nomarkw.img`（精简版）**，不是 `lk2nd.img`：精简版去掉了
> `msm8953-xiaomi-markw`，强制 lk2nd 命中 odin 条目，屏幕才会亮。

---

## 产物清单

| 产物 | 大小 | 用途 |
|---|---|---|
| `lk2nd-nomarkw.img` | 约 356 KB | 二级引导（**刷这个**），刷入 boot 分区 |
| `lk2nd.img` | 约 358 KB | 完整版二级引导，保留全部 29 个设备条目；一般不用 |
| `odin-debian-sparse.img` | 数百 MB | 完整系统的 sparse 版，**推荐**（fastboot 分块传输） |
| `odin-debian.img` | 2 GiB raw | 同上 raw 版，sparse 失败时的回退 |

镜像内根文件系统只有 2 GiB，首启由 `odin-firstboot-resize.service` 在线扩容到
userdata 实际容量（实机约 111.9 GiB）。

**下载产物怎么校验** → [docs/01 复现构建 § 五](../docs/01-复现构建.md)

---

## 需要细节时看哪里

| 你想知道 | 看 |
|---|---|
| 阶段脚本、`--from` 重跑、远程进 fastboot 的原理、9 项验收 | [docs/02 § 二～六](../docs/02-刷入指南.md) |
| 双 label（`l0-safe` / `l0`）怎么切、三个不能违反的约束 | [docs/02 § 七](../docs/02-刷入指南.md) |
| 状态判定、故障处理、EDL 救砖 | [docs/02 § 八](../docs/02-刷入指南.md) |
| WiFi / 网络 / U 盘自动挂载 / USB 救援通道 | [docs/03 系统使用](../docs/03-系统使用.md) |
| 面板不亮、DHCP 拿不到地址等具体排障 | [docs/04 排障](../docs/04-排障.md) |
| 怎么从零重建这些产物 | [docs/01 复现构建](../docs/01-复现构建.md) |

---

*本文件原为「odin-port 系列 №007 刷入指南」，内容已并入 `docs/`。*
