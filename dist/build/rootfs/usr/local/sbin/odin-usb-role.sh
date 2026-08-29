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
PIDFILE=/run/odin-dnsmasq.pid
LOCK=/run/lock/odin-usb-role.lock
#   odin-usb-role.sh [--dry-run]     加 --dry-run 只判断不动作（真机排障用：
#                                    直接执行会抢走 pmOS 已绑定的 UDC，SSH 会断）
UDC_WAIT=${ODIN_UDC_WAIT:-20}     # udev 的 RUN{program} 有 60s 上限，这里留足余量
DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1
HOST_IP=172.16.42.1
CLIENT_IP=172.16.42.2
CLIENT_IP_MAX=172.16.42.10   # 地址池上限（兜底：MAC 万一变了也不会无地址可分）

# 固定的 NCM MAC 地址（基于本机序列号 <emmc-serial>，本地管理地址，第二位为 2 合法）
# 为什么必须写死：gadget 每次重启都会随机生成 MAC，PC 侧网卡的 MAC 随之变化，
# dnsmasq 会当成全新客户端；而地址池若被旧 MAC 的租约(12h)占住，就会出现
#   "DHCPDISCOVER(usb0) xx:xx:... no address available"
# 于是 PC 只能拿到 169.254 自分配地址、必须手工配静态 IP（真机踩过两次）。
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
# Type-C 判 host 才切 host；没有 typec 子系统（安全版 DTB / QEMU）则恒 device
want_role() {
	local f r
	for f in /sys/class/typec/*/data_role; do
		[ -r "$f" ] || continue
		r=$(cat "$f" 2>/dev/null)
		[ "$r" = "host" ] && { echo host; return; }
	done
	echo device
}

udc_now() { ls /sys/class/udc 2>/dev/null | head -n1; }

# ---------------------------------------------------------------- device 分支
dnsmasq_running() {
	# 不能只看 pidfile：pid 可能被别的进程占用，会误判成"已在运行"而永远不启动
	local p
	[ -s "$PIDFILE" ] || return 1
	p=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$p" ] || return 1
	# 确认这个 pid 确实是服务于 usb0 的 dnsmasq
	tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--interface=usb0" || return 1
	kill -0 "$p" 2>/dev/null
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

	# 绑定 UDC 之前写死 MAC，否则 gadget 会用随机 MAC（见文件头注释）
	[ -f "$CFG/functions/ncm.usb0/host_addr" ] \
		|| echo "$GADGET_HOST_MAC" > "$CFG/functions/ncm.usb0/host_addr" 2>/dev/null
	[ -f "$CFG/functions/ncm.usb0/dev_addr" ] \
		|| echo "$GADGET_DEV_MAC" > "$CFG/functions/ncm.usb0/dev_addr" 2>/dev/null

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
	rm -f "$PIDFILE" 2>/dev/null
	# 注意两点（都是真机踩出来的）：
	#   1) 必须 --conf-file=/dev/null：系统 /etc/dnsmasq.d/zz-gadget-exclude.conf
	#      里有 bind-dynamic，与命令行的 --bind-interfaces 冲突，
	#      dnsmasq 会直接 "cannot set --bind-interfaces and --bind-dynamic" 退出。
	#   2) 系统 dnsmasq 会占住 UDP 67（bind-dynamic 绑通配地址），导致这里起不来。
	#      手机上没有别的用途，已在镜像里 disable 掉系统 dnsmasq。
	dnsmasq --no-daemon --pid-file="$PIDFILE" --interface=usb0 \
		--conf-file=/dev/null \
		--bind-interfaces --dhcp-range=${CLIENT_IP},${CLIENT_IP_MAX},12h \
		--dhcp-option=option:router --no-resolv --no-hosts \
		--log-facility=/var/log/odin-dnsmasq.log &
	dnsmasq_pid=$!
	sleep 1
	if kill -0 "$dnsmasq_pid" 2>/dev/null; then
		log "device: usb0=${HOST_IP}/24 dnsmasq started (pid $dnsmasq_pid)"
	else
		log "device: dnsmasq FAILED to start; last log:"
		tail -3 /var/log/odin-dnsmasq.log 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
		log "device: hint: 检查 67 端口是否被别的 dnsmasq 占用"
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
	if dnsmasq_running; then
		kill "$(cat "$PIDFILE")" 2>/dev/null && log "host: dnsmasq stopped"
	fi
	[ -s "$PIDFILE" ] && rm -f "$PIDFILE" 2>/dev/null
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
