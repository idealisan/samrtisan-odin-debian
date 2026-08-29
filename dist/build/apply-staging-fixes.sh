#!/bin/bash
# 对既有 rootfs（staging 目录或已挂载的镜像）应用 ODIN 首刷修复增量。
#
# 背景：reports/013 的解包复核发现，最近一次"重建镜像 + 安装 NetworkManager"
# 是在挂载中的镜像里直接改的，导致两项 P0：
#   1) 扩容标记 /var/lib/odin-resize-done 随镜像发布 + 服务未启用 ⇒ 根永远 2GiB
#   2) NM 会接管 usb0 ⇒ 172.16.42.1 被清、USB SSH 救援通道失效
# 本脚本把修复固化下来，幂等、可重复执行，不联网、不装包。
#
# 用法: apply-staging-fixes.sh <rootfs-dir>
set -e

R=${1:?usage: apply-staging-fixes.sh <rootfs-dir>}
[ -d "$R/etc" ] || { echo "not a rootfs: $R" >&2; exit 1; }

say() { echo "[fix] $*"; }

# ---------------------------------------------------------------- 1. 扩容链路
# 标记必须随镜像发布时不存在，否则 ConditionPathExists 会永久跳过扩容
rm -f "$R/var/lib/odin-resize-done"

mkdir -p "$R/usr/local/sbin"
cat > "$R/usr/local/sbin/odin-firstboot-resize.sh" << 'RESIZE'
#!/bin/bash
# 一次性把根分区扩到 userdata 实际大小。
# 关键：成败都由 unit 统一写标记并自禁用，本脚本不因失败而留下
# "每次开机都 failed" 的单元（历史 bug），失败只留 /var/log/odin-resize.log。
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
chmod 0755 "$R/usr/local/sbin/odin-firstboot-resize.sh"

cat > "$R/etc/systemd/system/odin-firstboot-resize.service" << 'UNIT'
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
UNIT

mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/odin-firstboot-resize.service \
  "$R/etc/systemd/system/multi-user.target.wants/odin-firstboot-resize.service"
say "resize: marker cleared, unit reinstalled + re-enabled"

# ------------------------------------------------------- 2. 保住 USB 救援通道
# /etc/network/interfaces 不存在 ⇒ Debian 默认 [ifupdown] managed=false 保护不到
# usb0 ⇒ NM 会按普通以太网自动连接并清掉 172.16.42.1，SSH 失联（无屏设备只剩 UART）
mkdir -p "$R/etc/NetworkManager/conf.d"
cat > "$R/etc/NetworkManager/conf.d/99-odin-usb0.conf" << 'NMC'
# usb0 由 odin-usb-gadget.service 静态配置（172.16.42.1 + dnsmasq 给 PC 172.16.42.2）。
# 必须排除在 NetworkManager 之外，否则 NM 接管后会清掉该地址，导致 USB 网络/SSH 通道失效。
[keyfile]
unmanaged-devices=interface-name:usb0
NMC
chmod 0644 "$R/etc/NetworkManager/conf.d/99-odin-usb0.conf"
say "NetworkManager: usb0 marked unmanaged"

# 首启已有扩容/日志压力，不要让 network-online 再用 90s 超时拖慢启动
rm -f "$R/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service"

# 本设备无蜂窝基带，ModemManager 只徒增启动开销并会扫描串口
if [ -e "$R/lib/systemd/system/ModemManager.service" ] || [ -e "$R/etc/systemd/system/ModemManager.service" ]; then
  rm -f "$R/etc/systemd/system/multi-user.target.wants/ModemManager.service"
  ln -sfn /dev/null "$R/etc/systemd/system/ModemManager.service"
  say "ModemManager masked"
fi

# ---------------------------------------------------------------- 3. 产物卫生
[ -d "$R/mnt/dist" ] && { rm -rf "$R/mnt/dist"; say "removed leftover /mnt/dist"; }
# /boot 下的游离 dtb 与 /boot/dtbs/qcom 下同名同尺寸，易造成"改了 A 没生效"的排障困惑
rm -f "$R/boot/msm8953-smartisan-odin.dtb"

say "done on $R"

