#!/bin/bash
# lk2nd 本地快速编译 —— 只用于迭代，发布制品仍以 CI 为准
#
#   bash tools/lk2nd-build-local.sh             # 编完整版 + 精简版
#   bash tools/lk2nd-build-local.sh --clean     # 先换一份新源码副本重来
#
# 为什么有这个脚本：lk2nd 在 CI 上只要 39 秒，但一轮 CI 要排队 + 全流程约 30 分钟。
# 改按键映射、改菜单文案这类活，本地十几秒就能看到产物，迭代速度差两个数量级。
#
# 编译命令与 Makefile 的 lk2nd target 保持一致（同样的补丁顺序、同样的
# LK2ND_VERSION / PROJECT），只是输出到 tmp/。
#
# 工具链（arm-none-eabi）三选一，按这个顺序找：
#   1. $ODIN_ARM_TOOLCHAIN/bin
#   2. tmp/lk2nd/toolchain/bin   （免 sudo 的解包位置，见下面说明）
#   3. 直接当它在 PATH 里
# 版本建议用 13.x：GCC 14+ 把 -Wincompatible-pointer-types 从警告升级成了错误，
# LK 的老代码（target/msm8953/oem_panel.c 的 FASTBOOT_INIT）会直接编不过。
# CI 用的是 Ubuntu 的 13.3。
#
# 免 sudo 装工具链的办法（Homebrew 的 gcc-arm-embedded 是 pkg，要 sudo）：
#   mkdir -p tmp/lk2nd
#   env -u http_proxy -u https_proxy curl -fsSL -o tmp/lk2nd/tc.tar.xz \
#     https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/\
# arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi.tar.xz
#   mkdir -p tmp/lk2nd/toolchain
#   tar -xf tmp/lk2nd/tc.tar.xz -C tmp/lk2nd/toolchain --strip-components=1
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
HERE="$REPO/tmp/lk2nd"
OUT="$HERE/out"
LK2ND_VER=23.1
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
# 每次运行用一个新的源码副本目录，不删旧目录 —— 省得删文件触发权限确认，
# 也留着上一次的现场可比对。
STAMP=$(date '+%H%M%S')
SRC="$HERE/src-$STAMP"

CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

TC=""
for c in "${ODIN_ARM_TOOLCHAIN:-}/bin" "$HERE/toolchain/bin"; do
	[ -x "$c/arm-none-eabi-gcc" ] && { TC="$c"; break; }
done
if [ -z "$TC" ]; then
	command -v arm-none-eabi-gcc >/dev/null || {
		echo "缺 ARM32 工具链。设置 ODIN_ARM_TOOLCHAIN，或解包到 tmp/lk2nd/toolchain（见本脚本头部注释）" >&2
		exit 1; }
else
	export PATH="$TC:$PATH"
fi
echo "工具链: $(command -v arm-none-eabi-gcc)  ($(arm-none-eabi-gcc --version | head -1))"

if [ "$CLEAN" = 1 ] || [ ! -d "$SRC" ]; then
	date '+[%F %T] 复制源码副本 -> src-'"$STAMP"
	mkdir -p "$SRC"
	(cd "$REPO/ext/lk2nd" && tar --exclude=.git -cf - .) | (cd "$SRC" && tar -xf -)
	test -f "$SRC/makefile" || { echo "源码副本不完整" >&2; exit 1; }
fi

date '+[%F %T] 打补丁 0001 0002 0003 0005 0006 0007 0008 0009'
for p in $(for n in 0001 0002 0003 0005 0006 0007 0008 0009; do ls "$REPO"/lk2nd/$n-*.patch 2>/dev/null; done); do
	echo "  $(basename "$p")"
	patch -p1 --forward --no-backup-if-mismatch -d "$SRC" < "$p" || {
		echo "补丁失败：$p" >&2; exit 1; }
done

mkdir -p "$OUT"
date '+[%F %T] 编完整版'
make -j"$JOBS" -C "$SRC" TOOLCHAIN_PREFIX=arm-none-eabi- \
	LK2ND_VERSION="$LK2ND_VER-full" PROJECT=lk2nd-msm8953 \
	> "$HERE/build-full-$STAMP.log" 2>&1 || {
		echo "完整版编译失败，看 $HERE/build-full-$STAMP.log" >&2
		tail -25 "$HERE/build-full-$STAMP.log"; exit 1; }
cp -f "$SRC/build-lk2nd-msm8953/lk2nd.img" "$OUT/lk2nd.img"
echo "  lk2nd.img         $(stat -f%z "$OUT/lk2nd.img") 字节"

date '+[%F %T] 打补丁 0004 → 编精简版'
for p in "$REPO"/lk2nd/0004-*.patch; do
	echo "  $(basename "$p")"
	patch -p1 --forward --no-backup-if-mismatch -d "$SRC" < "$p" || {
		echo "补丁失败：$p" >&2; exit 1; }
done
# 必须清掉构建目录：0004 改的是 rules.mk，而 make 不把 rules.mk 当依赖，
# 增量重编不会重造 QCDT 表 —— 第二份镜像里会照样带着 markw / rosy。
rm -rf "$SRC/build-lk2nd-msm8953"
make -j"$JOBS" -C "$SRC" TOOLCHAIN_PREFIX=arm-none-eabi- \
	LK2ND_VERSION="$LK2ND_VER-odin" PROJECT=lk2nd-msm8953 \
	> "$HERE/build-trimmed-$STAMP.log" 2>&1 || {
		echo "精简版编译失败，看 $HERE/build-trimmed-$STAMP.log" >&2
		tail -25 "$HERE/build-trimmed-$STAMP.log"; exit 1; }
cp -f "$SRC/build-lk2nd-msm8953/lk2nd.img" "$OUT/lk2nd-odin.img"
echo "  lk2nd-odin.img $(stat -f%z "$OUT/lk2nd-odin.img") 字节"

date '+[%F %T] 自检'
strings "$OUT/lk2nd-odin.img" > "$OUT/.strings.txt"
grep -q "xiaomi-markw" "$OUT/.strings.txt" \
	&& { echo "  ❌ 仍能搜到 xiaomi-markw" >&2; exit 1; } \
	|| echo "  ✅ xiaomi-markw: 0 处"
grep -q "xiaomi-rosy" "$OUT/.strings.txt" \
	&& { echo "  ❌ 仍能搜到 xiaomi-rosy" >&2; exit 1; } \
	|| echo "  ✅ xiaomi-rosy: 0 处"
grep -q "smartisan-odin" "$OUT/.strings.txt" \
	&& echo "  ✅ smartisan-odin: 保留" \
	|| { echo "  ❌ odin 条目丢失" >&2; exit 1; }
echo "  精简版版本串: $(grep -oE "$LK2ND_VER-[a-z]+" "$OUT/.strings.txt" | sort -u | tr '\n' ' ')"
date '+[%F %T] 完成'
