#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKILLCTL="$ROOT/skillctl"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
TEST_HOME=""
LIBRARY=""
SKILLCTL_OUTPUT=""
SKILLCTL_STATUS=""

cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
  fi
  return 0
}
trap cleanup EXIT HUP INT TERM

add_catalog_row() {
  local id="$1" display="$2" triggers="${3:-test}" description="${4:-测试描述文本长度足够避免触发长度告警测试}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'test' "$triggers" '' "$description" >> "$LIBRARY/catalog.tsv"
}

make_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-lint-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"
  add_catalog_row "test-skill" "测试技能"
  make_skill "$LIBRARY/skills/test-skill" "test-skill"
}

run_skillctl_capture() {
  if SKILLCTL_OUTPUT="$(/bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

test_lint_clean_fixture_reports_ok_and_exits_zero() {
  make_fixture
  run_skillctl_capture lint
  assert_eq "$SKILLCTL_STATUS" "0" "干净仓库 lint 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "frontmatter 完整，且 name 字段与目录名一致" "干净仓库报告 frontmatter 完整"
  assert_contains "$SKILLCTL_OUTPUT" "description 长度都在合理范围" "干净仓库报告 description 长度正常"
  assert_contains "$SKILLCTL_OUTPUT" "激活的 Skill 不足两个，跳过" "干净仓库（未激活任何 Skill）触发词检查报告跳过"
  cleanup
  TEST_ROOT=""
}

test_lint_rejects_extra_arguments() {
  make_fixture
  run_skillctl_capture lint extra-arg
  assert_eq "$SKILLCTL_STATUS" "2" "lint 带多余参数报错退出"
  assert_contains "$SKILLCTL_OUTPUT" "lint 不接受参数" "lint 报错提示不接受参数"
  cleanup
  TEST_ROOT=""
}

test_lint_detects_missing_skill_md_and_frontmatter_fields() {
  make_fixture
  mkdir -p "$LIBRARY/skills/no-skill-md"
  mkdir -p "$LIBRARY/skills/no-description"
  printf '%s\n' '---' 'name: no-description' '---' 'body' > "$LIBRARY/skills/no-description/SKILL.md"

  run_skillctl_capture lint
  assert_eq "$SKILLCTL_STATUS" "1" "存在残缺 SKILL.md 时 lint 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "no-skill-md 缺少 SKILL.md" "报告缺少 SKILL.md"
  assert_contains "$SKILLCTL_OUTPUT" "no-description 的 SKILL.md frontmatter 缺少 description 字段" "报告缺少 description 字段"
  cleanup
  TEST_ROOT=""
}

# lint 比 doctor 多查一条：doctor 只管 name 字段存不存在，不管它跟目录名
# 是否一致——这条是 lint 独有的，专门测这条，避免退化成 doctor 的重复测试。
test_lint_detects_name_directory_mismatch() {
  make_fixture
  mkdir -p "$LIBRARY/skills/renamed-dir"
  printf '%s\n' '---' 'name: original-name' 'description: 描述内容长度足够长不会触发长度告警测试用例' '---' 'body' \
    > "$LIBRARY/skills/renamed-dir/SKILL.md"

  run_skillctl_capture lint
  assert_eq "$SKILLCTL_STATUS" "0" "name/目录名不一致只产生警告，不算 fail"
  assert_contains "$SKILLCTL_OUTPUT" "renamed-dir 的 SKILL.md name 字段（original-name）跟目录名不一致" "报告 name 与目录名不一致"
  cleanup
  TEST_ROOT=""
}

test_lint_flags_too_short_description() {
  make_fixture
  mkdir -p "$LIBRARY/skills/thin-desc"
  printf '%s\n' '---' 'name: thin-desc' 'description: 太短' '---' 'body' > "$LIBRARY/skills/thin-desc/SKILL.md"

  run_skillctl_capture lint
  assert_eq "$SKILLCTL_STATUS" "0" "description 过短只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "thin-desc 的 description 只有" "报告 description 过短"
  assert_contains "$SKILLCTL_OUTPUT" "信息量可能不够" "过短提示说明原因"
  cleanup
  TEST_ROOT=""
}

test_lint_flags_too_long_description() {
  local long_desc
  make_fixture
  long_desc="$(awk 'BEGIN { for (i = 0; i < 1050; i++) printf "字" }')"
  mkdir -p "$LIBRARY/skills/verbose-desc"
  printf '%s\n' '---' 'name: verbose-desc' "description: $long_desc" '---' 'body' > "$LIBRARY/skills/verbose-desc/SKILL.md"

  run_skillctl_capture lint
  assert_eq "$SKILLCTL_STATUS" "0" "description 过长只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "verbose-desc 的 description 有 1050 字，偏长" "报告 description 过长"
  cleanup
  TEST_ROOT=""
}

# 只比较"当前激活集合"内的触发词——两个都没激活的 Skill 即使触发词完全
# 一样也不该被 lint 盯上，因为它们根本不会同时出现在候选池里。
test_lint_trigger_overlap_only_considers_active_skills() {
  make_fixture
  mkdir -p "$LIBRARY/skills/overlap-a" "$LIBRARY/skills/overlap-b"
  make_skill "$LIBRARY/skills/overlap-a" "overlap-a"
  make_skill "$LIBRARY/skills/overlap-b" "overlap-b"
  add_catalog_row "overlap-a" "重叠甲" "飞书,文档,协作,写作"
  add_catalog_row "overlap-b" "重叠乙" "飞书,文档,表格,公式"

  run_skillctl_capture lint
  assert_not_contains "$SKILLCTL_OUTPUT" "overlap-a 和 overlap-b" "未激活的两个 Skill 不参与重叠比较"

  run_skillctl_capture activate overlap-a --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活 overlap-a 成功退出"
  run_skillctl_capture activate overlap-b --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活 overlap-b 成功退出"

  run_skillctl_capture lint
  assert_contains "$SKILLCTL_OUTPUT" "overlap-a 和 overlap-b 在当前激活集合内触发词重叠较多" "两者都激活后报告触发词重叠"
  assert_contains "$SKILLCTL_OUTPUT" "确认这两个 Skill 的边界是否清楚" "重叠报告给出下一步建议"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_lint_clean_fixture_reports_ok_and_exits_zero
  test_lint_rejects_extra_arguments
  test_lint_detects_missing_skill_md_and_frontmatter_fields
  test_lint_detects_name_directory_mismatch
  test_lint_flags_too_short_description
  test_lint_flags_too_long_description
  test_lint_trigger_overlap_only_considers_active_skills
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
