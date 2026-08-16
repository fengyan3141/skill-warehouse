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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-eject-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ADAPTERS="$SKILL_ADAPTERS"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"

  cat > "$ADAPTERS" <<EOF
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
fake-link-tool	假工具	link	$TEST_ROOT/fake-tool/skills	.fake-tool/skills	__no_such_cli__	__NoSuchApp__	test
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

test_eject_noop_when_nothing_managed() {
  make_fixture
  run_skillctl_capture eject
  assert_eq "$SKILLCTL_STATUS" "0" "无受管软链时预演成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "没有发现受管软链目录" "无受管软链时预演报告无需 eject"

  run_skillctl_capture eject --apply
  assert_eq "$SKILLCTL_STATUS" "0" "无受管软链时 apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "没有发现受管软链目录" "无受管软链时 apply 报告无需 eject"
  assert_not_exists "$LIBRARY/eject-backups" "无受管软链时不创建备份目录"
  cleanup
  TEST_ROOT=""
}

test_eject_dry_run_does_not_modify() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"

  run_skillctl_capture eject
  assert_eq "$SKILLCTL_STATUS" "0" "eject 预演成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "[预演] 物化" "预演输出物化动作"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/test-skill")" "../../.skill-library/skills/test-skill" "预演不改动软链"
  assert_not_exists "$LIBRARY/eject-backups" "预演不创建备份目录"
  cleanup
  TEST_ROOT=""
}

# eject 是这套系统里改动面最大的一次性操作（把所有软链变成独立真实拷贝，
# 相当于永久退出管理），预演输出的可读性标准要比其他命令更高：必须让人
# 一眼看出"要动多少条软链、涉及哪些目录、备份会写到哪"，不能只靠逐条
# 罗列让读者自己去数。
test_eject_dry_run_states_count_directories_and_backup_location() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"
  run_skillctl_capture tools connect fake-link-tool --apply
  assert_eq "$SKILLCTL_STATUS" "0" "连接成功退出"

  run_skillctl_capture eject
  assert_eq "$SKILLCTL_STATUS" "0" "eject 预演成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "将把 2 条受管软链物化为独立真实拷贝，涉及 2 个目录" "预演开头明确给出软链总数和涉及目录数"
  assert_contains "$SKILLCTL_OUTPUT" "备份位置" "预演明确提示备份位置"
  assert_contains "$SKILLCTL_OUTPUT" "$LIBRARY/eject-backups" "预演给出备份所在的仓库路径"
  assert_contains "$SKILLCTL_OUTPUT" "$TEST_HOME/.agents/skills（全局共享目录，原生工具直接读取这里）" "预演逐个列出涉及的目录，并标注其身份"
  assert_contains "$SKILLCTL_OUTPUT" "假工具（fake-link-tool）" "预演逐个列出涉及的工具目录，并标注对应工具"
  cleanup
  TEST_ROOT=""
}

test_eject_apply_physicalizes_global_and_tool_dirs() {
  local content_hash tool_hash
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"
  run_skillctl_capture tools connect fake-link-tool --apply
  assert_eq "$SKILLCTL_STATUS" "0" "连接成功退出"
  assert_exists "$TEST_ROOT/fake-tool/skills/test-skill" "连接后工具目录里有软链"

  run_skillctl_capture eject --apply
  assert_eq "$SKILLCTL_STATUS" "0" "eject 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已备份将改动的目录到" "apply 报告已备份"
  assert_contains "$SKILLCTL_OUTPUT" "已脱离 skillctl 管理" "apply 报告已脱离管理"

  if [ -L "$TEST_HOME/.agents/skills/test-skill" ]; then
    not_ok "全局目录里的软链被物化为真实目录"
  else
    ok "全局目录里的软链被物化为真实目录"
  fi
  if [ -L "$TEST_ROOT/fake-tool/skills/test-skill" ]; then
    not_ok "工具目录里的软链被物化为真实目录"
  else
    ok "工具目录里的软链被物化为真实目录"
  fi

  assert_exists "$TEST_HOME/.agents/skills/test-skill/SKILL.md" "物化后全局目录保留内容"
  assert_exists "$TEST_ROOT/fake-tool/skills/test-skill/SKILL.md" "物化后工具目录保留内容"

  content_hash="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"
  tool_hash="$(shasum -a 256 "$TEST_ROOT/fake-tool/skills/test-skill/SKILL.md" | awk '{print $1}')"
  assert_eq "$tool_hash" "$content_hash" "工具目录物化后的内容与仓库源内容一致——回归测试：物化顺序不能让后处理的目标被误判为不归属仓库而跳过"

  assert_exists "$LIBRARY/eject-backups" "apply 创建备份目录"
  cleanup
  TEST_ROOT=""
}

test_eject_preserves_foreign_and_real_conflicts() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"

  mkdir -p "$TEST_HOME/external"
  ln -s "$TEST_HOME/external" "$TEST_HOME/.agents/skills/foreign-link"
  mkdir -p "$TEST_HOME/.agents/skills/real-dir"

  run_skillctl_capture eject --apply
  assert_eq "$SKILLCTL_STATUS" "0" "eject 成功退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/foreign-link")" "$TEST_HOME/external" "eject 不改动外部软链"
  if [ -L "$TEST_HOME/.agents/skills/real-dir" ]; then
    not_ok "eject 不改动已存在的真实目录"
  else
    ok "eject 不改动已存在的真实目录"
  fi
  cleanup
  TEST_ROOT=""
}

test_eject_backup_failure_aborts_before_any_mutation() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"

  mkdir -p "$LIBRARY/eject-backups"
  chmod u-w "$LIBRARY/eject-backups"

  run_skillctl_capture eject --apply
  assert_eq "$SKILLCTL_STATUS" "1" "备份目录不可写时 eject 失败退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/test-skill")" "../../.skill-library/skills/test-skill" "备份失败时软链未被改动"
  chmod u+w "$LIBRARY/eject-backups"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_eject_noop_when_nothing_managed
  test_eject_dry_run_does_not_modify
  test_eject_dry_run_states_count_directories_and_backup_location
  test_eject_apply_physicalizes_global_and_tool_dirs
  test_eject_preserves_foreign_and_real_conflicts
  test_eject_backup_failure_aborts_before_any_mutation
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
