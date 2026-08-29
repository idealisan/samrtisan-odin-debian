#!/bin/bash
# tools/ci/build-kernel.sh —— 交叉编译 ODIN 的 arm64 内核与模块
#
#   tools/ci/build-kernel.sh <输出目录>
#
# 内核源码固定到某个 commit（默认是我们一直在用的那个），打上 patches/ 下
# 全部补丁，用仓库里的 config 编译。产物：
#   vmlinuz          arch/arm64/boot/Image
#   modules.tar      内核模块树（rootfs 阶段装进镜像）
#
# 为什么要固定 commit：上游一动，补丁就可能打不上、或者编译出行为不同的内核。
# CI 的价值恰恰在于"同一个输入必然得到同一个输出"。
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-kernel.sh <输出目录>}
KDIR=${KDIR:-/tmp/linux-msm8953}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/msm8953-mainline/linux.git}
# 上游基线：Linux 6.19（我们本地 odin-wip 分支就是从这里切出去的）。
# 补丁由本脚本打，源码必须是干净的上游。
KERNEL_SHA=${KERNEL_SHA:-05f7e89ab9731565d8a62e3b5d1ec206485eeb0b}
CROSS=${CROSS:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

mkdir -p "$OUT"
say() { printf '[kernel] %s\n' "$*"; }

# ---------------------------------------------------------------- 源码
"$REPO/tools/ci/fetch-kernel.sh" "$KDIR"
cd "$KDIR"
say "内核树: $KDIR ($(git rev-parse --short HEAD 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------- 补丁
# 0001-0008 全打：CI 的价值之一就是持续证明这些补丁仍适用于固定 commit
for p in "$REPO"/patches/*.patch; do
  say "应用 $(basename "$p")"
  patch -p1 --forward --no-backup-if-mismatch < "$p" \
    || { echo "补丁应用失败: $p" >&2; exit 1; }
done

# ---------------------------------------------------------------- 配置
cp "$REPO/config-postmarketos-qcom-msm8953.aarch64" .config
make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig >/dev/null

# ---------------------------------------------------------------- 编译
say "编译 Image + modules（$JOBS 线程，这一步在 CI 上要跑几十分钟）"
make -j"$JOBS" ARCH=arm64 CROSS_COMPILE="$CROSS" Image modules \
  >/tmp/odin-kernel-build.log 2>&1 \
  || { echo "构建失败，日志尾部：" >&2; tail -40 /tmp/odin-kernel-build.log >&2; exit 1; }

# ---------------------------------------------------------------- 产物
cp arch/arm64/boot/Image "$OUT/vmlinuz"
say "vmlinuz: $(stat -c%s "$OUT/vmlinuz") 字节"

MODSTAGE=$(mktemp -d)
make ARCH=arm64 CROSS_COMPILE="$CROSS" INSTALL_MOD_PATH="$MODSTAGE" modules_install \
  >/dev/null 2>&1
tar -cf "$OUT/modules.tar" -C "$MODSTAGE" .
rm -rf "$MODSTAGE"
say "modules.tar: $(stat -c%s "$OUT/modules.tar") 字节"

# ---------------------------------------------------------------- 自检
say "自检：新增驱动应编进模块或内核"
for drv in panel-ft8716 panel-r69006 panel-nt36672; do
  if find . -name "${drv}.ko" | grep -q .; then
    say "  ✅ ${drv}.ko 已生成"
  else
    echo "  ❌ ${drv}.ko 缺失" >&2; exit 1
  fi
done
say "完成"
