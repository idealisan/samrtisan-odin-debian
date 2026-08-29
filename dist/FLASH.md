# 刷入指南 007 — ODIN Debian 刷机包

| 产物 | 大小 | 用途 |
|------|------|------|
| `lk2nd.img` | 358 KB | 二级引导，刷入 boot 分区 |
| `odin-debian.img` | 2 GiB (raw, 2147483648 B) | 完整系统（Debian rootfs+内核+引导配置），刷入 userdata |
| `odin-debian-sparse.img` | 约 731 MB (731096372 B) | 同上的 sparse 版，**推荐**（fastboot 分块流式传输） |

> 镜像内的根文件系统只有 2 GiB，首次启动由 `odin-firstboot-resize.service`
> 在线扩容到 userdata 实际容量（约 26G+），日志见设备上的 `/var/log/odin-resize.log`。

刷前自检（本机 `md5`/`md5sum`，值随重建批次变化，以仓库最新提交为准）：

```
lk2nd.img              521d64fcb2ab4cf534bac1f9b8440712
odin-debian.img        98482fdbdcd15e6f568c162fda3629ca
odin-debian-sparse.img 见 tools/check_sparse.py 的比对结果（应与 raw 逐字节一致）
```

```sh
python3 ../tools/check_sparse.py odin-debian-sparse.img odin-debian.img   # 期望 IDENTICAL
```

> ⚠️ **刷 userdata 会清空手机全部数据**（照片/应用/聊天记录），先备份！
> 本包不触碰 aboot/modem/persist 等分区；恢复原厂可用线刷包 EDL 全量救砖。

---

## 〇、两个引导 label（首刷前必读）

`/extlinux/extlinux.conf` 里有两条，**内核与 initrd 相同，只有 DTB 不同**：

| label | DTB | 用途 |
|---|---|---|
| `l0-safe`（**首刷默认**） | `msm8953-smartisan-odin-norolesw.dtb` | USB 固定 device 模式，UDC 恒在，SSH 救援通道不依赖 Type-C 角色判定；**代价：完全没有 OTG host** |
| `l0` | `msm8953-smartisan-odin.dtb` | 完整版：Type-C 角色切换 + OTG host |

首刷用 `l0-safe`。拿到 SSH 并确认整机可用后，在系统内执行：

```sh
sudo sed -i 's/^default .*/default l0/' /extlinux/extlinux.conf && sudo reboot
```

若完整版起不来，改回 `default l0-safe` 重启。`/extlinux/` 就在根分区里（本镜像是
单一文件系统，没有独立 boot 分区），改完重启即可。

> **为什么两个 label 都用显式 `fdt` 而不是 `fdtdir`**
> lk2nd 的 QCDT 表里同时存在 `msm8953-smartisan-odin`（board-id `<0x0b 0x01>`）与
> `msm8953-xiaomi-markw`（`<0x1000b 0x01>`）——两者 variant_id 都是 `0x0b`
> （`VARIANT_MASK=0xff`，高位只是 major/minor）。若 lk2nd 把票投给 markw，`fdtdir`
> 会去找镜像里根本不存在的 `msm8953-xiaomi-markw.dtb` 而启动失败。显式 `fdt` 则无论
> lk2nd 选中谁都能起：选中 odin 才有屏，选中 markw 则无屏但 SSH 可用。
>
> **面板占位 compatible `smartisan,odin-panel` 只有在 lk2nd 选中 odin 条目时才会被替换
> 成真实面板** —— 这是屏幕能否点亮的唯一开关，只能真机确认。若实测无屏而 SSH 正常，
> 下一步是精简 lk2nd（只保留 odin 条目）强制命中。

## 〇之二、外置存储（OTG U 盘）

插上即自动挂载到 `/run/media/<设备名>`，由 udev + systemd mount unit 完成（未装 udisks2）。
挂载选项按文件系统分流，见 `/usr/local/sbin/odin-mount-opts.sh`；日志 `/var/log/odin-automount.log`。

| 文件系统 | 用户可直接写 | 中文文件名 | 备注 |
|---|---|---|---|
| **exFAT**（推荐） | ✅ | ✅ | 内核模块 `exfat.ko` 已随镜像，挂载时自动加载 |
| NTFS | ✅ | ✅ | 走 `ntfs-3g`(FUSE)，`ntfsfix` 可用 |
| FAT32 / vfat | ✅ | ❌ 会乱码 | 内核未编 `NLS_UTF8`（不为它重编内核），默认 `iso8859-1` |
| ext4 / btrfs / xfs / f2fs | ❌ 需 `sudo` | ✅ | POSIX 权限，根目录属主是格式化时的用户；`sudo chown` 一次即可持久生效 |

