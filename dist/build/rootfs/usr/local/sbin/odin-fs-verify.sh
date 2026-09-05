#!/bin/bash
# odin-fs-verify.sh —— 根文件系统与启动路径的验收
#
#   sudo odin-fs-verify.sh
#
# 为什么单独有这个脚本（flash-all.sh 阶段 80 的 16 项已经验过一遍了）：
#   那 16 项验的是"屏幕 / 网络 / 扩容 / 服务"这类一眼可见的东西，
#   本脚本验的是**不出声就出错**的那几项 —— 文件系统特性位、lk2nd 的挂载
#   门禁、块设备编号、initramfs 有没有退化到暴力扫分区。这些平时没人看，
#   一旦不对就是"起不来"或者"悄悄少了个功能"。
#
# 背景（2026-09-05 那两次专项）：
#   * 开 extents   —— 为了基于文件的 swap（swapfile 走 iomap，没 extents 用不了）
#   * 开 metadata_csum —— 能检出 eMMC 位翻转造成的元数据静默损坏
#   两者都会抬高 lk2nd（二级引导）挂载根分区的门槛，所以必须正反向都验：
#   "该开的开了"和"该关的没开"，缺一边都不算数。
#
# 只读，不改动任何东西；退出码非 0 表示有项没过。
set -uo pipefail

# lk2nd ext2 驱动放行的 ro_compat 位（补丁 0006 之后）
#   sparse_super 0x001 / large_file 0x002 / metadata_csum 0x400
LK2ND_RO_ALLOWED=$((0x1 | 0x2 | 0x400))

pass=0
fail=0
ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m❌\033[0m %s\n' "$*"; fail=$((fail + 1)); }
info() { printf '     %s\n' "$*"; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# 期望包含 / 不包含
want()    { case "$2" in *"$1"*) ok   "$3";; *) bad "$3（实际: $2）";; esac; }
wantnot() { case "$2" in *"$1"*) bad "$3（不该有，实际: $2）";; *) ok   "$3（确无）";; esac; }

