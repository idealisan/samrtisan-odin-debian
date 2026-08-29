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
RemainAfterExit=yes
# 脚本内部保证任何分支都 exit 0；失败只留日志，由 .timer 看门狗重试
ExecStart=/usr/local/sbin/odin-usb-role.sh
[Install]
WantedBy=multi-user.target
UNIT
cat > $R/etc/systemd/system/odin-usb-gadget.timer << 'TIMER'
[Unit]
Description=ODIN USB role watchdog (self-healing every 30s)
[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
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

# --- WiFi management (equivalent to postmarketOS: NetworkManager + wpa) ---
sed -i 's/ main$/ main contrib non-free non-free-firmware/' $R/etc/apt/sources.list
chroot $R apt-get update -qq
# 网络工具：按"正常 Debian 服务器"的标准装齐（ping/curl/dig/tcpdump/iperf 等）。
# systemd-resolved 是为了 DNS 容错：实测某些路由器广播的 DNS 并不应答，
# 有 resolved 才会按顺序尝试后续服务器（这次实机就撞上了这个坑）。
# systemd-timesyncd 解决无 RTC 导致的时钟错乱 —— 时钟差几个月时 apt 会直接
# 拒绝 Release 文件（"Release file ... is not valid yet"）。
chroot $R apt-get install -y -qq \
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
# 本设备无蜂窝基带，ModemManager 只徒增启动开销并会扫描串口
chroot $R systemctl mask ModemManager.service 2>/dev/null || true

# --- WiFi 校准数据（persist 分区 → /lib/firmware） ---
# wcn36xx 要的 WCNSS_qcom_wlan_nv.bin 是每台机器不同的射频校准数据，
# 原厂放在 persist 分区，任何 Debian 包都不提供，也不该进版本库。
# 由 odin-wlan-nv.service 开机现取。
install -D -m 0755 "$HERE/rootfs/usr/local/sbin/odin-wlan-nv.sh" \
	"$R/usr/local/sbin/odin-wlan-nv.sh"
install -D -m 0644 "$HERE/rootfs/etc/systemd/system/odin-wlan-nv.service" \
	"$R/etc/systemd/system/odin-wlan-nv.service"
chroot $R systemctl enable odin-wlan-nv.service 2>&1 | tail -2 || true
# wcn36xx / qcom_wcnss_pil 是模块，靠 udev 在 platform 设备出现时加载，
# 这里显式列进 modules-load 更稳（不依赖时序）
# 目录不是必然存在：/etc/modules-load.d 是 kmod 提供的，而 debootstrap
# minbase 只装 required 优先级的包，kmod 不在其中
mkdir -p "$R/etc/modules-load.d"
echo -e "wcn36xx\nqcom_wcnss_pil" > "$R/etc/modules-load.d/odin-wlan.conf"

# --- enable ssh ---
chroot $R systemctl enable ssh.service
echo SETUP_DONE
