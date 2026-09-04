#!/bin/bash
# tools/ci/fetch-kernel.sh —— 把内核源码准备到 <目录>，钉在 KERNEL_SHA
#
#   tools/ci/fetch-kernel.sh <目录>
#
# 现在从**子模块** `ext/linux-msm8953` 取源码，不再直接 git clone。
# 为什么改用子模块（它顺带解决了一个老问题）：
#
#   老办法是 `git clone` + 三级回退（depth 1 → shallow-since → 整支 master），
#   因为 GitHub 只让取"某个 ref 能到达的"提交（`upload-pack: not our ref`）。
#   我们钉的 commit 是上游的历史提交，master 一往前走它就不再是 tip，按 SHA
#   取会被拒 —— 那段三级回退就是为了绕这个。
#
#   子模块天然绕开了它：gitlink 记录的是**确切 commit，而
#   `git submodule update --init` 会整量克隆（含全部历史），钉的 SHA 一定可达。
#   于是"取源码"退化成"校验子模块在不在、对不对，然后复制到工作目录"。
#
# 为什么还要复制一份到 <目录>，不直接拿子模块当构建树：
#   构建会往树里打补丁（patches/0001-0009）并生成大量中间产物，直接弄脏子模块
#   会让 `git status` 永远一片红，也容易误提交。子模块保持干净，构建树放 tmp/。
#
# 【子模块必需】本脚本不提供网络回退 —— 子模块没初始化就直接失败并给出该怎么
#   做。宁可响亮地失败，也不要悄悄编出一个"上游最新版"。
set -uo pipefail

DIR=${1:?用法: fetch-kernel.sh <目录>}
KERNEL_SHA=${KERNEL_SHA:-770e10fa15a00051eaef862e4cb2724f2f8fa568}
REPO=${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}
SRC=${ODIN_KERNEL_SRC:-$REPO/ext/linux-msm8953}

say() { echo "[fetch] $*"; }
die() { echo "[fetch] ❌ $*" >&2; exit 1; }

# 1) 子模块必须已初始化
if [ ! -e "$SRC/.git" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
	die "内核子模块未初始化：$SRC
      先跑：git submodule update --init ext/linux-msm8953
      （构建只要 ext/linux-msm8953 与 ext/lk2nd；参考用的 ext/smartisan-kernel 不必拉）"
fi

# 2) 子模块必须停在钉点。这里允许自动 checkout —— 子模块本来就是"记录确切 commit"
#    的机制，检出到钉点是它的正常用法，不算偷偷改上游。
head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "")
if [ "$head" != "$KERNEL_SHA" ]; then
	say "子模块 HEAD ${head:-（空）} ≠ 钉点 $KERNEL_SHA，检出到钉点"
	git -C "$SRC" checkout -q "$KERNEL_SHA" || die "子模块检出 $KERNEL_SHA 失败"
	head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "")
	[ "$head" = "$KERNEL_SHA" ] || die "检出后 HEAD 仍是 ${head:-（空）}，钉不住"
fi
say "子模块 HEAD 已钉在 $KERNEL_SHA"

# 3) 一致性校验：子模块记录的 commit（gitlink）必须和 KERNEL_SHA 是同一个。
#    两处都能钉版本，也就意味着两处会漂移。不校验的话会出现"子模块是 A、Makefile
#    要 B"，而 fetch 会默默把子模块 checkout 到 B，于是构建用了一个你没 review 过
#    的提交。宁可报错让人把两处对齐。
gitlink=$(git -C "$REPO" ls-tree HEAD ext/linux-msm8953 2>/dev/null | awk '{print $3}')
if [ -n "$gitlink" ] && [ "$gitlink" != "$KERNEL_SHA" ]; then
	die "内核版本两处不一致：
      子模块 gitlink  = $gitlink
      KERNEL_SHA     = $KERNEL_SHA
      请把两处对齐（改子模块就 commit 新 gitlink；改基线就同步 Makefile 与 workflow 的 env.KERNEL_SHA）"
fi

# 4) 复制到工作目录（幂等：已经在位且 HEAD 正确就跳过，省掉 1 GB 的复制）
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo "")" = "$KERNEL_SHA" ]; then
	say "目标 $DIR 已在位且 HEAD 正确，跳过复制"
	exit 0
fi

say "复制 $SRC → $DIR（本地文件系统复制，比重新 clone 快很多）"
rm -rf "$DIR"
mkdir -p "$(dirname "$DIR")" || die "无法建 $(dirname "$DIR")"
cp -a "$SRC" "$DIR" || die "复制失败（磁盘空间不够？）"

# 4) 复核：目录里的 HEAD 必须对得上。钉不住就宁可失败，不要悄悄编。
got=$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo "")
[ "$got" = "$KERNEL_SHA" ] || die "复制后 HEAD=$got，与钉点 $KERNEL_SHA 不符"
say "✅ 就绪：$DIR @ $KERNEL_SHA"
