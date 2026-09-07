#!/bin/bash
# tools/ci/build-rmtfs.sh —— 交叉编译 Qualcomm rmtfs 用户态守护进程
#
#   tools/ci/build-rmtfs.sh <输出目录>
#
# 产物：<输出目录>/rmtfs —— **全静态**的 aarch64 二进制。
#
# ---------------------------------------------------------------------------
# 为什么必须自己编（不能 apt 装）
# ---------------------------------------------------------------------------
# Debian bookworm 没有 rmtfs 包；postmarketOS 也是自己从源码编的
# （andersson/rmtfs）。而 modem 离不开它：modem 起来后要通过 rmtfs 读写 EFS
# （modemst1/modemst2），没有它 modem 初始化会卡死，watchdog 每约 50 秒把
# modem 拽崩一次（dog.c:1526:Watchdog detects stalled initialization）。
#
# ---------------------------------------------------------------------------
# 为什么要「去掉 libudev + 全静态链接」这两个改动
# ---------------------------------------------------------------------------
# 上游 rmtfs 的非 Android 分支用 libudev 去读共享内存设备的两个 sysfs 属性
# （phys_addr / size）。这条依赖在 CI 上有两个很硬的麻烦：
#
#   1. 交叉编译时得给 runner 装 `libudev-dev:arm64`，那是从 **Ubuntu** 拉的，
#      而设备跑的是 Debian bookworm。链接进去的 glibc 符号版本可能高于
#      bookworm 的 2.36（Ubuntu 24.04 是 2.39），设备上直接
#      "version `GLIBC_2.xx' not found"，而且是**运行时**才炸，构建期全绿。
#   2. Debian 的 libudev-dev **不带静态库**（没有 libudev.a，实测确认），
#      所以想静态也静态不了。
#
# 正解是绕开 libudev：上游源码里本来就有另一套实现（原来的 ANDROID 分支），
# 直接读 /sys/class/rmtfs/qcom_rmtfs_mem%d/{phys_addr,size}，不用 libudev。
# 这个路径对本机是成立的，已逐项核实：
#   · 内核 drivers/soc/qcom/rmtfs_mem.c：class 名就是 "rmtfs"（rmtfs_class），
#     设备名 "qcom_rmtfs_mem%d"，属性有 phys_addr / size / client_id（0444）；
#   · 真机实测：`cat /sys/class/rmtfs/qcom_rmtfs_mem1/phys_addr` →
#     0x00000000f2d00000，size → 0x0000000000180000。
#     （值是 %pa 打的、带 "0x" 前缀，strtoull(.., 16) 能正确解析。）
#
# 于是 0001 这个补丁只做一件事：把两套实现的开关从 `#ifndef ANDROID` 改成
# `#ifdef RMTFS_USE_LIBUDEV`，默认走 sysfs 那套；顺带把 <sys/endian.h> 改成
# <endian.h>（前者是 musl/BSD 的拼法，glibc 只有 <endian.h>）。
# 全改完一共 3 行。
#
# 去掉 libudev 之后就能**全静态链接**（-static），一举消掉运行期对 glibc 版本
# 和任何 .so 的依赖 —— 构建机是 Ubuntu 还是 Debian、什么版本，都不再影响产物
# 能不能在设备上跑。
#
# ---------------------------------------------------------------------------
# 上游锚点（钉死，上游再动也不影响复现）
# ---------------------------------------------------------------------------
#   qrtr   andersson/qrtr  @ 27d2c9dfb4e8653ac314ebe2b7980fed2f4bac2e
#          （上游没打 tag，只能钉 SHA）
#   rmtfs  andersson/rmtfs @ v1.3 == b30a3eb38f9af283f18dbd3c7755653efc52c094
#          （pmOS 用的是 695d0668，比 v1.3 早；v1.3 是本仓实测可用的版本）
#
# 为什么用 `git fetch --depth 1 origin <ref>` 而不是 clone --branch：
#   钉的是 SHA 时能且只能这么取；对 tag 同样成立，于是两个仓库走同一套代码。

set -euo pipefail

say() { printf '[rmtfs] %s\n' "$*"; }

OUT=${1:?用法: build-rmtfs.sh <输出目录>}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PATCH_DIR="$REPO/tools/ci/rmtfs"

QRTR_URL=https://github.com/andersson/qrtr
QRTR_REF=27d2c9dfb4e8653ac314ebe2b7980fed2f4bac2e
RMTFS_URL=https://github.com/andersson/rmtfs
RMTFS_REF=v1.3

