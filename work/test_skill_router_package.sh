#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROUTER="$ROOT/skill-router"
. "$SCRIPT_DIR/skill_test_helpers.sh"

assert_exists "$ROUTER/SKILL.md" "路由器 SKILL.md 存在"
assert_exists "$ROUTER/agents/openai.yaml" "路由器 openai.yaml 存在"

if [ -f "$ROUTER/SKILL.md" ]; then
  body="$(cat "$ROUTER/SKILL.md")"
  name_line="$(awk 'NR==1{if($0!="---"){exit 1}; f=1; next} f && $0=="---"{exit} f && $0 ~ /^name:[[:space:]]*/{sub(/^name:[[:space:]]*/,""); print; exit}' "$ROUTER/SKILL.md")"
  description_line="$(awk 'NR==1{if($0!="---"){exit 1}; f=1; next} f && $0=="---"{exit} f && $0 ~ /^description:[[:space:]]*/{sub(/^description:[[:space:]]*/,""); print; exit}' "$ROUTER/SKILL.md")"

  assert_eq "$(head -1 "$ROUTER/SKILL.md")" "---" "路由器使用合法 frontmatter 起始标记"
  assert_eq "$name_line" "skill-router" "路由器 name 字段与目录名一致"
  [ -n "$description_line" ] && ok "路由器 description 字段非空" || not_ok "路由器 description 字段非空"

  chars="$(wc -m < "$ROUTER/SKILL.md" | tr -d ' ')"
  [ "$chars" -le 4000 ] && ok "路由器正文不超过 4000 字符" || not_ok "路由器正文不超过 4000 字符"

  assert_contains "$body" "最多三个候选" "路由器限制候选数量"
  assert_contains "$body" "没有把握时询问用户" "路由器低置信度询问"
  assert_contains "$body" "不得保存用户请求原文" "路由器不记录聊天内容"
  assert_contains "$body" "中文名称" "路由器用中文名称呈现候选"
  assert_contains "$body" "route-status" "路由器检查自动选择开关状态"
  assert_contains "$body" "高风险" "路由器要求高风险动作单独确认"
  assert_contains "$body" "skillctl route" "路由器指向本地只读路由命令"

  assert_not_contains "$body" "ai-product-teardown" "路由器正文不内嵌完整目录条目"
  assert_not_contains "$body" "lark-doc" "路由器正文不内嵌完整目录条目"
  assert_not_contains "$body" "http://" "路由器不引用外部网络地址"
  assert_not_contains "$body" "https://" "路由器不引用外部网络地址"

  case "$description_line" in
    *AI*产品*飞书*|*产品*飞书*) ok "描述覆盖多个领域但不逐条列举" ;;
    *) not_ok "描述覆盖多个领域但不逐条列举" ;;
  esac
fi

if [ -f "$ROUTER/agents/openai.yaml" ]; then
  yaml="$(cat "$ROUTER/agents/openai.yaml")"
  assert_contains "$yaml" "display_name:" "openai.yaml 提供中文显示名字段"
  assert_contains "$yaml" "short_description:" "openai.yaml 提供中文简介字段"
  assert_contains "$yaml" "技能调度器" "openai.yaml 显示名为中文"
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
