#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
# 根目录可覆盖：CI 里不在 /mnt/debian，而是 debootstrap 到工作区下的某个目录
R=${ODIN_ROOTFS:-/mnt/debian}
[ -d "$R/etc" ] || { echo "不是 rootfs 目录: $R" >&2; exit 1; }

# --- user & sudo (幂等：重跑时用户已存在则跳过) ---
chroot $R id -u user >/dev/null 2>&1 || chroot $R useradd -m -s /bin/bash -G sudo user
echo "user:user" | chroot $R chpasswd
echo "root:*" | chroot $R chpasswd -e   # lock root password login

# --- base system identity ---
echo odin > $R/etc/hostname
sed -i "s/^127.0.1.1.*/127.0.1.1\todin/" $R/etc/hosts 2>/dev/null || echo "127.0.1.1	odin" >> $R/etc/hosts
cat > $R/etc/fstab << 'FSTAB'
/dev/disk/by-label/pmOS_root  /     ext4  defaults,noatime,errors=remount-ro  0 1
tmpfs                         /tmp  tmpfs defaults,nosuid                       0 0
FSTAB

# --- ensure udev is installed (provides systemd-udevd, rules, net naming) ---
chroot $R apt-get update -qq
chroot $R apt-get install -y -qq udev

# marker for initramfs fallback scan
touch $R/.odin-debian

# --- ssh: allow password auth ---
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' $R/etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'            $R/etc/ssh/sshd_config
mkdir -p $R/run/sshd

# --- serial console getty ---
chroot $R systemctl enable serial-getty@ttyMSM0.service

# --- usb 角色切换（device=usb0+dnsmasq / host=OTG） ---
# 注意（reports/014、015）：旧版是 set -e 的一次性 gadget 脚本，开机那一刻 UDC
# 不在就永久 failed，之后再插线也不会恢复 ⇒ SSH 救援通道丢失。
# 现在统一走 odin-usb-role.sh：幂等、先空后名、任何分支 exit 0，外加 30s 看门狗。
# 脚本本体与 udev 规则的源在 dist/build/rootfs/（改那里，别改这里）。
HERE="$(cd "$(dirname "$0")" && pwd)"
install -D -m 0755 "$HERE/rootfs/usr/local/sbin/odin-usb-role.sh" \
	"$R/usr/local/sbin/odin-usb-role.sh"
install -D -m 0644 "$HERE/rootfs/etc/udev/rules.d/99-odin-usb-role.rules" \
	"$R/etc/udev/rules.d/99-odin-usb-role.rules"
install -D -m 0755 "$HERE/rootfs/usr/local/sbin/odin-mount-opts.sh" \
	"$R/usr/local/sbin/odin-mount-opts.sh"
install -D -m 0644 "$HERE/rootfs/etc/udev/rules.d/99-odin-automount.rules" \
	"$R/etc/udev/rules.d/99-odin-automount.rules"
install -D -m 0644 "$HERE/rootfs/extlinux/extlinux.conf" "$R/extlinux/extlinux.conf"
for d in msm8953-smartisan-odin msm8953-smartisan-odin-norolesw; do
	[ -f "$HERE/../../dts/$d.dtb" ] && \
		install -D -m 0644 "$HERE/../../dts/$d.dtb" "$R/boot/dtbs/qcom/$d.dtb"
done