排障：`/usr/local/sbin/odin-automount.sh --dry-run` **不存在**，直接用下面这条查看决策：
`udevadm info -q property -n /dev/sda1 | grep -E "ID_BUS|ID_FS_TYPE|ID_FS_USAGE"`

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
- 先刷 lk2nd 后刷 userdata 的顺序**必须保持**（lk2nd 负责挂载 userdata 找到 `/extlinux/extlinux.conf`）。
- 注意：lk2nd 只有一套 `lib/fs/ext2` 驱动，**只读 ext2 兼容特性集**的文件系统。本镜像据此
  用保守特性集制作（无 extents/64bit/metadata_csum/huge_file/dir_nlink/extra_isize），
  切勿用发行版默认 `mkfs.ext4` 重建根分区，否则 lk2nd 挂载失败、整条引导链不执行。
  （重建配方见 `tools/build-image.sh`。）
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
4. 扩容确认：`df -h /` 应接近 userdata 实际容量（约 26G+）。
   该服务无论成败都会自禁用，所以**不要以服务状态判断成功与否**，要看
   `cat /var/log/odin-resize.log`（含扩容前后 `df` 与 `resize2fs` 返回码）。
   若日志里出现 `No reserved GDT blocks, can't resize` 之类的 EPERM，
   说明镜像特性集被改坏，需用 `tools/build-image.sh` 重建。

## 五、救援通道（SSH 不可用时）

| 通道 | 触发条件 | 用法 |
|------|----------|------|
| **initramfs telnet** | 启动早期每 ~5 秒自动开启；找不到根分区时**常驻** | 主机 `telnet 172.16.42.1`（root shell，无密码）；正常启动成功则窗口极短 |
| 强制驻留 telnet | 在 extlinux.conf 的 append 行加 `odin.telnet=always` | 停在 initramfs shell 不进系统 |
| UART 串口 | 始终 | ttyMSM0 @115200，系统内已启用 serial-getty（user 登录） |

> 系统装了 NetworkManager（管 WiFi）。`usb0` 是 USB 救援通道的命脉，
> 已通过 `/etc/NetworkManager/conf.d/99-odin-usb0.conf` 设为 `unmanaged`——
> **不要删这个文件**，否则 NM 会接管 usb0 并清掉静态地址 172.16.42.1，三条通道里
> 只剩 UART 可用（屏幕在真机上尚未验证过）。验证方式：
> `nmcli device status` 里 usb0 应显示 `unmanaged`。

> ℹ️ **USB 网络的自愈（本次新增）**：`odin-usb-gadget.service` 已改为调用
> `/usr/local/sbin/odin-usb-role.sh` —— 幂等、任何分支都 exit 0（不留 failed 单元）；
> 另有 `odin-usb-gadget.timer` 每 30 秒跑一次作为自愈看门狗，
> 以及 `/etc/udev/rules.d/99-odin-usb-role.rules` 监听 UDC 增删与 Type-C 变化。
> 因此**拔掉再插回 PC 后 USB 网络应当自动恢复**；排障看
> `journalctl -u odin-usb-gadget -f` 与 `/var/log/odin-usb-role.log`。
>
> ⚠️ **首刷仍然务必保持 USB 线连着电脑**，并优先用 `l0-safe`（UDC 不依赖角色判定）。
>
> ⚠️ **已知的回退缺口**：`echo device > /sys/class/usb_role/*/role` 这条手动强制切回
> device 的手段，在实测的 6.17.7 内核上**不可用**（`find /sys -name role` 结果为空，
> 该 sysfs 文件根本不存在）。项目自己的 6.19 内核上是否可用尚未验证。
> 因此回退请优先走"改 `extlinux.conf` 的 `default` 再重启"，或直接用 UART。

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
重建脚本：`odin-port/dist/build/setup-rootfs.sh`（从零构建 rootfs 用）；initramfs 源码：`dist/build/initramfs/init`。

> **重要（reports/013 教训）**：容器里的 `/mnt/debian`、`/mnt/debian-qemu` 是 8/23 的陈旧
> staging，不含后来装进镜像的 NetworkManager 等改动——最近几版镜像是"挂载镜像就地改"出来的。
> 因此**不要直接拿 `/mnt/debian` 重建镜像**，否则会丢失改动。
> 现行流程是：
> ```sh
> # 1) 以当前镜像内容为基线建可写 staging（挂载态复制是历史 bug 的根源，必须先卸载再复制）
> mount -o ro,loop dist/odin-debian.img /mnt/src && cp -a /mnt/src/. /mnt/stage/
> # 2) 应用增量修复（幂等）
> dist/build/apply-staging-fixes.sh /mnt/stage
> # 3) 导出 + 全量校验
> tools/build-image.sh /mnt/stage /mnt/img/odin-debian.new.img 524288 pmOS_root
> ```
> `tools/build-image.sh` 会把干净化（machine-id / random-seed / journal / wtmp）、
> 保守特性集（含 `resize_inode`）、e2fsck、img2simg 与逐项回读校验全部固化。

---
*指南结束 — odin-port 系列 №007*
