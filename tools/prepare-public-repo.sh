#!/bin/bash
# tools/prepare-public-repo.sh —— 从本仓库生成一个「可公开」的干净副本
#
#   tools/prepare-public-repo.sh <目标目录> [脱敏规则文件]
#
# 例：
#   tools/prepare-public-repo.sh /tmp/odin-clean ~/.config/odin-port/replacements.txt
#
# 做三件事：
#   1) 剔除所有二进制文件（构建产物一律走 GitHub Release，不进版本库）
#   2) 剔除超大 blob（历史里曾误入库过 2GB 的刷机镜像）
#   3) 按规则脱敏（设备序列号 / MAC / 主机名等），**文件内容与提交信息都换**
#
# 源仓库完全不动 —— 输出是一个独立的、历史已重写的克隆。源仓库保留着完整的
# 调试历史与全部产物，公开的只是"能重建出这些东西的源码"。
#
# 关于脱敏规则文件为什么不入库：
#   规则里必然写着被替换掉的原字符串（否则匹配不到），一旦入库就等于把要隐藏的
#   东西又写进了公开仓库。所以规则文件放仓库外，缺省时跳过第 3 步。
#   格式是 git-filter-repo 的 `原串==>替换串`，一行一条，例如：
#       02:00:11:22:33:44==>02:00:0d:1d:00:01
#       ac1d4f00==><emmc-serial>
#
# 依赖：git-filter-repo（brew install git-filter-repo / pip install git-filter-repo）
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
TARGET=${1:?用法: prepare-public-repo.sh <目标目录> [脱敏规则文件]}
RULES=${2:-}

command -v git-filter-repo >/dev/null 2>&1 \
  || { echo "缺 git-filter-repo：brew install git-filter-repo" >&2; exit 1; }
[ -e "$TARGET" ] && { echo "目标已存在：$TARGET" >&2; exit 1; }
if [ -n "$RULES" ] && [ ! -f "$RULES" ]; then
  echo "脱敏规则文件不存在：$RULES" >&2; exit 1
fi

say() { printf '\033[36m[pub]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[pub]\033[0m %s\n' "$*"; }

# file(1) 不认作 text/JSON/empty 的都算二进制。
# 写成函数而不是内联 case：macOS 自带的 bash 3.2 解析不了 $( ) 里带 ;; 的 case
# （最小复现都会报 syntax error near unexpected token ';;'）。
is_binary() {
  case "$(file -b "$1" 2>/dev/null)" in
    *text*|*ASCII*|*UTF-8*|*JSON*|*Unicode*|*empty*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------- 1. 克隆
say "克隆 → $TARGET"
git clone -q "$REPO" "$TARGET" 2>/dev/null
BEFORE=$(du -sk "$TARGET/.git" | cut -f1)
say "克隆完成，.git = $(( BEFORE / 1024 )) MiB"

# ---------------------------------------------------------------- 2. 二进制清单
BINLIST=$(mktemp -t odin-binlist)
( cd "$TARGET"
  git ls-files | while read -r f; do
    [ -f "$f" ] || continue
    if is_binary "$f"; then printf '%s\n' "$f"; fi
  done ) > "$BINLIST"
say "待剔除二进制：$(wc -l < "$BINLIST" | tr -d ' ') 个"

# ---------------------------------------------------------------- 3. 重写历史
say "重写历史（git-filter-repo）..."
ARGS=(--force --invert-paths --paths-from-file "$BINLIST" --strip-blobs-bigger-than 250K)
[ -n "$RULES" ] && ARGS+=(--replace-text "$RULES" --replace-message "$RULES")
( cd "$TARGET" && git filter-repo "${ARGS[@]}" >/dev/null 2>&1 )
rm -f "$BINLIST"
AFTER=$(du -sk "$TARGET/.git" | cut -f1)
ok "完成：.git $(( BEFORE / 1024 )) MiB → $(( AFTER / 1024 )) MiB"

# ---------------------------------------------------------------- 4. 验证
say "验证..."
fail=0
note() { printf '  %-28s %s\n' "$1" "$2"; }

remain=$(cd "$TARGET" && git ls-files | while read -r f; do
    [ -f "$f" ] || continue
    if is_binary "$f"; then printf '%s\n' "$f"; fi
  done | wc -l | tr -d ' ')
[ "$remain" -eq 0 ] && note "残留二进制" "0" || { note "残留二进制" "$remain 个"; fail=1; }

big=$(cd "$TARGET" && git ls-files | while read -r f; do
    [ -f "$f" ] || continue
    s=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
    if [ "${s:-0}" -gt 250000 ]; then printf '%s\n' "$f"; fi
  done | wc -l | tr -d ' ')
[ "$big" -eq 0 ] && note ">250KB 的文件" "0" || { note ">250KB 的文件" "$big 个"; fail=1; }

# 敏感串：扫全部历史（含提交信息），规则存在就逐条查原串
if [ -n "$RULES" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    old=${line%%==>*}
    [ -n "$old" ] || continue
    n=$(cd "$TARGET" && git log --all -p 2>/dev/null | grep -c -F "$old" || true)
    [ "${n:-0}" -eq 0 ] && note "敏感串 '$old'" "0 处" \
                        || { note "敏感串 '$old'" "$n 处残留"; fail=1; }
  done < "$RULES"
fi

# 通用：私钥
# 注意要 grep -v 掉本脚本自己那行——否则这条 grep 模式本身会被算成一次命中
n=$(cd "$TARGET" && git log --all -p 2>/dev/null \
    | grep -F "BEGIN PRIVATE KEY" | grep -cv "grep -c -F" || true)
[ "${n:-0}" -eq 0 ] && note "私钥" "0 处" || { note "私钥" "$n 处残留"; fail=1; }

commits=$(cd "$TARGET" && git log --oneline | wc -l | tr -d ' ')
files=$(cd "$TARGET" && git ls-files | wc -l | tr -d ' ')
note "提交数 / 跟踪文件数" "$commits / $files"

echo
if [ "$fail" -eq 0 ]; then
  ok "全部检查通过"
else
  echo "有未通过项，先处理再推送" >&2
  exit 1
fi

cat <<NEXT

下一步（filter-repo 会摘掉 origin，需要自己加回来）：
  cd $TARGET
  git remote add origin git@github.com:<用户>/<仓库>.git
  git push -u origin main

二进制产物请用 GitHub Release 单独发布，不要塞回版本库：
  gh release create v0.1 <镜像/固件/模块> ...
NEXT
