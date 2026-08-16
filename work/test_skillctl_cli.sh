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
  local id="$1" display="$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'test' "$display" '' "测试 $display" >> "$LIBRARY/catalog.tsv"
}

make_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-cli-test.XXXXXX")"
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

# 命令收敛的验收标准之一：裸敲 skillctl 输出的场景式帮助能一屏放完。用行数
# 做代理指标（<=20 行，留出安全余量），而不是像素级校验终端渲染。
test_bare_invocation_shows_scene_help_within_one_screen() {
  make_fixture
  run_skillctl_capture
  assert_eq "$SKILLCTL_STATUS" "0" "裸敲 skillctl 成功退出（不是报错）"
  local line_count
  line_count="$(printf '%s\n' "$SKILLCTL_OUTPUT" | wc -l | tr -d ' ')"
  if [ "$line_count" -le 20 ]; then
    ok "场景式帮助行数在一屏以内（$line_count 行）"
  else
    not_ok "场景式帮助行数在一屏以内（$line_count 行）"
  fi
  assert_contains "$SKILLCTL_OUTPUT" "skillctl status" "场景式帮助包含 status"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl doctor" "场景式帮助包含 doctor"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl eject" "场景式帮助包含 eject"
  assert_not_contains "$SKILLCTL_OUTPUT" "experimental" "场景式帮助不出现实验性子命令"
  assert_not_contains "$SKILLCTL_OUTPUT" "route" "场景式帮助不出现 route（已收敛为实验性）"
  cleanup
  TEST_ROOT=""
}

test_help_lists_experimental_section_and_full_reference() {
  make_fixture
  run_skillctl_capture help
  assert_eq "$SKILLCTL_STATUS" "0" "skillctl help 成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "实验性" "完整帮助里标注实验性分组"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl experimental route" "完整帮助提到 experimental route"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl doctor" "完整帮助包含 doctor"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl eject" "完整帮助包含 eject"
  cleanup
  TEST_ROOT=""
}

# 命令收敛的另一条验收标准：每条报错都带下一步建议，不能只甩一句"用法：..."
# 就完事。逐个检查几类具体错误路径的措辞里确实包含了可执行的下一步。
test_errors_include_actionable_next_step() {
  make_fixture

  run_skillctl_capture unknown-command
  assert_eq "$SKILLCTL_STATUS" "2" "未知命令报错退出码为 2"
  assert_contains "$SKILLCTL_OUTPUT" "看常用场景" "未知命令的报错指引回场景速查"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl help" "未知命令的报错指引完整参考"

  run_skillctl_capture activate
  assert_eq "$SKILLCTL_STATUS" "2" "activate 缺参数退出码为 2"
  assert_contains "$SKILLCTL_OUTPUT" "先 skillctl search" "activate 缺参数报错给出确认 id 的下一步"

  run_skillctl_capture tools connect
  assert_eq "$SKILLCTL_STATUS" "2" "tools connect 缺参数退出码为 2"
  assert_contains "$SKILLCTL_OUTPUT" "先 skillctl tools detect" "tools connect 缺参数报错指引 tools detect"

  run_skillctl_capture tools nosuchsub
  assert_eq "$SKILLCTL_STATUS" "2" "tools 未知子命令退出码为 2"
  assert_contains "$SKILLCTL_OUTPUT" "支持 detect/connect/disconnect" "tools 未知子命令列出可用子命令"
  cleanup
  TEST_ROOT=""
}

# 回归测试：CJK 标点紧跟裸 $var 在 bash 3.2 下会被误判成变量名的一部分，
# 报 unbound variable——这个坑本项目已经踩过好几次（见 CLAUDE.md）。新加的
# usage_error 报错分支里就藏过两处（$exp_sub；ubound、$command；unbound），
# 必须在真实的 /bin/bash 3.2 下跑一遍，bash -n 语法检查抓不出这种运行时坑。
test_error_messages_with_cjk_punctuation_do_not_crash_under_bash32() {
  make_fixture
  run_skillctl_capture nonexistent-command
  assert_not_contains "$SKILLCTL_OUTPUT" "unbound variable" "未知命令报错不因裸变量紧跟中文标点而崩溃"
  assert_eq "$SKILLCTL_STATUS" "2" "未知命令报错是正常的用法错误退出码，不是脚本崩溃"

  run_skillctl_capture tools nonexistent-sub
  assert_not_contains "$SKILLCTL_OUTPUT" "unbound variable" "tools 未知子命令报错不因裸变量紧跟中文标点而崩溃"

  run_skillctl_capture dashboard nonexistent-sub
  assert_not_contains "$SKILLCTL_OUTPUT" "unbound variable" "dashboard 未知子命令报错不因裸变量紧跟中文标点而崩溃"

  run_skillctl_capture experimental nonexistent-sub
  assert_not_contains "$SKILLCTL_OUTPUT" "unbound variable" "experimental 未知子命令报错不因裸变量紧跟中文标点而崩溃"
  cleanup
  TEST_ROOT=""
}

# route/project 收敛为 experimental 的验收关键点：bash 3.2 环境事实笔记里
# 明确写了"代码保留，内部实现不动"——真实回归风险是 evaluate-router.sh 和
# skill-router SKILL.md 都直接 shell 出裸 `skillctl route`，project 也有
# 测试直接调用裸 `project use`，如果收敛时误删了裸命令兼容，会静默破坏这些
# 真实调用方。这里正面验证：新增的 experimental 前缀和裸命令两条路都通。
test_experimental_prefix_and_bare_compat_both_work() {
  make_fixture

  run_skillctl_capture route 'test-skill'
  assert_eq "$SKILLCTL_STATUS" "0" "裸 route 仍然可用（向后兼容）"

  run_skillctl_capture experimental route 'test-skill'
  assert_eq "$SKILLCTL_STATUS" "0" "experimental route 可用"

  run_skillctl_capture route-status
  assert_eq "$SKILLCTL_STATUS" "0" "裸 route-status 仍然可用"

  run_skillctl_capture experimental route-status
  assert_eq "$SKILLCTL_STATUS" "0" "experimental route-status 可用"

  local project_dir
  project_dir="$TEST_ROOT/cli-project"
  mkdir -p "$project_dir"
  run_skillctl_capture project use core "$project_dir"
  assert_eq "$SKILLCTL_STATUS" "0" "裸 project use 仍然可用（向后兼容，evaluate-router.sh/已有测试都依赖这条路）"

  run_skillctl_capture experimental project use core "$project_dir"
  assert_eq "$SKILLCTL_STATUS" "0" "experimental project use 可用"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_bare_invocation_shows_scene_help_within_one_screen
  test_help_lists_experimental_section_and_full_reference
  test_errors_include_actionable_next_step
  test_error_messages_with_cjk_punctuation_do_not_crash_under_bash32
  test_experimental_prefix_and_bare_compat_both_work
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
