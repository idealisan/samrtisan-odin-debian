#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
# 变体：core（无 GUI，服务器 / 开发基线）或 gui（Plasma Mobile 桌面）。
# 由 tools/ci/build-rootfs.sh 从 make 的 ODIN_VARIANT 传下来。
# 两个变体共用同一套基础设施（USB 救援通道、swap、扩容、用户态脚本），
# 差别只在 gui 多装一套桌面 —— core 是它的子集。
ODIN_VARIANT=${ODIN_VARIANT:-core}
say() { printf '[setup-rootfs] %s\n' "$*"; }
# 根目录可覆盖：CI 里不在 /mnt/debian，而是 debootstrap 到工作区下的某个目录
R=${ODIN_ROOTFS:-/mnt/debian}
[ -d "$R/etc" ] || { echo "不是 rootfs 目录: $R" >&2; exit 1; }

# ---------------------------------------------------------------- DNS
# chroot 里必须有能解析域名的 resolv.conf，而且要**在任何 apt 之前**就位。
#
# debootstrap 拷进来的那份会被 systemd-resolved 的 postinst 换成指向
# ../run/systemd/resolve/stub-resolv.conf 的符号链接，而 chroot 里 resolved
# 根本没在跑 ⇒ 那个文件不存在 ⇒ 之后所有 chroot 里的 apt 都报
#     Temporary failure resolving 'deb.debian.org'
# 更隐蔽的是 apt-get update 在这种情况下**仍然返回 0**（只是打几行 W:），
# 于是包索引是空的，等到 install 才冒出满屏 "Unable to locate package" ——
# 报错离真因很远。core 变体碰不到（那之后不再装包），gui 变体必踩。
#
# 做法：拿构建环境的 resolv.conf 顶上；导出镜像前由 build-rootfs.sh 换回符号链接，
# 不能把构建机的 DNS 带进发布镜像。
# 做成函数而不是只做一次：systemd-resolved 的 postinst 在**安装时**还会再换一次，
# 所以每次 apt 之前都要重新确认一遍。
fix_dns() {
	if [ -L "$R/etc/resolv.conf" ] || [ ! -s "$R/etc/resolv.conf" ]; then
		rm -f "$R/etc/resolv.conf"
		cp -f /etc/resolv.conf "$R/etc/resolv.conf"
		say "resolv.conf: 换成构建环境的（chroot 内的 apt 要能解析域名）"
	fi
}
fix_dns

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

# --- 时区：默认 Asia/Shanghai（UTC+8）---
# 时区**无法靠联网可靠校正**：网络只能校到 UTC（NTP 给的就是 UTC），本地偏移得靠
# IP 地理定位之类的外部服务，既不稳定又要额外依赖。所以直接给一个明确的默认值。
# tzdata 属于 required 优先级，debootstrap minbase 会带上，/usr/share/zoneinfo 齐全。
# 要改：sudo timedatectl set-timezone <时区>  或  sudo dpkg-reconfigure tzdata
# （这里原为 Asia/Singapore：同为 UTC+8 但与中国大陆的夏令时/节假日无关，
#   设备在中国大陆使用，改成 Asia/Shanghai 更合适。）
echo "Asia/Shanghai" > $R/etc/timezone
rm -f $R/etc/localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai $R/etc/localtime

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
# 装包失败必须让构建失败：没有 NetworkManager / modprobe / resolved 的镜像是废的，
# 静默继续只会产出一个"看着成功、实际不能用"的制品，等刷进真机才发现。
# 所以这里不吞退出码（原来是 `|| echo WARN`，实测它吞掉过整批失败）。
# util-linux-extra 提供 hwclock。minbase 里没有它，于是真机上连"看一眼 RTC 现在
# 几点"都做不到（实测 `command -v hwclock` 为空）。只能**读**（hwclock -r）：
# 写是不行的 —— 本机的 RTC 不可写，见下面 swclock-offset 那一段。
# 注意：续行里不能再插 # 注释 —— 反斜杠续行会把各行拼成一行，# 之后全被吃掉。
#
# fake-hwclock：本机 RTC **写不了**（pm8xxx 驱动在没有 allow-set-time 时只能读；
# 而加上 allow-set-time 让它真写寄存器，实测 hwclock --systohc 会把整机挂死，
# 进程卡在不可中断状态）。于是每次开机内核从 RTC 读到的都是 1970 年的废值。
# Debian 对"没有可用 RTC 的机器"的标准解法就是这个包：把系统时间存进
# /etc/fake-hwclock.data（0.12 版的默认路径，不是 /var/lib —— 解包核对过
# /sbin/fake-hwclock 里的 FILE 默认值），开机早期（sysinit、fsck 之前）再恢复 ——
# 至少不会一重启就退回 1970。
# 联网时仍以 systemd-timesyncd 的 NTP 为准（fake-hwclock 只是兜底）。
# 存盘时机是包自带的 /etc/cron.hourly/fake-hwclock（每小时）与
# fake-hwclock.service 的 ExecStop（关机）；前者要 cron 才跑得起来，
# minbase 不带 cron，所以一并装上 —— 手机很少干净关机，只靠关机存盘的话
# 一掉电或长按电源硬复位就全丢了。
if ! chroot $R apt-get install -y -qq \
	kmod \
	network-manager wpasupplicant iw wireless-tools rfkill firmware-atheros \
	iputils-ping curl wget bind9-dnsutils net-tools traceroute tcpdump \
	iperf3 ethtool mtr-tiny \
	systemd-resolved systemd-timesyncd util-linux-extra fake-hwclock cron \
	nftables; then
	echo "[setup-rootfs] FATAL: 网络/基础包没装上，构建中止（apt 的完整报错在上面）" >&2
	exit 1