[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0" >&2; exit 2; }

ROOT_DEV=$(findmnt -no SOURCE /)
[ -n "$ROOT_DEV" ] || { echo "查不到根设备" >&2; exit 2; }

echo "========== odin 根文件系统 / 启动路径验收 =========="
echo "时间: $(date '+%F %T')"
echo "根设备: $ROOT_DEV"

# ---------------------------------------------------------------- 1. 特性位
sect "1. ext4 特性位（正反向都验）"
FEAT=$(dumpe2fs -h "$ROOT_DEV" 2>/dev/null | sed -n 's/^Filesystem features: *//p')
[ -n "$FEAT" ] || { echo "  dumpe2fs 读不出特性，中止"; exit 2; }
info "$FEAT"
want extent        "$FEAT" "extents 已开（swapfile 的前提）"
want metadata_csum "$FEAT" "metadata_csum 已开"
wantnot 64bit        "$FEAT" "64bit 未开（lk2nd 按 32 字节读组描述符）"
wantnot huge_file    "$FEAT" "huge_file 未开"
wantnot dir_nlink    "$FEAT" "dir_nlink 未开"
wantnot extra_isize  "$FEAT" "extra_isize 未开"

# ---------------------------------------------------------------- 2. lk2nd 门禁
sect "2. lk2nd 挂载门禁（位掩码才是真正的门槛，不是特性名清单）"
# 直接从超级块读 s_feature_ro_compat：超级块在分区偏移 1024 处，字段在 0x64。
# 用 od 而不是 dumpe2fs，是为了绕开"特性名"这层翻译 —— 名是给人看的，
# lk2nd 判的是位。
RO_HEX=$(dd if="$ROOT_DEV" bs=1 skip=1124 count=4 2>/dev/null | od -An -tx4 -N4 --endian=little | tr -d ' \n')
if [ -n "$RO_HEX" ]; then
	RO=$((16#$RO_HEX))
	MASKED=$((RO & ~LK2ND_RO_ALLOWED))
	printf '     s_feature_ro_compat = 0x%03x（放行 0x%03x，越界位 0x%03x）\n' \
		"$RO" "$LK2ND_RO_ALLOWED" "$MASKED"
	if [ "$MASKED" -eq 0 ]; then
		ok "lk2nd 会放行（ro_compat 没有越界位）"
	else
		bad "lk2nd 会拒绝挂载（越界位 0x$(printf '%x' "$MASKED")）—— 下次起不来"
	fi
else
	bad "读不出 s_feature_ro_compat（dd 失败？）"
fi

# ---------------------------------------------------------------- 3. 有没有真的报错
sect "3. 启动以来的 ext4 报错"
NERR=$(dmesg 2>/dev/null | grep -c "EXT4-fs error")
if [ "${NERR:-0}" -eq 0 ]; then ok "0 条 EXT4-fs error（校验和全部通过）"
else bad "$NERR 条 EXT4-fs error"; dmesg | grep "EXT4-fs error" | tail -5 | sed 's/^/       /'; fi

# 元数据校验和真出问题时，内核会点名说 "checksum"
NCERR=$(dmesg 2>/dev/null | grep -ci "checksum.*invalid\|corrupt.*checksum")
if [ "${NCERR:-0}" -eq 0 ]; then ok "0 条校验和错误"
else bad "$NCERR 条校验和错误"; dmesg | grep -i "checksum.*invalid" | tail -5 | sed 's/^/       /'; fi

# ---------------------------------------------------------------- 4. initramfs 找根
sect "4. initramfs 找根的路径（有没有退化到暴力扫分区）"
# 正常情况 dmesg 里只应该有根分区被挂载过。若出现一串别的分区 mount 又 umount，
# 说明 try_mount_root 的快路径（GPT 分区名 / 卷标）没命中，掉了兜底。
MOUNTED=$(dmesg 2>/dev/null | grep "EXT4-fs (" | sed -n 's/.*EXT4-fs (\([a-z0-9]*\)).*/\1/p' | sort -u | tr '\n' ' ')
info "本次启动挂载过的分区: ${MOUNTED:-（无）}"
OTHERS=$(echo "$MOUNTED" | tr ' ' '\n' | grep -v "^${ROOT_DEV#/dev/}$" | grep -c . || true)
if [ "${OTHERS:-0}" -eq 0 ]; then
	ok "只挂载过根分区，走的是快路径"
else
	bad "还挂载过 $OTHERS 个别的分区 —— 快路径没命中，退化到暴力扫描了"
fi

# ---------------------------------------------------------------- 5. swap
sect "5. swap（两级）"
SW=$(swapon --show --noheadings 2>/dev/null)
if [ -n "$SW" ]; then
	echo "$SW" | sed 's/^/     /'
	want "/swapfile" "$SW" "swapfile 在（依赖 extents）"
	want "/dev/zram" "$SW" "zram 在（第一级）"
	TOTAL=$(free -m | awk '/^Swap:/{print $2}')
	info "swap 合计 ${TOTAL} MiB"
	[ "${TOTAL:-0}" -gt 4000 ] && ok "swap 总量 > 4 GiB" || bad "swap 总量只有 ${TOTAL} MiB"
else
	bad "没有任何 swap"
fi

# ---------------------------------------------------------------- 6. 启动耗时
sect "6. 启动耗时"
if command -v systemd-analyze >/dev/null 2>&1; then
	# 取 "Startup finished in A (kernel) + B (userspace) = Cs" 里最后那个合计值。
	# 别用 tail -1 —— 那行是 "graphical.target reached after ..."，不是合计。
	SA=$(systemd-analyze 2>/dev/null | sed -n 's/^Startup finished in //p')
	info "Startup finished in $SA"
	SEC=$(printf '%s' "$SA" | sed -n 's/.*= *\([0-9.]*\)s.*/\1/p')
	if [ -n "$SEC" ]; then
		INT=${SEC%.*}
		if [ "${INT:-0}" -lt 300 ]; then
			ok "总启动 ${SEC}s（< 5 分钟）"
		else
			bad "总启动 ${SEC}s，偏慢（刷机后首启若超 4 分钟，先查 initramfs 找根那一段）"
		fi
	else
		info "（合计值没解析出来，跳过耗时判据）"
	fi
else
	info "没有 systemd-analyze，跳过"
fi

# ---------------------------------------------------------------- 7. 块设备编号
sect "7. 块设备编号（仅记录，不作为判据）"
info "根设备现在是 ${ROOT_DEV}"
info "（历史上在 mmcblk0 / mmcblk1 之间漂过，两个 SDHCI 控制器注册顺序不稳定；"
info "  这也是 initramfs 改用 GPT 分区名找根的原因之一）"

echo
echo "=============================================="
if [ "$fail" -eq 0 ]; then
	printf '\033[32m全部通过：%d 项\033[0m\n' "$pass"
	exit 0
else
	printf '\033[31m通过 %d 项，失败 %d 项\033[0m\n' "$pass" "$fail"
	exit 1
fi
