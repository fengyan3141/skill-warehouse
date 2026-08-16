#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PACKAGE="$ROOT"
EVALUATOR="$PACKAGE/evaluate-router.sh"
SKILLCTL="$PACKAGE/skillctl"
FULL_FIXTURES="$PACKAGE/config/route-evals.tsv"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
ENV_HOME=""

cleanup() {
  [ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
  [ -n "$ENV_HOME" ] && rm -rf "$ENV_HOME"
}

on_exit() {
  local status=$?
  cleanup
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

make_catalog() {
  local catalog="$1"
  printf '%s\n' \
    $'ai-product-teardown\tskills/ai-product-teardown\tAI 产品拆解\t产品拆解,竞品拆解\tproduct\t产品,拆解,竞品,架构\t简单评价\t系统拆解 AI 产品' \
    $'ai-pm-resume-writer\tskills/ai-pm-resume-writer\tAI 产品经理简历\t简历优化,岗位简历,改简历\tcareer\t简历,JD,求职,项目经历\t普通写作\t优化 AI 产品经理简历' \
    $'lark-doc\tskills/lark-doc\t飞书文档\t云文档,文档编辑,读取飞书文档\tlark\t飞书文档,docx,wiki\t表格,多维表格,云盘\t读取和编辑飞书文档' > "$catalog"
}

make_small_fixtures() {
  local path="$1" wrong_id="$2" first_id
  first_id="${wrong_id:-ai-product-teardown}"
  {
    printf 'class\texpected_id\tquery\n'
    printf 'clear\t%s\t%s\n' "$first_id" "帮我系统拆解一下这个 AI 产品"
    printf '%s\n' \
    $'clear\tai-pm-resume-writer\t我要投 AI 产品经理，帮我针对 JD 改简历' \
    $'clear\tlark-doc\t读取并修改这个飞书文档' \
    $'clear\tai-product-teardown\t请做竞品分析和产品架构拆解' \
    $'clear\tai-pm-resume-writer\t帮我优化产品经理项目经历' \
    $'clear\tlark-doc\t查看这个云文档' \
    $'ambiguous\t\t帮我整理一下这个材料' \
    $'ambiguous\t\t帮我同时拆解产品并优化简历' \
    $'none\t\t你好，介绍一下你自己' \
    $'none\t\t把这句话翻译成英文'
  } > "$path"
}

make_full_catalog() {
  local catalog="$1"
  awk -F '\t' 'BEGIN { OFS="\t" }
    $1 !~ /^#/ && NF == 6 {
      print $1, "skills/" $1, $2, $3, $4, $5, $6, "合成测试用的简短说明"
    }
  ' "$PACKAGE/config/aliases.tsv" > "$catalog"
}

new_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-evaluation-test.XXXXXX")"
  FIXTURE_LIBRARY="$TEST_ROOT/library"
  mkdir -p "$FIXTURE_LIBRARY"
  make_catalog "$FIXTURE_LIBRARY/catalog.tsv"
}

write_gate_record() {
  local library="$1" evaluated_at="$2" top1="$3" top3="$4" ambiguous="$5" auto_route="$6" catalog_hash
  catalog_hash="$(shasum -a 256 "$library/catalog.tsv" | awk '{ print $1 }')"
  mkdir -p "$library/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$catalog_hash" "$evaluated_at" "$top1" "$top3" "$ambiguous" "$auto_route" > "$library/state/router-gate.tsv"
}

assert_gate_disabled() {
  local library="$1" label="$2" output
  output="$(SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route-status)"
  assert_eq "$output" "自动选择未启用" "$label"
}

assert_gate_enabled() {
  local library="$1" label="$2" output
  output="$(SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route-status)"
  assert_eq "$output" "自动选择已启用" "$label"
}

