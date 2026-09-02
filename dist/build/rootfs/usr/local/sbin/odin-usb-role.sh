#!/bin/bash
# ODIN — USB 角色自动切换（用户态驱动）
#
# 背景（reports/014、015）：
#   内核层只负责"按 Type-C 判定切换角色"，但 UDC 出现/消失后**没有任何用户态东西**
#   重新绑定 gadget。旧脚本 odin-usb-gadget.sh 是 `set -e` 的一次性单元，
#   开机那一刻 UDC 不在就永久 failed，之后再插线也不会恢复 ⇒ SSH 救援通道丢失。
#
# 本脚本是唯一的角色入口，被三处触发：
#   1. odin-usb-gadget.service（开机）
#   2. /etc/udev/rules.d/99-odin-usb-role.rules（UDC add/remove、typec change）
#   3. odin-usb-gadget.timer（每 30s 自愈看门狗）
#
# 五条硬约束（都是实测/源码级结论，不是经验之谈）：
#   1) 先空后名 —— configfs 会保留 udc_name，不先 echo "" 解绑就直接写名字必返回
#      -EBUSY（drivers/usb/gadget/configfs.c:295）。这正是旧脚本修不好的根因。
#   2) 退出码恒为 0 —— 失败只记日志，由看门狗重试；绝不留 failed 单元。
#   3) 不用 set -e —— 所有返回值显式检查。
#   4) 必须幂等可重入 —— 同时被 udev 与 timer 触发时不能互相打架（用 lockfile）。
#   5) 无 typec 且无 UDC 时立即退出 —— QEMU 等无 USB 角色硬件的环境不要空等。

LOG=${ODIN_USB_ROLE_LOG:-/var/log/odin-usb-role.log}
CFG=/sys/kernel/config/usb_gadget/odin
# dnsmasq 由独立的 systemd unit 托管（见 etc/systemd/system/odin-dnsmasq@.service）。
# 以前这里是 PIDFILE=/run/odin-dnsmasq.pid，但 --no-daemon 下 dnsmasq 根本不写
# pidfile（实测 0 字节），靠它判定只会出错，已弃用。
DNSMASQ_UNIT="${ODIN_DNSMASQ_UNIT:-odin-dnsmasq@usb0.service}"
LOCK=/run/lock/odin-usb-role.lock
#   odin-usb-role.sh [--dry-run]     加 --dry-run 只判断不动作（真机排障用：
#                                    直接执行会抢走 pmOS 已绑定的 UDC，SSH 会断）
UDC_WAIT=${ODIN_UDC_WAIT:-20}     # udev 的 RUN{program} 有 60s 上限，这里留足余量
DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1
HOST_IP=172.16.42.1
CLIENT_IP=172.16.42.2
CLIENT_IP_MAX="${ODIN_CLIENT_IP_MAX:-172.16.42.2}"   # 单地址池——永远只连一台电脑，任何 MAC 都分到同一个 IP

# 固定的 NCM MAC 地址（本地管理地址：第一个字节的第二位为 2，不会与真实硬件 OUI 冲突）
# 为什么必须写死：gadget 每次重启都会随机生成 MAC，PC 侧网卡的 MAC 随之变化，
# dnsmasq 会当成全新客户端；而地址池若被旧 MAC 的租约(12h)占住，就会出现
#   "DHCPDISCOVER(usb0) xx:xx:... no address available"
# 于是 PC 只能拿到 169.254 自分配地址、必须手工配静态 IP（真机踩过两次）。
#
# 注意：这两个默认值是**通用占位**（0d1d ≈ ODIN），不是某台设备的真实 MAC——
# 早先这里写的是从本机 eMMC 序列号派生的地址，那样会把设备序列号泄漏到公开仓库里。
# 因为 USB 是点对点链路，默认值重复不会有问题；若确实要一机一址，用环境变量覆盖：
#   ODIN_GADGET_HOST_MAC=... ODIN_GADGET_DEV_MAC=... （或写进 /etc/odin/usb-role.env）
GADGET_HOST_MAC="${ODIN_GADGET_HOST_MAC:-02:00:0d:1d:00:01}"   # PC 侧看到的 MAC
GADGET_DEV_MAC="${ODIN_GADGET_DEV_MAC:-02:00:0d:1d:00:02}"     # 手机侧 usb0 的 MAC

log() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

# ---------------------------------------------------------------- 并发保护
# udev 事件与 timer 可能同时触发；拿不到锁就直接退出（另一次会做完该做的事）
mkdir -p /run/lock 2>/dev/null
exec 9>"$LOCK" 2>/dev/null
if ! flock -n 9 2>/dev/null; then
	log "another instance running, skip"
	exit 0
fi

# ---------------------------------------------------------------- 环境准备
modprobe configfs 2>/dev/null
mount -t configfs none /sys/kernel/config 2>/dev/null
[ -d /sys/kernel/config/usb_gadget ] || { log "configfs unavailable, skip"; exit 0; }

# ------------------------------------------------------- 当前应有的角色
# PMIC SMBCHG extcon 是 ODIN 的角色来源；Type-C class 保留作兼容兜底。
want_role() {
	local f r
	for f in /sys/class/extcon/*/state; do
		[ -r "$f" ] || continue
		grep -qx 'USB-HOST=1' "$f" && { echo host; return; }
	done
	for f in /sys/class/typec/*/data_role; do
		[ -r "$f" ] || continue
		r=$(cat "$f" 2>/dev/null)
		case "$r" in
			host|*"[host]"*) echo host; return ;;
		esac
	done
	echo device
}

udc_now() { ls /sys/class/udc 2>/dev/null | head -n1; }

# ---------------------------------------------------------------- device 分支
dnsmasq_running() {
	# dnsmasq 现在是独立的 systemd unit，判定直接问 systemd 最准。
	if systemctl is-active --quiet "$DNSMASQ_UNIT" 2>/dev/null; then
		return 0
	fi
	# systemd 不可用时的兜底（例如某些容器里跑 dry-run）：按进程命令行筛。
	# 别写成 `pgrep | while read; do return 0; done` —— while 在管道里开子 shell，
	# 里面的 return 退不出函数，判定会永远返回假。用命令替换喂 for 循环。
	local p
	for p in $(pgrep -x dnsmasq 2>/dev/null); do
		if tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--interface=usb0"; then
			return 0
		fi
	done
	return 1
}

