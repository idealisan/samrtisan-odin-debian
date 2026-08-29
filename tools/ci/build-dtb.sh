#!/bin/bash
# tools/ci/build-dtb.sh —— 从零编译四个 ODIN 设备树
#
#   tools/ci/build-dtb.sh <输出目录>
#
# 依赖内核源码树（里面要有 msm8953.dtsi 等），用 patches/0007 把 odin 的 DTS
# 放进去，再用仓库里的 dts/build-dtb.sh 编译。CI 里从固定 commit 拉内核，
# 因此不受上游后续改动影响。
#
# 四个产物：
#   msm8953-smartisan-odin.dtb                 自动识别面板（完整版）
#   msm8953-smartisan-odin-norolesw.dtb        自动识别面板（安全版，USB 固定 device）
#   msm8953-smartisan-odin-ft8716.dtb          面板写死 FT8716（完整版）  ← 发布默认
#   msm8953-smartisan-odin-ft8716-norolesw.dtb 面板写死 FT8716（安全版）  ← 首刷默认
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
OUT=${1:?用法: build-dtb.sh <输出目录>}
KDIR=${KDIR:-/tmp/linux-msm8953}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/msm8953-mainline/linux.git}
# 上游基线：Linux 6.19。注意不是本地 odin-wip 的 HEAD（那个已经含我们的补丁），
# 而是它下面的第一个上游提交 —— 补丁由本脚本打，源码必须是干净的。
KERNEL_SHA=${KERNEL_SHA:-05f7e89ab9731565d8a62e3b5d1ec206485eeb0b}

mkdir -p "$OUT"
# 必须转绝对路径：下面会 cd 进内核树，届时 "out/kernel" 这种相对路径就指到别处去了
# （CI 上表现为编译 22 分钟成功、最后 cp 时 "No such file or directory"）
OUT=$(cd "$OUT" && pwd)
say() { printf '[dtb] %s\n' "$*"; }

# ---------------------------------------------------------------- 内核源码
bash "$REPO/tools/ci/fetch-kernel.sh" "$KDIR"
say "内核源码就绪"

# ---------------------------------------------------------------- 设备树补丁
# DTB 只依赖 0007（设备树）；0001-0006/0008 是驱动，编 DTB 用不到，
# 少打几个补丁就少几个失配点。
say "应用设备树补丁 0007"
if [ -f "$KDIR/arch/arm64/boot/dts/qcom/msm8953-smartisan-odin.dts" ]; then
  say "  已打过，跳过"
else
  patch -p1 --forward -d "$KDIR" < "$REPO"/patches/0007-*.patch \
    || { echo "0007 应用失败" >&2; exit 1; }
fi

# ---------------------------------------------------------------- 编译
say "编译四个 DTB（内核树: ${KDIR}）"
KDIR="$KDIR" bash "$REPO/dts/build-dtb.sh"

for f in "$REPO"/dts/*.dtb; do
  cp -f "$f" "$OUT/"
  say "  $(basename "$f")  $(stat -c%s "$f") 字节"
done

# ---------------------------------------------------------------- 自检
say "自检"
fail=0
chk() { # chk <文件> <应含字符串> <说明>
  if grep -qa "$2" "$OUT/$1"; then say "  ✅ $3"; else echo "  ❌ $3" >&2; fail=1; fi
}
for v in ft8716 ft8716-norolesw; do
  chk "msm8953-smartisan-odin-$v.dtb" "smartisan,odin-ft8716" "面板写死 FT8716 ($v)"
done
# 安全版不应带 Type-C 角色切换
if dtc -I dtb -O dts "$OUT/msm8953-smartisan-odin-ft8716-norolesw.dtb" 2>/dev/null \
   | grep -q "usb-role-switch"; then
  echo "  ❌ 安全版仍含 usb-role-switch" >&2; fail=1
else
  say "  ✅ 安全版无 usb-role-switch"
fi
[ "$fail" -eq 0 ] || exit 1
say "完成"