test_route_status_rejects_forged_or_expired_gate() {
  local library="$1" now catalog_hash
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  catalog_hash="$(shasum -a 256 "$library/catalog.tsv" | awk '{ print $1 }')"

  write_gate_record "$library" "$now" "0.899999" "1.000000" "0.000000" "enabled"
  assert_gate_disabled "$library" "伪造的低 Top1 状态不允许自动选择"
  write_gate_record "$library" "$now" "1.000000" "0.979999" "0.000000" "enabled"
  assert_gate_disabled "$library" "伪造的低 Top3 状态不允许自动选择"
  write_gate_record "$library" "$now" "1.000000" "1.000000" "0.050001" "enabled"
  assert_gate_disabled "$library" "伪造的高歧义误选状态不允许自动选择"
  write_gate_record "$library" "$now" "not-a-number" "1.000000" "0.000000" "enabled"
  assert_gate_disabled "$library" "非数值指标状态不允许自动选择"
  write_gate_record "$library" "2026/08/14 12:00:00" "1.000000" "1.000000" "0.000000" "enabled"
  assert_gate_disabled "$library" "非 UTC 时间格式状态不允许自动选择"
  write_gate_record "$library" "2000-01-01T00:00:00Z" "1.000000" "1.000000" "0.000000" "enabled"
  assert_gate_disabled "$library" "超过三十天的状态不允许自动选择"

  mkdir -p "$library/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\textra\n' "$catalog_hash" "$now" "1.000000" "1.000000" "0.000000" "enabled" > "$library/state/router-gate.tsv"
  assert_gate_disabled "$library" "字段数不是六的状态不允许自动选择"
}

test_route_status_uses_exact_decimal_thresholds() {
  local library="$1" now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  write_gate_record "$library" "$now" "0.89999999999999999" "1.000000" "0.000000" "enabled"
  assert_gate_disabled "$library" "超长小数低于 0.90 不允许自动选择"
  write_gate_record "$library" "$now" "1.000000" "0.97999999999999999" "0.000000" "enabled"
  assert_gate_disabled "$library" "超长小数低于 0.98 不允许自动选择"
  write_gate_record "$library" "$now" "1.000000" "1.000000" "0.0500000000000000001" "enabled"
  assert_gate_disabled "$library" "超长小数高于 0.05 不允许自动选择"

  write_gate_record "$library" "$now" "0.90" "0.98" "0.05" "enabled"
  assert_gate_enabled "$library" "精确阈值状态允许自动选择"
}

test_bad_fixture_disables_auto_route() {
  local fixture output route_output route_status status
  new_fixture
  fixture="$TEST_ROOT/bad.tsv"
  make_small_fixtures "$fixture" "lark-doc"

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" 2>&1)"
  status=$?
  set -e

  [ "$status" -ne 0 ] && ok "低于阈值的夹具返回非零" || not_ok "低于阈值的夹具返回非零"
  assert_contains "$output" "AUTO_ROUTE=disabled" "低于阈值的夹具禁用自动选择"

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" --write-status --apply 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] && ok "失败评测写状态后仍返回非零" || not_ok "失败评测写状态后仍返回非零"
  assert_exists "$FIXTURE_LIBRARY/state/router-gate.tsv" "失败评测仅在双显式旗标下记录关闭状态"
  assert_eq "$(awk -F '\t' 'NR == 1 { print $6 }' "$FIXTURE_LIBRARY/state/router-gate.tsv")" "disabled" "失败评测状态记录为关闭"
  route_status="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$SKILLCTL" route-status)"
  assert_eq "$route_status" "自动选择未启用" "失败评测状态不允许自动选择"
  route_output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$SKILLCTL" route "帮我系统拆解一下这个 AI 产品")"
  assert_contains "$route_output" $'\tAI 产品拆解\t' "关闭自动选择时仍保留中文候选"
}

test_good_fixture_requires_explicit_write_pair() {
  local fixture output status route_status
  new_fixture
  fixture="$TEST_ROOT/good.tsv"
  make_small_fixtures "$fixture" ""

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "达标夹具评测成功"
  assert_contains "$output" "AUTO_ROUTE=enabled" "达标夹具启用自动选择"
  assert_eq "$(printf '%s\n' "$output" | awk 'END { print NR }')" "4" "评测指标逐行输出"
  assert_not_exists "$FIXTURE_LIBRARY/state/router-gate.tsv" "默认评测不写状态文件"

  set +e
  route_status="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$SKILLCTL" route-status 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "route-status 命令存在"
  assert_eq "$route_status" "自动选择未启用" "缺少状态文件时自动选择关闭"

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" --write-status 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] && ok "缺少 apply 的写状态请求被拒绝" || not_ok "缺少 apply 的写状态请求被拒绝"
  assert_not_exists "$FIXTURE_LIBRARY/state/router-gate.tsv" "单独 write-status 不写状态文件"

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" --write-status --apply 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "双显式写状态评测成功"
  assert_contains "$output" "AUTO_ROUTE=enabled" "显式写状态保留评测结果"
  assert_exists "$FIXTURE_LIBRARY/state/router-gate.tsv" "同时指定 write-status 和 apply 才写状态文件"
  assert_eq "$(awk -F '\t' 'NR == 1 { print NF }' "$FIXTURE_LIBRARY/state/router-gate.tsv")" "6" "状态文件固定六个字段"
  assert_eq "$(awk -F '\t' 'NR == 1 { print $6 }' "$FIXTURE_LIBRARY/state/router-gate.tsv")" "enabled" "状态文件记录启用结果"

  set +e
  route_status="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$SKILLCTL" route-status 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "已写状态可被 route-status 读取"
  assert_eq "$route_status" "自动选择已启用" "哈希匹配且已启用时允许自动选择"

  test_route_status_rejects_forged_or_expired_gate "$FIXTURE_LIBRARY"
  test_route_status_uses_exact_decimal_thresholds "$FIXTURE_LIBRARY"

  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$fixture" --write-status --apply)"
  assert_contains "$output" "AUTO_ROUTE=enabled" "安全拒绝测试后可恢复合法状态"

  printf '%s\n' "catalog-drift" >> "$FIXTURE_LIBRARY/catalog.tsv"
  set +e
  route_status="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$SKILLCTL" route-status 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "目录变化后 route-status 仍可读取"
  assert_eq "$route_status" "自动选择未启用" "目录哈希变化后自动选择关闭"
}

