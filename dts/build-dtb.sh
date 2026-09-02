#!/bin/bash
# 编译 ODIN 设备树（完整版 + 安全版）
#
# 用法: dts/build-dtb.sh
#
# 说明：
#   - 源码目录为宿主的 linux-msm8953（主线 6.19），预处理用它的 gcc -E，
#     编译用 dtc。内核自带的 scripts/dtc/dtc 是 aarch64-musl 二进制，
#     在 macOS 宿主和 debian 容器里都跑不起来，所以这里用系统 dtc。
#   - 已标定：容器 dtc 1.6.1（去掉 -Wno-interrupt_map）与宿主 dtc 1.7.2
#     编译 msm8953-smartisan-odin.dts 均**逐字节复现**仓库既有 dtb
#     （md5 e0ecc4ad23d02bce50997bdb011aa993），故管线可信。
#   - 容器内执行时内核树路径为 /work/linux-msm8953。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# 内核源码树位置（可用环境变量覆盖）
#   默认指向本仓库 tmp/ 下，不再依赖仓库外的绝对路径（AGENTS.md §1.5）。
#   注意：Makefile 的 dtb 目标会显式传 KDIR，不走这里的默认值。
KDIR="${KDIR:-$REPO/tmp/linux-msm8953}"
[ -d "$KDIR" ] || KDIR="/work/linux-msm8953"   # 仅在容器内手工跑时的挂载点兜底
[ -d "$KDIR" ] || { echo "找不到内核源码树: $KDIR（可显式传 KDIR 覆盖）" >&2; exit 1; }

DTC_BIN="$(command -v dtc || true)"
[ -n "$DTC_BIN" ] || { echo "需要 dtc (apt install device-tree-compiler / brew install dtc)" >&2; exit 1; }
DTC_VER="$("$DTC_BIN" --version | awk '{print $NF}')"

# dtc 1.6.x 不认识 interrupt_map 这个检查项
EXTRA_W=""
case "$DTC_VER" in
	1.7.*|1.8.*) EXTRA_W="-Wno-interrupt_map" ;;
esac

DTS_DIR="$KDIR/arch/arm64/boot/dts/qcom"
# 中间产物放本仓库 tmp/ 下，不用系统 $TMPDIR（AGENTS.md §1.6）
mkdir -p "$REPO/tmp"
TMP="$(mktemp -d "$REPO/tmp/dtbbuild-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

build_one() {
	local src="$1" out="$2" name
	name="$(basename "$out")"

	# 1) 预处理（#include 相对宿主 dts 目录解析）
	gcc -E -nostdinc \
		-I "$KDIR/scripts/dtc/include-prefixes" \
		-I "$DTS_DIR" \
		-undef -D__DTS__ -x assembler-with-cpp \
		-o "$TMP/pre.dts" "$src"

	# 2) 编译
	"$DTC_BIN" -o "$out" -b 0 \
		-i"$DTS_DIR/" \
		-i"$KDIR/scripts/dtc/include-prefixes" \
		-Wno-unique_unit_address -Wno-unit_address_vs_reg \
		-Wno-avoid_unnecessary_addr_size -Wno-alias_paths \
		-Wno-graph_child_address -Wno-simple_bus_reg \
		$EXTRA_W \
		"$TMP/pre.dts" 2> >(grep -viE 'interrupt_provider|smp2p' >&2)

	echo "  $name  $(stat -c %s "$out" 2>/dev/null || stat -f %z "$out") 字节"
}

echo "内核树: $KDIR"
echo "dtc:    $DTC_BIN (v$DTC_VER)"
echo

echo "[1/4] 完整版 msm8953-smartisan-odin.dtb"
build_one "$DTS_DIR/msm8953-smartisan-odin.dts" "$TMP/msm8953-smartisan-odin.dtb"

echo "[2/4] 安全版 msm8953-smartisan-odin-norolesw.dtb"
build_one "$HERE/msm8953-smartisan-odin-norolesw.dts" "$TMP/msm8953-smartisan-odin-norolesw.dtb"

# 面板写死版：给"boot 分区仍是未精简 lk2nd"的场景用（lk2nd 不会替换占位
# compatible，就由 DTB 自己直接指定面板）。刷入精简版 lk2nd 后应切回上面两个。
echo "[3/4] 面板写死 FT8716（完整版）msm8953-smartisan-odin-ft8716.dtb"
build_one "$HERE/msm8953-smartisan-odin-ft8716.dts" "$TMP/msm8953-smartisan-odin-ft8716.dtb"

echo "[4/4] 面板写死 FT8716（安全版）msm8953-smartisan-odin-ft8716-norolesw.dtb"
build_one "$HERE/msm8953-smartisan-odin-ft8716-norolesw.dts" \
	"$TMP/msm8953-smartisan-odin-ft8716-norolesw.dtb"

# Publish only after all four builds succeed. A failed build must never leave
# old DTBs looking like fresh output.
for f in "$TMP"/*.dtb; do
	install -m 0644 "$f" "$HERE/$(basename "$f")"
done

echo
echo "=== 面板写死版自检（应含 smartisan,odin-ft8716、无占位独留）==="
for f in "$HERE"/msm8953-smartisan-odin-ft8716.dtb "$HERE"/msm8953-smartisan-odin-ft8716-norolesw.dtb; do
	[ -f "$f" ] || continue
	printf "  %s\n" "$(basename "$f")"
	"$DTC_BIN" -I dtb -O dts "$f" 2>/dev/null \
		| grep -A3 'panel@0 {' | grep -m1 'compatible' | sed 's/^/    panel: /'
done

echo
echo "完成。安全版差异自检："
if command -v dtc >/dev/null; then
	dtc -I dtb -O dts -o "$TMP/safe.dts" "$HERE/msm8953-smartisan-odin-norolesw.dtb" 2>/dev/null
	printf "  usb-role-switch : %s (期望 0)\n" "$(grep -c 'usb-role-switch' "$TMP/safe.dts")"
	printf "  usb-c-connector : %s (期望 0)\n" "$(grep -c 'usb-c-connector' "$TMP/safe.dts")"
	printf "  dr_mode         : %s\n" "$(grep -o 'dr_mode = \"[a-z]*\"' "$TMP/safe.dts")"
fi
