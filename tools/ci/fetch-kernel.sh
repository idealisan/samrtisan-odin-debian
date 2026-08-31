#!/bin/bash
# tools/ci/fetch-kernel.sh —— 把内核源码取到固定 commit
#
#   tools/ci/fetch-kernel.sh <目录>
#
# 为什么不能简单 `git fetch --depth 1 origin <sha>`：
#   GitHub 只允许取"某个 ref 能到达的"提交（`upload-pack: not our ref` 就是这个错）。
#   我们钉的那个 commit 是上游 master 上的历史提交，一旦 master 往前走，
#   它就不是 tip 了，按 SHA 取会被拒。
#
# 所以策略是三级：
#   1) 先试 `fetch --depth 1 origin <sha>`（当前仍是 tip 时最快）
#   2) 退回 `fetch --shallow-since=<sha 前一天> origin master`：按时间截断，
#      只要钉的 commit 不早于这个日期就一定能取到，且不会把整个仓库拖下来
#   3) 再退回整支 master（最慢，但不会失败）
# 最后一律 `git checkout <sha>` 并校验 HEAD 对得上——钉不住就宁可失败，
# 也不要悄悄编出一个"上游最新版"。
set -euo pipefail

DIR=${1:?用法: fetch-kernel.sh <目录>}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/msm8953-mainline/linux.git}
# 这里的默认值必须跟 Makefile 的 KERNEL_SHA / KERNEL_BRANCH / KERNEL_SINCE 一致
# —— make 会显式传值覆盖，但直接手工跑本脚本时会用到默认值。四处钉点
# （Makefile、本文件、workflow 的 env、文档表格）必须一起改，理由见 docs/05 第六节。
KERNEL_SHA=${KERNEL_SHA:-770e10fa15a00051eaef862e4cb2724f2f8fa568}
KERNEL_BRANCH=${KERNEL_BRANCH:-6.19.5/main}
# shallow-since 的日期：钉住的那个 commit 的前一天（见 KERNEL_SINCE 注释）
KERNEL_SINCE=${KERNEL_SINCE:-2026-01-01}

say() { printf '[fetch] %s\n' "$*"; }

if [ -f "$DIR/Makefile" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$KERNEL_SHA" ]; then
  say "已在 ${KERNEL_SHA}，复用"
  exit 0
fi

rm -rf "$DIR"; mkdir -p "$DIR"
git init -q "$DIR"
git -C "$DIR" remote add origin "$KERNEL_REPO"

say "目标 ${KERNEL_SHA:0:12}（上游 ${KERNEL_BRANCH}）"

ok=0
if git -C "$DIR" fetch -q --depth 1 origin "$KERNEL_SHA" 2>/dev/null; then
  say "  按 SHA 直取成功"
  ok=1
fi
if [ "$ok" -eq 0 ]; then
  say "  按 SHA 直取被拒（不是 tip），改用 --shallow-since=$KERNEL_SINCE"
  if git -C "$DIR" fetch -q --shallow-since="$KERNEL_SINCE" origin "$KERNEL_BRANCH" 2>/dev/null; then
    ok=1
  fi
fi
if [ "$ok" -eq 0 ]; then
  say "  再退回整支 $KERNEL_BRANCH"
  git -C "$DIR" fetch -q origin "$KERNEL_BRANCH"
fi

git -C "$DIR" checkout -q "$KERNEL_SHA" 2>/dev/null \
  || { echo "取到的历史里没有 $KERNEL_SHA" >&2; exit 1; }

got=$(git -C "$DIR" rev-parse HEAD)
[ "$got" = "$KERNEL_SHA" ] || { echo "HEAD=$got 与期望 $KERNEL_SHA 不符" >&2; exit 1; }
say "  HEAD 已钉在 ${got:0:12}"