test_full_reviewed_fixture() {
  local output status expected_ids fixture_ids wrong_counts ambiguous_or_none_rows
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-evaluation-full-test.XXXXXX")"
  FIXTURE_LIBRARY="$TEST_ROOT/library"
  mkdir -p "$FIXTURE_LIBRARY"
  make_full_catalog "$FIXTURE_LIBRARY/catalog.tsv"

  expected_ids="$(awk -F '\t' '$1 !~ /^#/ && NF == 6 && $4 != "system" { print $1 }' "$PACKAGE/config/aliases.tsv" | LC_ALL=C sort)"
  fixture_ids="$(awk -F '\t' '$1 == "clear" { print $2 }' "$FULL_FIXTURES" | LC_ALL=C sort -u)"
  assert_eq "$fixture_ids" "$expected_ids" "clear 评测 ID 与全部非 system aliases 双向一致"
  wrong_counts="$(awk -F '\t' '$1 == "clear" { count[$2]++ } END { for (id in count) if (count[id] != 3) print id "=" count[id] }' "$FULL_FIXTURES" | LC_ALL=C sort)"
  assert_eq "$wrong_counts" "" "每个 clear 评测 ID 恰好三条合成提示"
  ambiguous_or_none_rows="$(awk -F '\t' '$1 == "ambiguous" || $1 == "none" { count++ } END { print count + 0 }' "$FULL_FIXTURES")"
  [ "$ambiguous_or_none_rows" -ge 20 ] && ok "全量夹具包含至少二十条歧义或无 Skill 提示" || not_ok "全量夹具包含至少二十条歧义或无 Skill 提示"

  set +e
  output="$(SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY" /bin/bash "$EVALUATOR" --fixtures "$FULL_FIXTURES" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "全量审阅夹具满足精确阈值"
  assert_contains "$output" "AUTO_ROUTE=enabled" "全量审阅夹具允许自动选择"
  assert_not_exists "$FIXTURE_LIBRARY/state/router-gate.tsv" "全量默认评测保持只读"
}

assert_exists "$SKILLCTL" "skillctl 入口存在"

# 这个套件里每条调用都显式传 SKILL_LIBRARY_ROOT="$FIXTURE_LIBRARY"（每个测试
# 函数用的夹具库不一样，显式传更清楚，不改）。这里仍然跑一次公共初始化，把
# HOME/SKILL_ALIASES/SKILL_ADAPTERS/SKILL_APPLICATIONS_DIR/SKILL_PACKAGE_ROOT
# 等这条测试目前用不到、但组内其它命令可能会读的变量也兜底指到沙箱里，防止
# 以后往这个文件加新调用时漏传。
ENV_HOME="$(mktemp -d "${TMPDIR:-/tmp}/router-evaluation-env.XXXXXX")"
skill_test_env_init "$ENV_HOME"
unset SKILLS_ACTIVE SKILL_GLOBAL_DIR

test_bad_fixture_disables_auto_route
test_good_fixture_requires_explicit_write_pair

if [ "${1:-}" = "--full" ]; then
  test_full_reviewed_fixture
elif [ "$#" -gt 0 ]; then
  printf '用法：%s [--full]\n' "$0" >&2
  exit 2
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
