#!/bin/bash
# tools/ci/build-lk2nd.sh —— 从零构建 lk2nd 刷机镜像（完整版 + 精简版）
#
#   tools/ci/build-lk2nd.sh <输出目录>
#
# 这是"从头刷入"的第一环：设备自带的原生 fastboot 只能刷 boot 分区，
# 而 lk2nd 就是刷进 boot 分区的那个二级引导——由它去扫描分区、
# 找到 /extlinux/extlinux.conf，才谈得上启动 Debian。
#
# 上游固定为 msm8916-mainline/lk2nd 的 19.0 tag（postmarketOS 用的就是这个版本，
# 设备上跑的 `lk2nd:version : 21.0-r0-postmarketos` 即由此打包而来）。
# 注意不是 msm8953-mainline/lk2nd —— 那个仓库的目录结构不一样
# （设备树在 dts/、设备表在 dts/rules.mk），我们的补丁对它不适用。
#
# 两个产物：
#   lk2nd.img         完整版（打 0001-0003）：保留全部 29 个设备条目
#   lk2nd-nomarkw.img 精简版（再打 0004）：去掉 msm8953-xiaomi-markw 与
#                     sdm450-xiaomi-rosy，强制 lk2nd 命中 odin 条目 ——
#                     只有命中 odin，占位 compatible 才会被替换成真实面板
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-lk2nd.sh <输出目录>}
LK2ND_VER=${LK2ND_VER:-19.0}
SRC=${SRC:-/tmp/lk2nd-src}

mkdir -p "$OUT"
say() { printf '[lk2nd] %s\n' "$*"; }

# ---------------------------------------------------------------- 源码
if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/makefile" ]; then
  say "拉取 lk2nd $LK2ND_VER (msm8916-mainline/lk2nd)"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  curl -sSL "https://github.com/msm8916-mainline/lk2nd/archive/refs/tags/${LK2ND_VER}.tar.gz" \
    | tar -xz --strip-components=1 -C "$SRC"
fi
[ -f "$SRC/makefile" ] || { echo "源码不完整: $SRC" >&2; exit 1; }
say "源码就绪: $SRC"

apply_patch() {
  local p="$1"
  say "应用 $(basename "$p")"
  # 用 patch 而不是 git apply：源码是 tarball 解出来的，没有 git 索引，
  # --3way 用不了；patch -p1 对这种场景更稳
  patch -p1 --forward --no-backup-if-mismatch -d "$SRC" < "$p" \
    || { echo "补丁应用失败: $p" >&2; exit 1; }
}

build() {
  make -j"$(nproc)" -C "$SRC" TOOLCHAIN_PREFIX=arm-none-eabi- PROJECT=lk2nd-msm8953 \
    >/tmp/lk2nd-build.log 2>&1 \
    || { echo "构建失败，日志尾部：" >&2; tail -30 /tmp/lk2nd-build.log >&2; exit 1; }
}

# ------------------------------------------------- 1) 完整版（0001-0003）
rm -rf "$SRC"
mkdir -p "$SRC"
curl -sSL "https://github.com/msm8916-mainline/lk2nd/archive/refs/tags/${LK2ND_VER}.tar.gz" \
  | tar -xz --strip-components=1 -C "$SRC"
for p in "$REPO"/lk2nd/0001-*.patch "$REPO"/lk2nd/0002-*.patch "$REPO"/lk2nd/0003-*.patch; do
  apply_patch "$p"
done
build
cp "$SRC/build-lk2nd-msm8953/lk2nd.img" "$OUT/lk2nd.img"
say "完整版: $OUT/lk2nd.img ($(stat -c%s "$OUT/lk2nd.img") 字节)"

# ------------------------------------------------- 2) 精简版（再打 0004）
apply_patch "$REPO/lk2nd/0004-*.patch"
# 增量重编即可：改的是设备表，make 会重编 QCDT 并重新打包
build
cp "$SRC/build-lk2nd-msm8953/lk2nd.img" "$OUT/lk2nd-nomarkw.img"
say "精简版: $OUT/lk2nd-nomarkw.img ($(stat -c%s "$OUT/lk2nd-nomarkw.img") 字节)"

# ---------------------------------------------------------------- 自检
say "自检：精简版里不应再出现 markw"
if strings "$OUT/lk2nd-nomarkw.img" | grep -q "xiaomi-markw"; then
  echo "  FAIL: 仍能搜到 xiaomi-markw" >&2; exit 1
fi
say "  xiaomi-markw: 0 处 ✅"
if strings "$OUT/lk2nd-nomarkw.img" | grep -q "smartisan-odin"; then
  say "  smartisan-odin: 保留 ✅"
else
  echo "  FAIL: odin 条目丢失" >&2; exit 1
fi
say "完成"
