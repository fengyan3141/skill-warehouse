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
ADAPTERS=""
APPS_DIR=""
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
  local id="$1" display="$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'test' "$display" '' "测试 $display" >> "$LIBRARY/catalog.tsv"
}

make_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-doctor-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ADAPTERS="$SKILL_ADAPTERS"
  APPS_DIR="$SKILL_APPLICATIONS_DIR"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"

  cat > "$ADAPTERS" <<EOF
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
fake-link-tool	假工具	link	$TEST_ROOT/fake-tool/skills	.fake-tool/skills	__no_such_cli__	__NoSuchApp__	已验证
EOF

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

test_doctor_clean_fixture_reports_ok_and_exits_zero() {
  make_fixture
  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "干净仓库 doctor 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "没有发现断链" "干净仓库报告没有断链"
  assert_contains "$SKILLCTL_OUTPUT" "没有发现未收编进仓库的真实目录" "干净仓库报告货架上没有未收编内容"
  assert_contains "$SKILLCTL_OUTPUT" "manual.list 与磁盘软链状态一致" "干净仓库报告 manual.list 一致"
  assert_contains "$SKILLCTL_OUTPUT" "SKILL.md frontmatter 都齐全" "干净仓库报告 Skill 内容完整"
  assert_contains "$SKILLCTL_OUTPUT" "catalog 中没有重复的 Skill id" "干净仓库报告无重复 id"
  assert_contains "$SKILLCTL_OUTPUT" "catalog 与仓库磁盘内容一致" "干净仓库报告 catalog 与磁盘一致"
  assert_contains "$SKILLCTL_OUTPUT" "❌ 0" "干净仓库汇总行里 ❌ 计数为 0"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_broken_global_link() {
  make_fixture
  ln -s "../../.skill-library/skills/gone-skill" "$TEST_HOME/.agents/skills/gone-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "1" "存在断链时 doctor 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "❌ 断链" "报告断链问题"
  assert_contains "$SKILLCTL_OUTPUT" "gone-skill" "断链报告指出具体 id"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_shelf_orphan_directory() {
  make_fixture
  make_skill "$TEST_HOME/.agents/skills/orphan-skill" "orphan-skill"
  mkdir -p "$TEST_ROOT/fake-tool/skills"
  make_skill "$TEST_ROOT/fake-tool/skills/tool-orphan" "tool-orphan"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "只有货架孤儿目录时 doctor 仍成功退出（只是警告，不算失败）"
  assert_contains "$SKILLCTL_OUTPUT" "❌ 0" "货架孤儿目录不计入失败"
  assert_contains "$SKILLCTL_OUTPUT" "orphan-skill" "报告主货架上未收编的真实目录"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl import" "报告给出收编建议命令"
  assert_contains "$SKILLCTL_OUTPUT" "--activate --apply" "收编建议命令带 --activate --apply"
  assert_contains "$SKILLCTL_OUTPUT" "tool-orphan" "报告软链模式工具目录下未收编的真实目录"
  cleanup
  TEST_ROOT=""
}

test_doctor_does_not_flag_shelf_directory_already_in_catalog() {
  make_fixture
  # test-skill 已经在 catalog 里登记过——就算货架上那个位置被一个真实目录
  # 占着（没走 activate 建软链），也不该被"未收编"检查重复报告，这类
  # 冲突已经由 skillctl status 的"真实目录冲突"单独负责，不用这里再报一遍。
  make_skill "$TEST_HOME/.agents/skills/test-skill" "test-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "已登记 id 的真实目录不影响 doctor 退出码"
  assert_contains "$SKILLCTL_OUTPUT" "没有发现未收编进仓库的真实目录" "已登记 id 不会被当成未收编内容重复报告"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_broken_tool_link_with_prune_suggestion() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"
  run_skillctl_capture tools connect fake-link-tool --apply
  assert_eq "$SKILLCTL_STATUS" "0" "连接成功退出"

  run_skillctl_capture deactivate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "停用成功退出（工具目录里的链接因此变成断链）"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "1" "工具目录断链时 doctor 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "tools connect fake-link-tool --prune --apply" "断链修复建议指向 tools connect --prune"
  cleanup
  TEST_ROOT=""
}

test_doctor_tool_detection_states() {
  make_fixture
  mkdir -p "$TEST_HOME/.fake-not-connected"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "工具未安装只产生警告，doctor 仍成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "⚠️ 假工具（fake-link-tool）未检测到" "未安装工具报告未检测到"
  assert_contains "$SKILLCTL_OUTPUT" "先安装/运行一次该工具" "未检测到指引安装/运行"

  mkdir -p "$TEST_ROOT/fake-tool/skills"
  run_skillctl_capture doctor
  assert_contains "$SKILLCTL_OUTPUT" "只发现残留的软链目录" "只有残留目录时给出对应诊断"
  assert_contains "$SKILLCTL_OUTPUT" "tools disconnect fake-link-tool --apply" "残留目录指引 disconnect"
  cleanup
  TEST_ROOT=""
}

test_doctor_tool_detection_suggests_app_name_fix_when_similar_folder_found() {
  make_fixture
  mkdir -p "$APPS_DIR/FakeLinkTool CN.app"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "疑似改名安装只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "疑似同类文件夹" "检测到疑似同类文件夹时给出对应诊断"
  assert_contains "$SKILLCTL_OUTPUT" "FakeLinkTool CN.app" "列出疑似文件夹名"
  assert_contains "$SKILLCTL_OUTPUT" "手动把 tools.tsv 里 fake-link-tool 这行的 app_name 改成真实文件夹名" "指引手动修正 app_name"
  cleanup
  TEST_ROOT=""
}

test_doctor_flags_literal_unverified() {
  make_fixture
  cat > "$ADAPTERS" <<EOF
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
untrusted-tool	未验证工具	link	$TEST_ROOT/untrusted/skills	.untrusted/skills	__no_such_cli__	__NoSuchApp__	unverified
EOF

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "unverified 只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "verification 字段字面为 unverified" "报告 unverified 适配器"
  assert_contains "$SKILLCTL_OUTPUT" "--allow-unverified" "指引 --allow-unverified"
  cleanup
  TEST_ROOT=""
}

test_doctor_verification_ok_when_none_unverified() {
  make_fixture
  run_skillctl_capture doctor
  assert_contains "$SKILLCTL_OUTPUT" "当前没有适配器被标记为 unverified" "无 unverified 适配器时给出正常汇总"
  cleanup
  TEST_ROOT=""
}

test_doctor_manual_list_link_missing() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"
  rm "$TEST_HOME/.agents/skills/test-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "manual.list 记录缺链只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "manual.list 记录了 test-skill，但" "报告 manual.list 记录缺链"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl deactivate test-skill --apply" "指引清理 manual.list 记录"
  cleanup
  TEST_ROOT=""
}

test_doctor_orphan_managed_link_not_in_manual_list_or_profile() {
  make_fixture
  ln -s "../../.skill-library/skills/test-skill" "$TEST_HOME/.agents/skills/test-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "孤儿受管软链只产生警告"
  assert_contains "$SKILLCTL_OUTPUT" "既不属于任何场景包，也没记录在 manual.list 里" "报告孤儿受管软链"
  cleanup
  TEST_ROOT=""
}

# 回归测试：真实环境里发现过 doctor 把用户自己手动指到仓库以外内容的软链
# （比如直接 ln -s 到另一个工具自己的 skill 目录）误判成"孤儿受管软链"，
# 建议 activate/deactivate——但这种软链根本不归 skillctl 管，activate 会
# 直接报"未登记 Skill"失败。孤儿检查必须先判断软链是否归属仓库
# （eject_link_is_repo_managed 用的同一套判断），不归属仓库的外部软链要像
# 别处的"外部软链冲突"一样被完全忽略，不体现在 doctor 输出里。
test_doctor_ignores_foreign_link_not_pointing_into_repo() {
  make_fixture
  mkdir -p "$TEST_ROOT/external-tool/skills/foreign-skill"
  make_skill "$TEST_ROOT/external-tool/skills/foreign-skill" "foreign-skill"
  ln -s "$TEST_ROOT/external-tool/skills/foreign-skill" "$TEST_HOME/.agents/skills/foreign-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "0" "外部软链不影响 doctor 退出码"
  assert_not_contains "$SKILLCTL_OUTPUT" "foreign-skill" "doctor 完全不提外部软链，不建议 activate/deactivate"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_missing_skill_md_and_missing_fields() {
  make_fixture
  mkdir -p "$LIBRARY/skills/no-skill-md"
  mkdir -p "$LIBRARY/skills/no-description"
  printf '%s\n' '---' 'name: no-description' '---' 'body' > "$LIBRARY/skills/no-description/SKILL.md"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "1" "存在残缺 SKILL.md 时 doctor 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "no-skill-md 缺少 SKILL.md" "报告缺少 SKILL.md"
  assert_contains "$SKILLCTL_OUTPUT" "no-description 的 SKILL.md frontmatter 缺少 description 字段" "报告缺少 description 字段"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_duplicate_catalog_ids() {
  make_fixture
  add_catalog_row "test-skill" "重复的测试技能"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "1" "catalog 有重复 id 时 doctor 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "catalog 中 id 重复：test-skill" "报告重复 id"
  cleanup
  TEST_ROOT=""
}

test_doctor_detects_catalog_disk_mismatch_both_directions() {
  make_fixture
  add_catalog_row "ghost-skill" "幽灵技能"
  mkdir -p "$LIBRARY/skills/untracked-skill"
  make_skill "$LIBRARY/skills/untracked-skill" "untracked-skill"

  run_skillctl_capture doctor
  assert_eq "$SKILLCTL_STATUS" "1" "catalog 与磁盘不一致时 doctor 非零退出"
  assert_contains "$SKILLCTL_OUTPUT" "catalog 记录了 ghost-skill，但仓库目录不存在" "报告 catalog 有记录但目录缺失"
  assert_contains "$SKILLCTL_OUTPUT" "仓库里有 untracked-skill，但 catalog 中没有记录" "报告磁盘有目录但 catalog 缺失"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_doctor_clean_fixture_reports_ok_and_exits_zero
  test_doctor_detects_broken_global_link
  test_doctor_detects_shelf_orphan_directory
  test_doctor_does_not_flag_shelf_directory_already_in_catalog
  test_doctor_detects_broken_tool_link_with_prune_suggestion
  test_doctor_tool_detection_states
  test_doctor_tool_detection_suggests_app_name_fix_when_similar_folder_found
  test_doctor_flags_literal_unverified
  test_doctor_verification_ok_when_none_unverified
  test_doctor_manual_list_link_missing
  test_doctor_orphan_managed_link_not_in_manual_list_or_profile
  test_doctor_ignores_foreign_link_not_pointing_into_repo
  test_doctor_detects_missing_skill_md_and_missing_fields
  test_doctor_detects_duplicate_catalog_ids
  test_doctor_detects_catalog_disk_mismatch_both_directions
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