CC=${CC:-aarch64-linux-gnu-gcc}

# 中间产物一律落在 $OUT 下面（$OUT 本身是 git 忽略的构建输出目录），
# 这样 `make clean` 一次收干净，脚本里不需要任何删除命令。
WORK="$OUT/rmtfs-build"
mkdir -p "$WORK"

command -v "$CC" >/dev/null 2>&1 || {
  echo "[rmtfs] 找不到交叉编译器 $CC。CI 的 rootfs job 要装 gcc-aarch64-linux-gnu" >&2
  exit 1
}
say "编译器: $CC ($($CC -dumpmachine))"

# ---------------------------------------------------------------- 取源码
fetch() { # <url> <ref> <目标目录>
  local url=$1 ref=$2 dest=$3
  if [ -d "$dest/.git" ]; then
    say "已存在，跳过拉取: $dest"
    return
  fi
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch -q --depth 1 origin "$ref"
  git -C "$dest" checkout -q FETCH_HEAD
  say "取到 $url @ $ref → $(git -C "$dest" rev-parse --short HEAD)"
}

fetch "$QRTR_URL" "$QRTR_REF" "$WORK/qrtr"
fetch "$RMTFS_URL" "$RMTFS_REF" "$WORK/rmtfs"

# ---------------------------------------------------------------- 打补丁
cd "$WORK/rmtfs"
# qmi_rmtfs.c 是 qmic 从 qmi_rmtfs.qmi 生成的，仓库里存的是生成好的那份。
# 先 touch 一下，免得哪天 make 觉得 .qmi 比 .c 新、想去跑并不存在的 qmic。
[ -f qmi_rmtfs.c ] && touch qmi_rmtfs.c

if git apply --check "$PATCH_DIR/0001-sharedmem-drop-libudev-read-sysfs.patch" 2>/dev/null; then
  git apply "$PATCH_DIR/0001-sharedmem-drop-libudev-read-sysfs.patch"
  say "已应用 0001（去掉 libudev，改读 sysfs）"
elif grep -q RMTFS_USE_LIBUDEV sharedmem.c; then
  say "0001 已应用过，跳过"
else
  echo "[rmtfs] 0001 补丁打不上：上游 sharedmem.c 可能变了，需要重新生成补丁" >&2
  exit 1
fi

# ---------------------------------------------------------------- 编 libqrtr
# qrtr 上游是 meson 工程，但我们要的只是 libqrtr.a 里的三个 .c，
# 直接手工编译比配 meson 交叉文件省事得多，也不引入 meson 依赖。
say "编 libqrtr"
cd "$WORK/qrtr"
$CC -O2 -fPIC -Iinclude -Ilib -c lib/logging.c lib/qmi.c lib/qrtr.c
ar rcs "$WORK/libqrtr.a" logging.o qmi.o qrtr.o
say "  libqrtr.a: $(stat -c%s "$WORK/libqrtr.a" 2>/dev/null || stat -f%z "$WORK/libqrtr.a") 字节"

# ---------------------------------------------------------------- 编 rmtfs
say "编 rmtfs（全静态，无 libudev）"
cd "$WORK/rmtfs"
$CC -O2 -Wall -I"$WORK/qrtr/include" \
    -c qmi_rmtfs.c rmtfs.c rproc.c sharedmem.c storage.c util.c
# 注意这里**没有** -ludev：走了 sysfs 分支就不需要它了。
# -static 是关键：产物不依赖设备上任何 .so，也不受构建机 glibc 版本影响。
$CC -static -o "$WORK/rmtfs.bin" \
    qmi_rmtfs.o rmtfs.o rproc.o sharedmem.o storage.o util.o \
    "$WORK/libqrtr.a" -lpthread

# ---------------------------------------------------------------- 自检
# 静态链接要是没生效（比如哪天多出一个动态依赖），这里立刻失败，
# 不要等到刷进设备才发现 "GLIBC_2.xx not found"。
if file "$WORK/rmtfs.bin" 2>/dev/null | grep -q "statically linked"; then
  say "自检通过: 静态链接"
else
  echo "[rmtfs] 产物不是静态链接的，拒绝交付" >&2
  file "$WORK/rmtfs.bin" 2>/dev/null || true
  exit 1
fi

install -m 0755 "$WORK/rmtfs.bin" "$OUT/rmtfs"
say "产物: $OUT/rmtfs ($(stat -c%s "$OUT/rmtfs" 2>/dev/null || stat -f%z "$OUT/rmtfs") 字节)"
