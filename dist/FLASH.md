# 刷入指南 007 — ODIN Debian 刷机包

| 产物 | 大小 | 用途 |
|------|------|------|
| `lk2nd.img` | 358 KB | 二级引导，刷入 boot 分区 |
| `odin-debian.img` | 1.13 GB (raw) | 完整系统（Debian rootfs+内核+引导配置），刷入 userdata |
| `odin-debian-sparse.img` | 646 MB | 同上的 sparse 版，**推荐**（fastboot 分块流式传输） |

> ⚠️ **刷 userdata 会清空手机全部数据**（照片/应用/聊天记录），先备份！
> 本包不触碰 aboot/modem/persist 等分区；恢复原厂可用线刷包 EDL 全量救砖。

---

## 一、前提

1. 手机已解锁 bootloader（原厂 fastboot 模式下执行过解锁；未解锁先在原厂系统内申请并解锁）。
2. PC 安装 fastboot（macOS: `brew install android-platform-tools`）。
3. 手机电量 >30%。

## 二、进入 fastboot 模式

- 系统可开机时：`adb reboot bootloader`
- 关机状态：按住 **音量减 + 电源键**（原厂组合）→ 出现 fastboot 屏幕后松手
- 验证：`fastboot devices` 应列出设备

## 三、刷写（两条命令）

```sh
cd odin-port/dist

# 1) 二级引导 → boot 分区(64M)
fastboot flash boot lk2nd.img

# 2) 整个 Debian 系统 → userdata 分区(~27G)
fastboot flash userdata odin-debian-sparse.img
# 若报 download 太大/传输中断, 改用: fastboot flash userdata odin-debian.img

# 3) 重启
fastboot reboot
```

说明：
- 先刷 lk2nd 后刷 userdata 的顺序**必须保持**（lk2nd 负责解析 userdata 里的 ext4 找到引导配置）。
- sparse 版由 fastboot 自动分块传输；raw 版一次下载，若超过设备 max-download-size 会失败。
- 之后每次重刷系统只需重复第 2 步；boot 分区的 lk2nd 无需再动。

## 四、首次启动与登录

1. 插 USB 线连接电脑，等待 **1–3 分钟**（首次启动含文件系统扩容）。
2. 电脑网络列表出现新以太网网卡（USB NCM）。若未自动获取 IP：
   ```sh
   sudo ifconfig enX inet 172.16.42.2/24    # macOS, enX 为新网卡名
   ```
   设备侧固定为 **172.16.42.1**（pmOS 同款约定）。
3. SSH 登录：
   ```sh
   ssh user@172.16.42.1      # 密码: user, 已在 sudo 组
   ```
4. 扩容确认：`df -h /` 应接近 userdata 实际容量（约 26G+）；
   `systemctl status odin-firstboot-resize` 显示 inactive(dead) 即已成功执行并自禁用。

## 五、救援通道（SSH 不可用时）

| 通道 | 触发条件 | 用法 |
|------|----------|------|
| **initramfs telnet** | 启动早期每 ~5 秒自动开启；找不到根分区时**常驻** | 主机 `telnet 172.16.42.1`（root shell，无密码）；正常启动成功则窗口极短 |
| 强制驻留 telnet | 在 extlinux.conf 的 append 行加 `odin.telnet=always` | 停在 initramfs shell 不进系统 |
| UART 串口 | 始终 | ttyMSM0 @115200，系统内已启用 serial-getty（user 登录） |

telnet 内常用救援命令示例：
```sh
mount -t ext4 /dev/mmcblk0pNN /mnt   # 手动挂根检查
cat /proc/cmdline; findfs LABEL=pmOS_root
```

## 六、故障排查

| 现象 | 排查 |
|------|------|
| `fastboot flash` 卡住/失败 | 改用 sparse 版；换 USB 口/线；确认非 hub |
| 刷完黑屏无 USB 网卡 | 等 60s 再看；换 USB 网络驱动（macOS 看 `ifconfig` 新 enX）；接串口看日志 |
| lk2nd 菜单音量-/电源异常 | 见报告003；不影响本流程（PC fastboot 操作即可绕过菜单） |
| 屏幕不亮但 SSH 可用 | 预期内（面板驱动待实机验证），SSH 进去 `dmesg \| grep -iE "dsi\|panel"` 反馈日志 |
| 彻底变砖 | 高通 9008 EDL 模式：按住音量上+下插线 → 用原厂线刷包目录内 `edl-flash.sh` 全量恢复 |

## 七、构建复现

容器 `odin-build`（debian:bookworm arm64）保留在 Docker 中：
```sh
docker start odin-build          # 继续使用
docker exec -it odin-build bash  # rootfs 位于容器 /mnt/debian
docker rm -f odin-build          # 清理
```
重建脚本：`odin-port/dist/build/setup-rootfs.sh`；initramfs 源码：`dist/build/initramfs/init`。

---
*指南结束 — odin-port 系列 №007*
