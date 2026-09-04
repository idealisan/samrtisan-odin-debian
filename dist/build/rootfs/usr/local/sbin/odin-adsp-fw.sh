#!/bin/bash
# odin-adsp-fw.sh —— 取 ADSP（音频 DSP）固件，并把 ADSP 拉起来
#
# 为什么在用户态再留一条：
#   正确的时序是在 initramfs 里、switch_root 之前备好（见
#   dist/build/initramfs/sbin/odin-adsp-fw.sh）—— 驱动的第一次
#   request_firmware("adsp.mdt") 就直接成功，不需要任何补救。
#
#   但 initramfs 的生成被 `tools/ci/build-rootfs.sh` 的
#   `if [ "$STAGE_CACHE_HIT" != true ]` 包住了：staging 层缓存命中时
#   **不重建 initramfs**。于是新加的取固件脚本不会进镜像，而 ADSP 又带着
#   auto_boot = true（一 probe 就要固件，失败不重试）⇒ 整台机器没有声音。
#   2026-09-04 实刷 v0.9.4-audio4 就是撞在这上面：
#       remoteproc1: Direct firmware load for adsp.mdt failed with error -2
#       /proc/asound/cards -> --- no soundcards ---
#
#   initramfs 那次之所以没生效，是因为 dist/build/initramfs/sbin/odin-adsp-fw.sh
#   以 100644（无可执行位）入的库 —— initramfs 的 `[ -x /sbin/odin-adsp-fw.sh ]`
#   恒假，整段静默跳过，取固件的动作一次都没发生过。
#   （2026-09-04 实刷 v0.9.4-submodules 撞上，ADSP 停在 offline。）
#
#   所以这里补一条用户态兜底：固件不在位就从原厂 modem 分区取，
#   取到后通过 remoteproc 的 sysfs 接口把 ADSP 拉起来。
#   remoteproc 与 platform 驱动不同 —— 它可以在用户态重新启动，
#   不需要重载内核模块。
#
# 失败一律不致命 —— 最坏结果只是没有声音，绝不能因为这一步把启动搞挂。
set -u

FW=adsp.mdt
DEST=/lib/firmware
LOG=/var/log/odin-adsp-fw.log
PROC=/sys/class/remoteproc
# 等 adsp 这个 remoteproc 出现的最长时间（秒）。
# 实测本机 qcom,msm8953-adsp-pil 要到开机约 40.5s 才 probe 出 remoteproc1，
# 而本服务（After=local-fs.target）在 40.0s 就跑完了 —— 差 0.5 秒，
# 于是每次都只留下一句"没有找到 adsp remoteproc，跳过"。
# 40 秒足够；服务的 TimeoutStartSec 是 60，留出余量给取固件与启动。
WAIT_MAX=40

say() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; echo "[odin-adsp-fw] $*" >&2; }

# 找到名字是 adsp 的那个 remoteproc
rp_adsp() {
	for d in "$PROC"/remoteproc*; do
		[ -d "$d" ] || continue
		if [ "$(cat "$d/name" 2>/dev/null)" = "adsp" ]; then
			echo "$d"; return 0
		fi
	done
	return 1
}

have_fw() {
	[ -s "$DEST/$FW" ] || return 1
	ls "$DEST"/adsp.b* >/dev/null 2>&1
}

start_adsp() {
	local rp=$1
	# 已经在跑就不用管
	[ "$(cat "$rp/state" 2>/dev/null)" = "running" ] && return 0

	say "启动 ADSP（$rp）"
	echo "$FW" > "$rp/firmware" 2>/dev/null
	echo start > "$rp/state" 2>/dev/null
	sleep 2
	local st
	st=$(cat "$rp/state" 2>/dev/null)
	say "  state=$st"
	[ "$st" = "running" ]
}

# adsp remoteproc 的注册晚于本服务（见上面 WAIT_MAX 的注释），
# 所以这里等它出现 —— 不睡固定时长，而是每次 1 秒轮询、最多等 WAIT_MAX 秒。
rp=
i=0
while [ "$i" -lt "$WAIT_MAX" ]; do
	if rp=$(rp_adsp); then
		break
	fi
	rp=
	i=$((i + 1))
	sleep 1
done

if [ -z "$rp" ]; then
	say "等了 ${WAIT_MAX}s 仍没有 adsp remoteproc，跳过"
	exit 0
fi
say "找到 adsp remoteproc: $rp（等了 ${i}s）"

# 1) 固件不在位就从原厂 modem 分区取
if ! have_fw; then
	dev=$(readlink -f /dev/disk/by-partlabel/modem 2>/dev/null)
	if [ ! -b "${dev:-}" ]; then
		say "modem 分区不存在，跳过取固件"
	else
		tmp=$(mktemp -d) || tmp=
		if [ -n "${tmp:-}" ] && mount -o ro "$dev" "$tmp" 2>/dev/null; then
			mkdir -p "$DEST"
			for cand in "$tmp"/image/adsp.* "$tmp"/image/ADSP.* \
			            "$tmp"/adsp.* "$tmp"/ADSP.*; do
				[ -f "$cand" ] || continue
				base=${cand##*/}
				lower=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
				cmp -s "$cand" "$DEST/$lower" && continue
				if cp -f "$cand" "$DEST/$lower" 2>/dev/null; then
					say "已取 $lower ($(stat -c%s "$cand") 字节) ← modem"
				fi
			done
			umount "$tmp" 2>/dev/null
			rmdir "$tmp" 2>/dev/null
		else
			say "modem 挂载失败，跳过取固件"
			rmdir "${tmp:-}" 2>/dev/null
		fi
	fi
fi

# 2) 固件齐了就把 ADSP 拉起来
if have_fw; then
	say "固件就位"
	start_adsp "$rp" && say "ADSP 已 running" || say "ADSP 启动失败（详见 dmesg）"
else
	say "仍未取到 $FW，跳过（最坏结果只是没有声音）"
fi

exit 0
