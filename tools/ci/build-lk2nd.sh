#!/bin/bash
# tools/ci/build-lk2nd.sh —— 从零构建 lk2nd 刷机镜像（完整版 + 精简版）
#
#   tools/ci/build-lk2nd.sh <输出目录>
#
# 这是"从头刷入"的第一环：设备自带的原生 fastboot 只能刷 boot 分区，
# 而 lk2nd 就是刷进 boot 分区的那个二级引导——由它去扫描分区、
# 找到 /extlinux/extlinux.conf，才谈得上启动 Debian。
#
# 上游固定为 msm8916-mainline/lk2nd 的 23.1 tag。
# 选 23.x 而不是设备上跑过的 21.0-r0-postmarketOS，是因为我们的补丁按 23.x
# 的 lk2nd/device/dts/msm8953/rules.mk 生成：19.x 的设备表只有 21 个条目且
# 行尾是两个空格，21.0 把 flipkart-rimob 改名成 billion-rimob、还缺
# qrd-sku3 / wingtech / sdm632-mtp-3 等条目 —— 0002 的上下文对不上，直接
# "Hunk #1 FAILED"。23.0 与 23.1 的 rules.mk 逐字节一致，取较新的 23.1。
# 注意不是 msm8953-mainline/lk2nd —— 那个仓库的目录结构不一样。
#
# 两个产物：
#   lk2nd.img         完整版（打 0001-0003）：保留全部 29 个设备条目
#   lk2nd-nomarkw.img 精简版（再打 0004）：去掉 msm8953-xiaomi-markw 与
#                     sdm450-xiaomi-rosy，强制 lk2nd 命中 odin 条目 ——
#                     只有命中 odin，占位 compatible 才会被替换成真实面板
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-lk2nd.sh <输出目录>}
LK2ND_VER=${LK2ND_VER:-23.1}
SRC=${SRC:-/tmp/lk2nd-src}

mkdir -p "$OUT"
# 必须转绝对路径：下面会 cd 进内核树，届时 "out/kernel" 这种相对路径就指到别处去了
# （CI 上表现为编译 22 分钟成功、最后 cp 时 "No such file or directory"）
OUT=$(cd "$OUT" && pwd)
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

# LK2ND_VERSION 必须显式传：pmOS 也是这么做的（pmaports/main/lk2nd/APKBUILD 里
#   make LK2ND_VERSION="$pkgver-r$pkgrel-postmarketos" ...
# 这就是为什么原厂镜像上报的是 `21.0-r0-postmarketos` —— 那是构建时注入的，
# 不是源码里写死的。不传的话版本串不可识别，排障时连"跑的是哪一份"都分不清。
build() {
  local variant="${1:?用法: build <变体名>}"
  local ver="${LK2ND_VER}-${variant}-odinport"
  say "构建 ${variant} 版（LK2ND_VERSION=${ver}）"
  if ! make -j"$(nproc)" -C "$SRC" TOOLCHAIN_PREFIX=arm-none-eabi- \
        LK2ND_VERSION="$ver" \
        PROJECT=lk2nd-msm8953 2>&1 | tee /tmp/lk2nd-build.log; then
    echo "lk2nd 构建失败，日志见上面" >&2
    exit 1
  fi
}

# ------------------------------------------------- 1) 完整版（0001-0003）
rm -rf "$SRC"
mkdir -p "$SRC"
curl -sSL "https://github.com/msm8916-mainline/lk2nd/archive/refs/tags/${LK2ND_VER}.tar.gz" \
  | tar -xz --strip-components=1 -C "$SRC"
for p in "$REPO"/lk2nd/0001-*.patch "$REPO"/lk2nd/0002-*.patch "$REPO"/lk2nd/0003-*.patch; do
  apply_patch "$p"
done
build full
cp "$SRC/build-lk2nd-msm8953/lk2nd.img" "$OUT/lk2nd.img"
say "完整版: $OUT/lk2nd.img ($(stat -c%s "$OUT/lk2nd.img") 字节)"

# ------------------------------------------------- 2) 精简版（再打 0004）
# 注意：glob 必须写在引号外面，写成 "$REPO/lk2nd/0004-*.patch" 整串被引号包住时
# 不会展开，patch 会拿到一个字面量的星号文件名然后 No such file or directory
apply_patch "$REPO"/lk2nd/0004-*.patch
# 增量重编即可：改的是设备表，make 会重编 QCDT 并重新打包
build nomarkw
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
