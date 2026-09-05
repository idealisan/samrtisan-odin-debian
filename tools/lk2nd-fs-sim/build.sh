#!/bin/bash
# 在宿主机上编译 lk2nd 的 ext2 驱动 + 仿真台。
#
# 关键点：
#   1. 驱动源码从 ext/lk2nd 复制到本地 src/，然后把 lk2nd/0005 补丁打上去 ——
#      这样仿真台测的**就是真正会编进 lk2nd.img 的那份代码**，而不是子模块的
#      原始状态（子模块平时是干净的，我们的改动都在 lk2nd/*.patch 里）。
#   2. 编译时用 -I 指到本目录，于是 #include <lib/bio.h> / <debug.h> 会命中
#      我们的 shim.h，ext/ 下的源码一个字都不用改。
#
# 用法：
#   ./build.sh              # 打补丁后编译（默认，测"改后"的行为）
#   NOPATCH=1 ./build.sh    # 不打补丁（用来复现"改前"的失败，做对照）
#   DEBUGLEVEL=SPEW ./build.sh   # 打开驱动的逐块 trace
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LK="$REPO/ext/lk2nd"
DBG="${DEBUGLEVEL:-}"
cd "$HERE"

if [ ! -d "$LK/lib/fs/ext2" ]; then
	echo "[build] ❌ 找不到 $LK（先跑：git submodule update --init ext/lk2nd）" >&2
	exit 1
fi

# ---- 1. 复制驱动源码
rm -rf src
mkdir -p src/lib/fs/ext2
cp "$LK"/lib/fs/ext2/*.c "$LK"/lib/fs/ext2/*.h src/lib/fs/ext2/

# ---- 2. 应用我们的补丁（NOPATCH=1 时跳过）
if [ "${NOPATCH:-0}" = 1 ]; then
	echo "[build] NOPATCH=1 —— 用子模块原始代码（复现'改前'行为）"
else
	p=$(ls "$REPO"/lk2nd/0005-*.patch 2>/dev/null | head -1)
	if [ -n "$p" ]; then
		echo "[build] 应用 $(basename "$p")"
		patch -p1 --forward --no-backup-if-mismatch -d src < "$p"
	else
		echo "[build] ⚠ 没找到 lk2nd/0005-*.patch，按未打补丁编译" >&2
	fi
fi

# ---- 3. 编译
echo "[build] 编译 ext2sim${DBG:+ (DEBUGLEVEL=$DBG)}"
cc -std=gnu11 -O1 -g -Wall -Wno-unused-parameter \
	-I "$HERE" ${DBG:+-DDEBUGLEVEL=$DBG} \
	-o ext2sim \
	main.c shim.c \
	src/lib/fs/ext2/ext2.c src/lib/fs/ext2/file.c \
	src/lib/fs/ext2/io.c src/lib/fs/ext2/dir.c

echo "[build] OK -> $HERE/ext2sim"