cat > $R/etc/systemd/system/odin-usb-gadget.service << 'UNIT'
[Unit]
Description=ODIN USB role switch (device=usb0+dnsmasq / host=OTG)
After=systemd-modules-load.service
Before=network.target sshd.service
[Service]
Type=oneshot
# 注意：这里**故意不写** RemainAfterExit=yes。
# 原因（真机实测踩到）：写了之后 unit 执行完永不转为 inactive，而本 unit 的看门狗
# 用的是 OnUnitActiveSec=30s —— 它依赖 unit 的激活周期来排下一跳；unit 一直是 active
# 时，systemd 252（Debian 12）不会重新排期 ⇒ timer 触发一次就再也不触发了
# （实测：LastTriggerUSec 停在开机后 25.8s，TimersMonotonic 里 next_elapse=0）。
# 不写 RemainAfterExit 则每次跑完转 inactive，OnUnitActiveSec 才能正确排期。
# 副作用只是 systemctl status 显示为 inactive，不影响功能。
# 脚本内部保证任何分支都 exit 0；失败只留日志，由 .timer 看门狗重试。
ExecStart=/usr/local/sbin/odin-usb-role.sh
# dnsmasq 已独立成 odin-dnsmasq@.service，不在这个 cgroup 里；
# 显式写 process 是免得以后再有人往这里塞后台进程时被连带杀掉。
KillMode=process
[Install]
WantedBy=multi-user.target
UNIT
cat > $R/etc/systemd/system/odin-usb-gadget.timer << 'TIMER'
[Unit]
Description=ODIN USB role watchdog (self-healing every 30s)
[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
# 日历式兜底：OnUnitActiveSec 依赖 unit 的激活周期，一旦 unit 状态异常
# （例如被 RemainAfterExit 钉在 active）就不会重排 ⇒ 看门狗静默失效。
# 加一条 OnCalendar 保证无论如何都会周期性重排，宁可多跑一次也别漏。
OnCalendar=*:0/1
AccuracySec=1s
[Install]
WantedBy=timers.target
TIMER
chroot $R systemctl enable odin-usb-gadget.service odin-usb-gadget.timer

# --- first-boot resize to fill userdata ---
# 关键（reports/013）：成败都要落标记并自禁用。旧版用 `脚本 && touch marker`，
# 一旦 resize2fs 失败就既不落标记也不 disable，导致每次开机都挂一个 failed 单元。
cat > $R/usr/local/sbin/odin-firstboot-resize.sh << 'RESIZE'
#!/bin/bash
# 一次性把根分区扩到 userdata 实际大小；结果只记日志，不以退出码影响 unit 语义
LOG=/var/log/odin-resize.log
ROOTDEV=$(findmnt -n -o SOURCE /)

case "$ROOTDEV" in
  /dev/dm-*|/dev/mapper/*)
    echo "$(date -Is) skip: mapped device $ROOTDEV" >> "$LOG"; exit 0 ;;
esac

DISK=$(dirname "$ROOTDEV" | sed 's|/dev$||;s|^$|/dev|')/$(basename "$ROOTDEV" | sed -E "s/p?[0-9]+$//")
PART=$(basename "$ROOTDEV" | grep -oE "[0-9]+$")

{
  echo "=== $(date -Is) resize start: dev=$ROOTDEV disk=$DISK part=$PART ==="
  echo "--- before ---"
  df -h /
} >> "$LOG" 2>&1

growpart "$DISK" "$PART" >> "$LOG" 2>&1 \
  || echo "$(date -Is) growpart skipped/failed rc=$?" >> "$LOG"

resize2fs "$ROOTDEV" >> "$LOG" 2>&1
rc=$?
{
  echo "$(date -Is) resize2fs rc=$rc"
  echo "--- after ---"
  df -h /
  echo "=== resize end ==="
} >> "$LOG" 2>&1

exit 0
RESIZE
chmod +x $R/usr/local/sbin/odin-firstboot-resize.sh
cat > $R/etc/systemd/system/odin-firstboot-resize.service << 'UNIT2'
[Unit]
Description=Grow root filesystem to fill userdata (one-shot)
After=local-fs.target
ConditionPathExists=!/var/lib/odin-resize-done

[Service]
Type=oneshot
TimeoutStartSec=300
# 无论扩容成败都落标记并自禁用：失败只留日志，不留每开机都 failed 的单元
ExecStart=/bin/sh -c '/usr/local/sbin/odin-firstboot-resize.sh; \
  systemctl disable odin-firstboot-resize.service; \
  touch /var/lib/odin-resize-done; exit 0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT2
# 发布镜像里绝不能带这个标记，否则 ConditionPathExists 会永久跳过扩容
rm -f $R/var/lib/odin-resize-done
chroot $R systemctl enable odin-firstboot-resize.service

# --- locale & misc ---
echo "en_US.UTF-8 UTF-8" > $R/etc/locale.gen
chroot $R locale-gen >/dev/null 2>&1 || true
chroot $R systemd-machine-id-setup 2>/dev/null || true

# --- 时区：默认新加坡（UTC+8）---
# 时区**无法靠联网可靠校正**：网络只能校到 UTC（NTP 给的就是 UTC），本地偏移得靠
# IP 地理定位之类的外部服务，既不稳定又要额外依赖。所以直接给一个明确的默认值。
# tzdata 属于 required 优先级，debootstrap minbase 会带上，/usr/share/zoneinfo 齐全。
# 要改：sudo timedatectl set-timezone <时区>  或  sudo dpkg-reconfigure tzdata
echo "Asia/Singapore" > $R/etc/timezone
rm -f $R/etc/localtime
ln -sf /usr/share/zoneinfo/Asia/Singapore $R/etc/localtime

# --- WiFi management (equivalent to postmarketOS: NetworkManager + wpa) ---
sed -i 's/ main$/ main contrib non-free non-free-firmware/' $R/etc/apt/sources.list
chroot $R apt-get update -qq
# 网络工具：按"正常 Debian 服务器"的标准装齐（ping/curl/dig/tcpdump/iperf 等）。
# systemd-resolved 是为了 DNS 容错：实测某些路由器广播的 DNS 并不应答，
# 有 resolved 才会按顺序尝试后续服务器（这次实机就撞上了这个坑）。
# systemd-timesyncd 解决无 RTC 导致的时钟错乱 —— 时钟差几个月时 apt 会直接
# 拒绝 Release 文件（"Release file ... is not valid yet"）。
# kmod 提供 /sbin/modprobe。它不是 debootstrap minbase 的一部分，但项目里
# 有多处依赖它：odin-usb-role.sh 加载 configfs、/etc/modules-load.d/*.conf
# 也要靠它。缺了不会报错（这些调用都带 2>/dev/null），
# 只会静默失效 —— 实测真机上 command -v modprobe 为空，确认缺失。
chroot $R apt-get install -y -qq \
	kmod \
	network-manager wpasupplicant iw wireless-tools rfkill firmware-atheros \
	iputils-ping curl wget bind9-dnsutils net-tools traceroute tcpdump \
	iperf3 ethtool mtr-tiny \
	systemd-resolved systemd-timesyncd \
	nftables 2>&1 || echo "[setup-rootfs] WARN: 部分网络包装不上，继续"
chroot $R systemctl enable NetworkManager.service
chroot $R systemctl enable wpa_supplicant.service 2>/dev/null || true

# --- USB 救援通道保护（reports/013 的 P0-2） ---
# /etc/network/interfaces 不存在 ⇒ Debian 默认 [ifupdown] managed=false 保护不到
# usb0 ⇒ NM 会按普通以太网自动连接并清掉 gadget 配置的 172.16.42.1，
# 无屏设备将只剩 UART 可用。unmanaged-devices 是 NM 官方机制，最小侵入。
mkdir -p $R/etc/NetworkManager/conf.d
cat > $R/etc/NetworkManager/conf.d/99-odin-usb0.conf << 'NMC'
# usb0 由 odin-usb-gadget.service 静态配置（172.16.42.1 + dnsmasq 给 PC 172.16.42.2）。
# 必须排除在 NetworkManager 之外，否则 NM 接管后会清掉该地址，导致 USB 网络/SSH 通道失效。
[keyfile]
unmanaged-devices=interface-name:usb0
NMC
# 首启已有扩容/日志压力，别再被 network-online 的 90s 超时拖慢
chroot $R systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
# 蜂窝网络（移动数据）：本设备**有**基带，不是没有硬件。
#   - SoC 是骁龙 626（MSM8953 Pro），基带是 msm8953 的 MSS
#   - 固件在原厂 modem 分区（mba.mbn + modem.mdt + modem.b00~b20，约 43MB）
#   - 主线 qcom_q6v5_mss.c 有 msm8953 专门分支，Fairphone 3（同为 msm8953）是成功先例
#   - 工具链走 QRTR（不是串口扫描），ModemManager / qmicli 都可装
# 那为什么还 mask 掉 ModemManager？
#   因为这条链路在 6.19 + 我们的 odin DTB 上**尚未实机验证**（DTS 里的 &mpss 还是
#   上游默认的 disabled，WiFi 当初就是这么被挡住的）。在验证通过之前不默认启用，
#   免得开机多一个必然会失败的探测。想试的人：装 tqftpserv + rmtfs、在 DTS 里启用
#   &mpss（需 pll-supply = <&pm8953_l7>）、unmask ModemManager，然后看 dmesg 与 mmcli。
chroot $R systemctl mask ModemManager.service 2>/dev/null || true

# --- WiFi 固件与校准数据（原厂分区 → /lib/firmware） ---
# wcn36xx 要两样东西，都不在任何 Debian 包里，也不该进版本库：
#   1. WCNSS 固件 wcnss.mdt + .b00/.b01/... ← modem 分区的 /image/
#   2. 板级射频校准数据 WCNSS_qcom_wlan_nv.bin ← persist 分区
# （实测：modem:/image/wcnss.* 与此前手工预置的固件十个文件 md5 全等，
#   所以"开机现取"与"预置"完全等价，还省掉了往仓库塞二进制）
#
# 这件事由 **initramfs** 做（dist/build/initramfs/sbin/odin-wlan-fw.sh），
# 不在用户态做任何 late service —— 时序上放晚了就永远差一步：
# 内核的 qcom_wcnss_pil 约在开机 10s 就 request_firmware("wcnss.mdt")，
# 而 systemd 的 late service 要到 25s 之后才跑，那时 remoteproc 已经停在
# offline，补上文件也不会自己重试。详见 reports/021。
# 只有 stage 里确实缺文件时，initramfs 才会把根临时挂为 rw 去取。
#
# wcn36xx / qcom_wcnss_pil 是模块，靠 udev 在 platform 设备出现时加载，
# 这里显式列进 modules-load 更稳（不依赖时序）
# 目录不是必然存在：/etc/modules-load.d 是 kmod 提供的，而 debootstrap
# minbase 只装 required 优先级的包，kmod 不在其中
mkdir -p "$R/etc/modules-load.d"
echo -e "wcn36xx\nqcom_wcnss_pil" > "$R/etc/modules-load.d/odin-wlan.conf"

# --- enable ssh ---
chroot $R systemctl enable ssh.service
echo SETUP_DONE
