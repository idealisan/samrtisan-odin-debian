#!/bin/bash
# 把 patches/ 下的补丁打进内核源码树。
#
#   apply-patches.sh <内核树> <补丁目录>
#
# 关键是**可重复执行**：改了配置想在既有树上重编内核是家常便饭，而朴素的
# `patch --forward` 遇到"已应用过"会返回 1，在 set -e 下直接把构建打断。
#
# 难点在于"已应用"没有一种万能判法，要按三种情形分别处理：
#
#   1. 反向能干净应用  ⇒ 这个补丁的效果还在，跳过。
#   2. 正向能干净应用  ⇒ 还没打过，打上。
#   3. 两边都不行      ⇒ 多半是"打了，但被后面的补丁改过"，于是反向还原不了。
#      本项目里就有现成的例子：0005 新建 drivers/gpu/drm/panel/panel-ft8716.c，
#      而 0008 又改了同一个文件 —— 0005 因此无法反向还原。
#      这种情形若补丁是"新建文件"且目标文件已存在，就认为已打过。
#
# 除此之外一律报错退出，不做"看起来过了"的猜测 —— 静默跳过一个没打上的补丁，
# 产出的内核会缺某个驱动，而编译阶段完全看不出来。
set -uo pipefail

KDIR=${1:?用法: apply-patches.sh <内核树> <补丁目录>}
PDIR=${2:?用法: apply-patches.sh <内核树> <补丁目录>}

[ -d "$KDIR" ] || { echo "[patches] 内核树不存在: $KDIR" >&2; exit 1; }
[ -d "$PDIR" ] || { echo "[patches] 补丁目录不存在: $PDIR" >&2; exit 1; }

cd "$KDIR" || exit 1

rc=0
for p in $(ls "$PDIR"/*.patch 2>/dev/null | sort); do
	name=$(basename "$p")
	if git apply --check --reverse "$p" 2>/dev/null; then
		echo "[patches]   $name —— 已打过，跳过"
	elif git apply --check "$p" 2>/dev/null; then
		echo "[patches]   $name —— 打上"
		git apply "$p" || { echo "[patches]   ❌ $name 应用失败" >&2; rc=1; }
	elif [ "$(grep -c '^--- /dev/null' "$p")" -gt 0 ]; then
		# 新建文件的补丁：逐个确认它要创建的文件是否都已存在
		missing=0
		for f in $(grep -E '^\+\+\+ b/' "$p" | sed 's|^\+\+\+ b/||'); do
			[ -e "$f" ] || { missing=1; echo "[patches]     缺文件: $f"; }
		done
		if [ "$missing" -eq 0 ]; then
			echo "[patches]   $name —— 已打过（目标文件在，且被后续补丁改过，故无法反向校验），跳过"
		else
			echo "[patches]   ❌ $name 要创建的文件不存在，也不像打过" >&2
			rc=1
		fi
	else
		echo "[patches]   ❌ $name 既不能正向也不能反向应用（源码与补丁不匹配？）" >&2
		rc=1
	fi
done

exit $rc
