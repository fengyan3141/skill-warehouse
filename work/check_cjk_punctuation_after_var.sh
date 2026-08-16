#!/bin/bash
# 静态扫描：裸变量 $var（未加花括号）后面直接紧跟非 ASCII 字节（如中文/全角标点），
# 在 bash 3.2 下会被误判成变量名的一部分，触发 set -u 下的 "unbound variable"。
# 这个坑在本项目已经踩过三次（见 CLAUDE.md「已知坑」），bash -n 语法检查完全
# 抓不出这种运行时问题，只能靠这类静态扫描在写代码时就拦下来。
#
# 判定条件：
#   - 裸 $var（$ 后面直接是字母/下划线，不是 { ）
#   - 后面没有任何分隔（空格、引号、花括号等），直接是一个字节 >= 0x80 的字符
#   - 跳过整行都是注释的行（行首去空白后以 # 开头）——注释里的示例文字不会被
#     shell 求值，不构成真实风险
# 用 LC_ALL=C 让 awk 按字节而不是按 UTF-8 字符处理，否则高位字节会触发
# "multibyte conversion failure"。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# 仓库扁平化之后 work/ 是 $ROOT 的子目录，$ROOT 一次递归就能扫到，不用再
# 像以前包和 work/ 是两个平级目录时那样分两个起点传给 find（那样传会把
# work/ 底下的文件扫两遍，命中和计数都翻倍）。用 -path 排除 .git，不然
# 仓库初始化后 hooks 之类的东西也会被扫进来。
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( -name '*.sh' -o -name 'skillctl' \) -print 2>/dev/null | sort)

if [ "${#files[@]}" -eq 0 ]; then
  printf '中文标点扫描：未找到任何待扫描脚本，检查路径是否正确\n' >&2
  exit 1
fi

low=$'\x80'
high=$'\xff'

hits="$(LC_ALL=C awk -v low="$low" -v high="$high" '
  BEGIN { pat = "\\$[A-Za-z_][A-Za-z0-9_]*[" low "-" high "]" }
  {
    trimmed = $0
    sub(/^[ \t]+/, "", trimmed)
    if (trimmed ~ /^#/) next
    if ($0 ~ pat) print FILENAME ":" FNR ":" $0
  }
' "${files[@]}" 2>&1)"

if [ -n "$hits" ]; then
  printf '中文标点扫描：命中裸 $变量 紧跟非 ASCII 字符，可能在 bash 3.2 下触发 unbound variable，请改成 ${变量} 界定边界：\n\n'
  printf '%s\n' "$hits"
  exit 1
fi

printf '中文标点扫描：通过（扫描 %s 个脚本，0 命中）\n' "${#files[@]}"
exit 0
