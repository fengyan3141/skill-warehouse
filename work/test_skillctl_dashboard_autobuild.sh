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
ALIASES=""
HTML=""
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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-dashboard-autobuild-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ADAPTERS="$SKILL_ADAPTERS"
  ALIASES="$SKILL_ALIASES"
  HTML="$LIBRARY/dashboard/index.html"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"
  printf '%s\n' '# id	display_zh	aliases_zh	category	triggers	excludes' > "$ALIASES"

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

# 阶段4的要求：所有改变激活/连接状态的 --apply 命令收尾要自动 dashboard
# build，不用用户自己再手动跑一遍。这里逐个命令验证面板确实生成了，并且
# 输出里有个"（已自动重建本地面板）"的提示，不是悄悄发生的。
test_activate_apply_auto_rebuilds_dashboard() {
  make_fixture
  assert_not_exists "$HTML" "初始状态没有面板"

  run_skillctl_capture activate test-skill
  assert_eq "$SKILLCTL_STATUS" "0" "预演成功退出"
  assert_not_exists "$HTML" "预演不自动重建面板"

  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "apply 报告已自动重建面板"
  assert_exists "$HTML" "activate --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

test_deactivate_apply_auto_rebuilds_dashboard() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  rm -f "$HTML"

  run_skillctl_capture deactivate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "deactivate apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "deactivate apply 报告已自动重建面板"
  assert_exists "$HTML" "deactivate --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

test_profile_use_apply_auto_rebuilds_dashboard() {
  make_fixture
  run_skillctl_capture profile use core --apply
  assert_eq "$SKILLCTL_STATUS" "0" "profile use apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "profile use apply 报告已自动重建面板"
  assert_exists "$HTML" "profile use --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

test_tools_connect_and_disconnect_apply_auto_rebuild_dashboard() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  rm -f "$HTML"

  run_skillctl_capture tools connect fake-link-tool --apply
  assert_eq "$SKILLCTL_STATUS" "0" "tools connect apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "tools connect apply 报告已自动重建面板"
  assert_exists "$HTML" "tools connect --apply 后面板已生成"

  rm -f "$HTML"
  run_skillctl_capture tools disconnect fake-link-tool --apply
  assert_eq "$SKILLCTL_STATUS" "0" "tools disconnect apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "tools disconnect apply 报告已自动重建面板"
  assert_exists "$HTML" "tools disconnect --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

test_import_activate_apply_auto_rebuilds_dashboard() {
  make_fixture
  local incoming
  incoming="$TEST_ROOT/incoming"
  make_skill "$incoming" "imported-skill"

  run_skillctl_capture import "$incoming" --activate --apply
  assert_eq "$SKILLCTL_STATUS" "0" "import --activate apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "import --activate apply 报告已自动重建面板"
  assert_exists "$HTML" "import --activate --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

test_import_without_activate_does_not_rebuild_dashboard() {
  make_fixture
  local incoming
  incoming="$TEST_ROOT/incoming"
  make_skill "$incoming" "imported-skill-2"

  run_skillctl_capture import "$incoming" --apply
  assert_eq "$SKILLCTL_STATUS" "0" "import（不带 --activate）apply 成功退出"
  assert_not_exists "$HTML" "import 不带 --activate 时不自动重建面板"
  cleanup
  TEST_ROOT=""
}


test_eject_apply_auto_rebuilds_dashboard() {
  make_fixture
  run_skillctl_capture activate test-skill --apply
  rm -f "$HTML"

  run_skillctl_capture eject --apply
  assert_eq "$SKILLCTL_STATUS" "0" "eject apply 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已自动重建本地面板" "eject apply 报告已自动重建面板"
  assert_exists "$HTML" "eject --apply 后面板已生成"
  cleanup
  TEST_ROOT=""
}

# 回归测试：这是这次实现过程中真实踩过的坑——加自动重建面板之前，有个
# 现成的安全测试断言"祖先软链挡住一切操作时，整棵目录树纹丝不动"；一开始
# 无脑地在 apply=yes 时无条件重建面板，结果祖先软链挡下 activate/
# deactivate/profile use 之后，虽然核心操作被安全跳过了，面板却还是凭空
# 冒出来一个，破坏了那条"纹丝不动"的断言。修复方式是重建前先确认目标路径
# 本身没有被判定为不安全（复用 safe_link_directory）。这里直接复现那个
# 场景，锁定这个修复不会再退化。
test_ancestor_symlink_block_does_not_create_dashboard() {
  make_fixture
  rm -rf "$TEST_HOME/.agents"
  mkdir -p "$TEST_HOME/external-agents/skills"
  ln -s "$TEST_HOME/external-agents" "$TEST_HOME/.agents"

  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下 activate 安全退出"
  assert_contains "$SKILLCTL_OUTPUT" "目标路径含软链" "activate 因祖先软链被跳过"
  assert_not_exists "$HTML" "activate 被祖先软链挡住时不生成面板"

  run_skillctl_capture deactivate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下 deactivate 安全退出"
  assert_not_exists "$HTML" "deactivate 被祖先软链挡住时不生成面板"

  run_skillctl_capture profile use core --apply
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下 profile use 安全退出"
  assert_not_exists "$HTML" "profile use 被祖先软链挡住时不生成面板"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_activate_apply_auto_rebuilds_dashboard
  test_deactivate_apply_auto_rebuilds_dashboard
  test_profile_use_apply_auto_rebuilds_dashboard
  test_tools_connect_and_disconnect_apply_auto_rebuild_dashboard
  test_import_activate_apply_auto_rebuilds_dashboard
  test_import_without_activate_does_not_rebuild_dashboard
  test_eject_apply_auto_rebuilds_dashboard
  test_ancestor_symlink_block_does_not_create_dashboard
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