# ------------------------------------------------- 4. 阶段 0：安全版 DTB + 双 label
# 首刷用 l0-safe（dr_mode=peripheral，UDC 恒在，SSH 不依赖 Type-C 角色判定）；
# 拿到 SSH 并验证完整版可用后，把 default 改成 l0 重启即可。
# 两个 label 只有 DTB 不同，内核与 initrd 相同。
#
# 关键约束（读 lk2nd 源码 lk2nd/boot/extlinux.c:394-434 确认）：
#   fdt 与 fdtdir **互斥**——label 里只要有 fdtdir，lk2nd 就会用 lk2nd,dtb-files
#   拼路径并覆盖 fdt。所以安全版 label 只写 fdt，绝不能带 fdtdir。
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../.."

if [ -d "$REPO/dts" ]; then
	mkdir -p "$R/boot/dtbs/qcom"
	for d in msm8953-smartisan-odin msm8953-smartisan-odin-norolesw; do
		if [ -f "$REPO/dts/$d.dtb" ]; then
			cp -f "$REPO/dts/$d.dtb" "$R/boot/dtbs/qcom/$d.dtb"
			chmod 0644 "$R/boot/dtbs/qcom/$d.dtb"
		else
			echo "[fix] WARN: 缺少 $REPO/dts/$d.dtb，跳过（先跑 dts/build-dtb.sh）" >&2
		fi
	done
	say "dtb: 完整版 + 安全版已就位"
fi

if [ -f "$HERE/rootfs/extlinux/extlinux.conf" ]; then
	mkdir -p "$R/extlinux"
	cp -f "$HERE/rootfs/extlinux/extlinux.conf" "$R/extlinux/extlinux.conf"
	chmod 0644 "$R/extlinux/extlinux.conf"
	say "extlinux: 双 label 配置就位（default=$(sed -n 's/^default //p' "$R/extlinux/extlinux.conf" | head -1)）"
fi

# ------------------------------------------------- 5. 阶段 1/3：用户态文件
# dist/build/rootfs/ 是这些文件的源，改动请改这里再重跑本脚本，
# 不要直接改 staging（否则下次重建镜像会丢）。
if [ -d "$HERE/rootfs" ]; then
	( cd "$HERE/rootfs" && find . -type f -print ) | while read -r f; do
		dst="$R/${f#./}"
		mkdir -p "$(dirname "$dst")"
		cp -f "$HERE/rootfs/${f#./}" "$dst"
		case "$f" in
			*/sbin/*|*/bin/*) chmod 0755 "$dst" ;;
			*)                chmod 0644 "$dst" ;;
		esac
		echo "[fix]   + /${f#./}"
	done
	say "rootfs 覆盖树已部署"
fi

# ------------------------------------------------- 6. 阶段 3：USB 角色自动切换
# 旧 odin-usb-gadget.sh 是 set -e 的一次性单元：开机那一刻 UDC 不在就永久 failed，
# 之后再插线也不会恢复 ⇒ SSH 救援通道丢失（reports/014、015）。
# 改为 odin-usb-role.sh：幂等、先空后名、任何分支都 exit 0，外加 30s 看门狗。
#
# 用 cat > 而不是 cp：QEMU 镜像里 odin-usb-gadget.service 是指向 /dev/null 的
# 符号链接（无 UDC 故被 mask），写穿它正好保持 mask 生效；真机镜像是普通文件，
# 会被正常覆盖。
cat > "$R/etc/systemd/system/odin-usb-gadget.service" << 'UNIT'
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

cat > "$R/etc/systemd/system/odin-usb-gadget.timer" << 'TIMER'
[Unit]
Description=ODIN USB role watchdog (self-healing every 30s)

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
chmod 0644 "$R/etc/systemd/system/odin-usb-gadget.service" \
           "$R/etc/systemd/system/odin-usb-gadget.timer" 2>/dev/null

# 服务未被 mask（=真机镜像）才启用看门狗；QEMU 镜像里它是 /dev/null 符号链接
if [ ! -L "$R/etc/systemd/system/odin-usb-gadget.service" ]; then
	mkdir -p "$R/etc/systemd/system/timers.target.wants"
	ln -sfn /etc/systemd/system/odin-usb-gadget.timer \
		"$R/etc/systemd/system/timers.target.wants/odin-usb-gadget.timer"
	say "usb-role: service+watchdog timer 已就位并启用"
else
	say "usb-role: service 被 mask（QEMU 镜像），不启用 watchdog"
fi