apply_device() {
	local udc
	# 只在"有 USB 角色硬件"时才等 UDC；否则立即退出，避免空转
	if [ ! -d /sys/class/typec ] && [ -z "$(udc_now)" ]; then
		log "device: no typec and no UDC -> skip (非角色切换环境)"
		return 0
	fi

	udc=$(udc_now)
	if [ -z "$udc" ]; then
		log "device: waiting UDC up to ${UDC_WAIT}s"
		local i=0
		while [ -z "$udc" ] && [ "$i" -lt "$UDC_WAIT" ]; do
			sleep 1; i=$((i+1)); udc=$(udc_now)
		done
	fi
	if [ -z "$udc" ]; then
		log "device: UDC still absent after ${UDC_WAIT}s -> give up (watchdog will retry)"
		return 0
	fi

	# dry-run：到此为止，不碰 gadget / 网络 / dnsmasq（真机上直接执行会抢走
	# pmOS 已绑定的 UDC，SSH 立刻断，所以排障必须用 dry-run）
	if [ "$DRY_RUN" = 1 ]; then
		local cur=""
		[ -r "$CFG/UDC" ] && cur=$(cat "$CFG/UDC" 2>/dev/null)
		log "device: [dry-run] udc=$udc gadget-UDC='$cur' "\
			"dnsmasq_running=$(dnsmasq_running && echo yes || echo no); no action"
		return 0
	fi

	# 建 gadget（幂等：目录/软链已存在时 mkdir、ln 都允许失败）
	mkdir -p "$CFG/functions/ncm.usb0" "$CFG/configs/c.1" 2>/dev/null
	[ -f "$CFG/idVendor" ]  || echo 0x18d1 > "$CFG/idVendor"   2>/dev/null
	[ -f "$CFG/idProduct" ] || echo 0x4ee1 > "$CFG/idProduct"  2>/dev/null
	mkdir -p "$CFG/configs/c.1/strings/0x409" 2>/dev/null
	[ -f "$CFG/configs/c.1/strings/0x409/configuration" ] \
		|| echo "ODIN Debian" > "$CFG/configs/c.1/strings/0x409/configuration" 2>/dev/null
	ln -sf "$CFG/functions/ncm.usb0" "$CFG/configs/c.1/f1" 2>/dev/null

	# MAC 固定 —— 注意两点（都踩过）：
	#  1) configfs 的 host_addr/dev_addr 一旦绑定 UDC 就不可写（Permission denied）；
	#     而且这两个文件**总是存在**（内核填了随机值），所以不能用 [ -f ] 判断是否跳过
	#     （旧代码正是这样 ⇒ 一直用随机 MAC，每次重启换一个，把 dnsmasq 地址池耗光）。
	#  2) 改成 usb0 出现后用 ip link set 设置，这个在绑定后仍然有效。

	ip link set usb0 up 2>/dev/null
	ip addr add ${HOST_IP}/24 dev usb0 2>/dev/null   # 已存在时报错无妨

	# 固定手机侧 MAC（PC 侧看到的 host MAC 由内核/对端决定，这里固定本端即可）
	#
	# **仅当当前 MAC 不是目标 MAC 才重设**。
	# 以前这里是无条件 down/up，而看门狗每 30s 跑一次脚本 —— 等于每 30s 把网卡
	# 打掉一次。dnsmasq 用 --bind-interfaces 把 socket 钉死在 usb0 上（不会动态
	# 重绑），链路 down 会让 DHCP 实际失效：进程还在，但发不出回包，PC 又退回
	# 169.254。加重设守卫后，看门狗空跑时不再打断网络。
	local cur_mac=""
	[ -r /sys/class/net/usb0/address ] && cur_mac=$(cat /sys/class/net/usb0/address 2>/dev/null)
	if [ "$cur_mac" != "$GADGET_DEV_MAC" ]; then
		ip link set usb0 down 2>/dev/null
		ip link set usb0 address "$GADGET_DEV_MAC" 2>/dev/null
		ip link set usb0 up 2>/dev/null
		ip addr add ${HOST_IP}/24 dev usb0 2>/dev/null   # 重新 up 后地址会丢，补一次
	fi

	# dnsmasq 地址池：给足范围，避免多次重启后旧租约把池占满导致 "no address available。
	# 更稳妥的做法是每次启动都清空租约文件（下面执行）。

	# 【关键】先清空再写名字，否则 configfs 保留旧 udc_name 直接 -EBUSY
	local cur=""
	[ -r "$CFG/UDC" ] && cur=$(cat "$CFG/UDC" 2>/dev/null)
	if [ "$cur" != "$udc" ]; then
		[ -n "$cur" ] && echo "" > "$CFG/UDC" 2>/dev/null
		if ! echo "$udc" > "$CFG/UDC" 2>/dev/null; then
			log "device: bind UDC '$udc' FAILED"
			return 0
		fi
		sleep 1
		log "device: bound UDC=$udc"
	fi

	ip link set usb0 up 2>/dev/null
	ip addr add ${HOST_IP}/24 dev usb0 2>/dev/null   # 已存在时报错无妨

	# 等 usb0 真正拿到地址再启 dnsmasq：刚 add 完地址还处于 tentative，过早绑定
	# 会让 dnsmasq 起来后又退出（开机时"started (pid N)"但 pgrep 查不到就是这个原因）
	local w=0
	while [ "$w" -lt 10 ]; do
		ip -4 -o addr show usb0 2>/dev/null | grep -q "${HOST_IP}" && break
		sleep 1; w=$((w+1))
	done
	if [ "$w" -ge 10 ]; then
		log "device: usb0 未拿到 ${HOST_IP}，仍尝试启动 dnsmasq（看门狗会重试）"
	fi

	if dnsmasq_running; then
		log "device: dnsmasq already running, skip"
		return 0
	fi

	# 清租约：gadget MAC 每次重启随机 ⇒ 旧租约会累积，把（单地址）池占满 ⇒
	# 新客户端 "no address available"。每次重建 gadget 都清一次。
	rm -f /var/lib/misc/dnsmasq.leases 2>/dev/null

	# 【关键】交给 systemd unit 启动，而不是在这里用 & 裸起。
	#
	# 为什么：裸 & 起的 dnsmasq 会留在**调用者**的 cgroup 里。本脚本有两个调用者，
	# udev 的 RUN{program} 和 odin-usb-gadget.service：
	#   - udev 事件处理完会清理事件 cgroup ⇒ dnsmasq 被杀；
	#     UDC 的 add 事件发生在内核枚举阶段、远早于 multi-user.target，
	#     所以开机时第一个拉起它的就是 udev ⇒ 必死。
	#   - service 重启时按 KillMode 默认 control-group 清 cgroup ⇒ 也会被杀。
	# 独立成 unit 后 dnsmasq 有自己的 cgroup 和 Restart=always，两条都杀不到它，
	# 真被杀也会在 3 秒后自己回来。
	#
	# dnsmasq 的具体参数（--conf-file=/dev/null / --port=0 / --bind-interfaces /
	# 单地址池）全部在 unit 文件里维护，这里不再重复；注释见
	# etc/systemd/system/odin-dnsmasq@.service。
	# --no-block 很重要：默认 systemctl start 会一直阻塞到目标 unit 变 active。
	# 本脚本是被 systemd 拉起的，若 dnsmasq unit 因任何原因起不来（比如 usb0 还没
	# 被 systemd 认成 device unit），阻塞会让 odin-usb-gadget.service 一直挂在
	# "starting"，看门狗也就再也排不上（实测开机卡在 USB Gadget Service 一分多钟）。
	if systemctl start --no-block "$DNSMASQ_UNIT" 2>/dev/null; then
		log "device: usb0=${HOST_IP}/24 dnsmasq start requested ($DNSMASQ_UNIT)"
	else
		log "device: dnsmasq start FAILED ($DNSMASQ_UNIT); last log:"
		tail -3 /var/log/odin-dnsmasq.log 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
		systemctl status "$DNSMASQ_UNIT" --no-pager -n 5 2>/dev/null \
			| sed 's/^/    /' | tee -a "$LOG"
	fi
	return 0
}

# ---------------------------------------------------------------- host 分支
apply_host() {
	local cur=""
	[ -r "$CFG/UDC" ] && cur=$(cat "$CFG/UDC" 2>/dev/null)
	if [ "$DRY_RUN" = 1 ]; then
		log "host: [dry-run] would unbind UDC='$cur' / stop dnsmasq, skip"
		return 0
	fi
	if [ -n "$cur" ]; then
		echo "" > "$CFG/UDC" 2>/dev/null && log "host: unbound UDC '$cur'"
	fi
	# 以前这里是 kill "$(cat $PIDFILE)"，但 --no-daemon 下 $PIDFILE 恒为 0 字节
	# ⇒ kill "" 必失败 ⇒ 切 host 时 dnsmasq 根本杀不掉。改走 systemctl。
	if dnsmasq_running; then
		systemctl stop "$DNSMASQ_UNIT" 2>/dev/null && log "host: dnsmasq stopped"
	fi
	ip addr flush dev usb0 2>/dev/null
	return 0
}

# ---------------------------------------------------------------- 主流程
role=$(want_role)
case "$role" in
	host)   apply_host   ;;
	*)      apply_device ;;
esac

exit 0