fi
# --- 时钟：本机 RTC 能读不能写，用 Debian 自带的 fake-hwclock 兜底 ---
# 内核侧与 postmarketOS 官方那份 msm8953 配置逐项比对过，RTC 部分完全一致：
# 	# CONFIG_RTC_HCTOSYS is not set
# 	# CONFIG_RTC_SYSTOHC is not set
# 	CONFIG_RTC_DRV_PM8XXX=m
# 即内核不读也不写 RTC —— 因为本机写不了，两条路都是实测不通：
#   · 不加 allow-set-time：rtc-pm8xxx 的 set_time 走 pm8xxx_rtc_update_offset()，
#     它要设备树里名为 offset 的 nvmem cell，本机没有 ⇒ 一律 -ENODEV；
#   · 加上 allow-set-time 让它真写寄存器：hwclock --systohc 会把整机挂死
#     （进程卡在不可中断状态，连设备端的 timeout 都杀不掉）。
#   ⇒ 开机内核从 RTC 读到的永远是 1970 年的废值，只能靠用户态兜住。
#
# 用户态不再照搬 pmOS 的 swclock-offset（把「系统时间 − RTC」的偏差存文件）——
# 既然都是写文件，就用 Debian 自带的 fake-hwclock（存绝对时间）：
#   · fake-hwclock.service 在 sysinit 早期 load，ExecStop 在关机时 save；
#   · load 只在"存的时刻比现在新"时才设，不会把时间往回拨；
#   · 存盘由包自带的 /etc/cron.hourly/fake-hwclock（每小时）+ ExecStop（关机）完成。
# 服务本由包自己的 postinst（deb-systemd-helper enable）启用，这里显式再开一次，
# 免得换包 / 换 debhelper 版本时悄悄失效。
chroot $R systemctl enable fake-hwclock.service
chroot $R systemctl enable cron.service
# 注：bookworm 的 util-linux-extra **没有** hwclock-save.service（解包核对过：
# 它只带 /etc/init.d/hwclock.sh 与 udev 的 hwclock-set，两者开头都是
# `[ -e /run/systemd/system ] && exit 0`，systemd 下压根不会去写 RTC），
# 所以没什么要屏蔽的 —— 之前那句 mask 是照 pmOS 的思路想当然加的，撤掉。
chroot $R systemctl enable NetworkManager.service
chroot $R systemctl enable odin-swap.service 2>/dev/null || true
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

# --- 变体 gui：Plasma Mobile 桌面 ---
# 包清单照搬真机上手工验证过的那套（Plasma Mobile + sddm + 常用工具），
# 不是现编的：手工装过、确认能起来，这里只是把它固化进构建。
if [ "$ODIN_VARIANT" = "gui" ]; then
	say "变体=gui：安装 Plasma Mobile 与配套工具（这步较慢）"
	# 上面装 systemd-resolved 时它的 postinst 又把 resolv.conf 换回那个悬空符号链接
	# 了，装包前必须再修一次，否则 apt 报 "Temporary failure resolving ..."
	fix_dns
	chroot $R apt-get update -qq
	# 装包失败必须让整个构建失败。GUI 的依赖链是全项目最长的，
	# 静默继续只会产出一个"看着成功、实际缺组件"的镜像，等刷进真机才发现 ——
	# 那时定位成本比现在高一个量级。所以不吞退出码，也不接 | tail
	# （管道的退出码取最后一段，会把 apt 的失败盖掉）。
	if ! chroot $R apt-get install -y -qq \
		plasma-mobile plasma-mobile-tweaks \
		sddm \
		x11-utils xinput \
		plasma-nm \
		firefox-esr \
		vim nano less file unzip zip rsync tmux screen \
		htop btop iotop sysstat \
		git build-essential \
		pipewire pipewire-pulse wireplumber \
		fonts-noto-cjk fonts-noto-color-emoji; then
		echo "[setup-rootfs] FATAL: GUI 包没装上，构建中止（apt 的完整报错在上面）" >&2
		exit 1
	fi

	chroot $R systemctl set-default graphical.target
	chroot $R systemctl enable sddm.service

	# 手机屏 PPI 很高，Xorg/Wayland 默认会让字小得没法看。
	# QT_SCALE_FACTOR 放大 Qt 界面；sddm 的 EnableHiDPI 管登录界面那一块。
	mkdir -p $R/etc/sddm.conf.d
	cat > $R/etc/sddm.conf.d/10-odin-hidpi.conf << 'SDDMCONF'
[X11]
EnableHiDPI=true

[Wayland]
EnableHiDPI=true
SDDMCONF
	grep -q QT_SCALE_FACTOR $R/etc/environment 2>/dev/null \
		|| echo "QT_SCALE_FACTOR=2" >> $R/etc/environment

	# 注意：swap 的 sysctl（vm.swappiness / vfs_cache_pressure）**不在这里写**。
	# 它在 dist/build/rootfs/etc/sysctl.d/99-odin-swap.conf，由
	# apply-staging-fixes.sh 对两个变体一视同仁地部署 —— GUI 不是它的前置条件。
	say "变体=gui：graphical.target + sddm + 2x 缩放 就位"
else
	say "变体=core（无 GUI）"
fi

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
