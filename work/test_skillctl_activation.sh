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
  [ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
  return 0
}
trap cleanup EXIT HUP INT TERM

snapshot_tree() {
  find "$1" -print | LC_ALL=C sort | while IFS= read -r path; do
    if [ -L "$path" ]; then
      printf 'link\t%s\t%s\n' "$path" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'file\t%s\t%s\n' "$path" "$(shasum -a 256 "$path" | awk '{print $1}')"
    elif [ -d "$path" ]; then
      printf 'dir\t%s\n' "$path"
    fi
  done
}

add_catalog_row() {
  local id="$1" display="$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'test' "$display" '' "测试 $display" >> "$LIBRARY/catalog.tsv"
}

make_fixture() {
  local id
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-activation-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"

  # commit-message-writer / code-review-checklist：随包 core 场景包的真实
  # 两个成员（PROFILE_DIR 硬编码指向真实包配置，没法在沙箱里伪造独立场景
  # 包，所以这里的假 catalog 必须跟真实 config/profiles/core 的内容对上）。
  for id in commit-message-writer code-review-checklist lark-doc orphan-skill; do
    add_catalog_row "$id" "$id"
  done
  for id in commit-message-writer code-review-checklist lark-doc orphan-skill; do
    make_skill "$LIBRARY/skills/$id" "$id"
  done
}

run_skillctl_capture() {
  if SKILLCTL_OUTPUT="$(/bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

run_skillctl_in_active_capture() {
  local active="$1"
  shift
  if SKILLCTL_OUTPUT="$(SKILLS_ACTIVE="$active" /bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

test_dry_run_leaves_global_tree_unchanged() {
  local before after output
  make_fixture
  before="$(snapshot_tree "$TEST_HOME")"
  run_skillctl_capture activate lark-doc
  output="$SKILLCTL_OUTPUT"
  after="$(snapshot_tree "$TEST_HOME")"

  assert_eq "$SKILLCTL_STATUS" "0" "激活预演成功退出"
  assert_eq "$after" "$before" "激活预演不改动临时 HOME"
  assert_contains "$output" '[预演] 激活 lark-doc' "激活预演输出中文动作"
  cleanup
  TEST_ROOT=""
}

test_activation_is_relative_and_idempotent() {
  local first second
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc" 2>/dev/null || true)" "../../.skill-library/skills/lark-doc" "激活创建相对受管软链"

  first="$(snapshot_tree "$TEST_HOME/.agents/skills")"
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "重复激活成功退出"
  second="$(snapshot_tree "$TEST_HOME/.agents/skills")"
  assert_eq "$second" "$first" "重复激活保持幂等"
  cleanup
  TEST_ROOT=""
}

test_conflicts_and_missing_skills_are_preserved() {
  local output
  make_fixture
  mkdir -p "$TEST_HOME/.agents/skills/lark-doc"
  run_skillctl_capture activate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "真实目录冲突安全退出"
  assert_exists "$TEST_HOME/.agents/skills/lark-doc" "激活保留真实目录"
  assert_contains "$output" '[跳过] 真实目录冲突 lark-doc' "真实目录产生跳过告警"

  rm -rf "$TEST_HOME/.agents/skills/lark-doc"
  mkdir -p "$TEST_HOME/external/foreign"
  ln -s "$TEST_HOME/external/foreign" "$TEST_HOME/.agents/skills/lark-doc"
  run_skillctl_capture activate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "外部软链冲突安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc" 2>/dev/null || true)" "$TEST_HOME/external/foreign" "激活保留外部软链"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "外部软链产生跳过告警"

  # core 场景包的另一个成员 code-review-checklist 在 catalog 里登记了，但
  # 这里删掉它的仓库目录，模拟"场景包引用了仓库里缺失的 Skill"。
  rm -rf "$LIBRARY/skills/code-review-checklist"
  run_skillctl_capture profile use core --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "缺失 Skill 场景包安全退出"
  assert_not_exists "$TEST_HOME/.agents/skills/code-review-checklist" "仓库缺失 Skill 不创建链接"
  assert_contains "$output" '[跳过] 仓库缺少 code-review-checklist' "仓库缺失产生跳过告警"
  cleanup
  TEST_ROOT=""
}

test_deactivate_only_removes_managed_link() {
  local output
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "停用前激活成功退出"
  run_skillctl_capture deactivate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "停用成功退出"
  assert_not_exists "$TEST_HOME/.agents/skills/lark-doc" "停用删除受管软链"

  mkdir -p "$TEST_HOME/external/foreign"
  ln -s "$TEST_HOME/external/foreign" "$TEST_HOME/.agents/skills/lark-doc"
  run_skillctl_capture deactivate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "外部软链停用安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc" 2>/dev/null || true)" "$TEST_HOME/external/foreign" "停用保留外部软链"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "停用外部软链产生跳过告警"
  cleanup
  TEST_ROOT=""
}

test_profile_use_preserves_manual_but_still_prunes_others() {
  local count output
  make_fixture

  # lark-doc：走 `activate` 单独激活，进 manual.list，应该在场景切换后幸存。
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "场景切换前手动激活成功退出"

  # orphan-skill：手工直接建软链，模拟"没走 manual.list 机制就已经存在的
  # 受管软链"（比如老版本 skillctl 留下的、或者曾经某个场景包激活过的），
  # 用来验证这条 profile use 仍然会清掉它——manual.list 只保护真正走过
  # `activate` 命令的 id，不是让 profile use 变成什么都不清。
  ln -s '../../.skill-library/skills/orphan-skill' "$TEST_HOME/.agents/skills/orphan-skill"

  mkdir -p "$TEST_HOME/.agents/skills/real-skill"
  run_skillctl_capture profile use core --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "场景切换成功退出"
  assert_contains "$output" "将停用 1 个" "场景切换输出可见的停用清单"

  assert_exists "$TEST_HOME/.agents/skills/lark-doc" "手动激活的 skill 在切换场景包后仍然存活"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc" 2>/dev/null || true)" "../../.skill-library/skills/lark-doc" "手动激活的软链未被场景切换动过"
  assert_not_exists "$TEST_HOME/.agents/skills/orphan-skill" "非手动激活的孤儿软链仍会被场景切换清掉"
  assert_exists "$TEST_HOME/.agents/skills/real-skill" "场景切换保留真实目录"
  count="$(find "$TEST_HOME/.agents/skills" -type l | wc -l | tr -d ' ')"
  assert_eq "$count" "3" "core 两个加手动激活的一个，共三个受管链接"
  assert_exists "$TEST_HOME/.agents/skills/commit-message-writer" "core 包含提交信息生成"
  assert_exists "$TEST_HOME/.agents/skills/code-review-checklist" "core 包含代码审查清单"
  assert_contains "$(cat "$LIBRARY/state/manual.list" 2>/dev/null || true)" "lark-doc" "manual.list 记录了手动激活的 lark-doc"
  cleanup
  TEST_ROOT=""
}

test_project_scope_is_absolute_and_isolated() {
  local project output
  make_fixture
  project="$TEST_ROOT/project"
  mkdir -p "$project"
  run_skillctl_capture project use core "$project" --apply
  assert_eq "$SKILLCTL_STATUS" "0" "项目作用域成功退出"

  assert_eq "$(readlink "$project/.agents/skills/commit-message-writer" 2>/dev/null || true)" "../../../home/.skill-library/skills/commit-message-writer" "项目作用域创建相对受管软链"
  assert_not_exists "$TEST_HOME/.agents/skills/commit-message-writer" "项目作用域不写入全局目录"

  run_skillctl_capture project use core relative-project --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "2" "相对项目路径返回参数错误"
  assert_contains "$output" '项目路径必须是已存在的绝对目录' "项目作用域拒绝相对路径"
  assert_not_exists "$TEST_ROOT/relative-project/.agents/skills" "拒绝路径不会创建项目目录"
  cleanup
  TEST_ROOT=""
}

test_skills_active_overrides_default_global_directory() {
  local custom_active
  make_fixture
  custom_active="$TEST_HOME/custom-active"
  run_skillctl_in_active_capture "$custom_active" activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "SKILLS_ACTIVE 激活成功退出"
  assert_exists "$custom_active/lark-doc" "SKILLS_ACTIVE 覆盖默认全局目录"
  assert_not_exists "$TEST_HOME/.agents/skills/lark-doc" "覆盖后不写默认全局目录"
  cleanup
  TEST_ROOT=""
}

test_same_target_nonstandard_links_are_external() {
  local output raw_link status_output
  make_fixture
  raw_link="$LIBRARY/skills/lark-doc"
  ln -s "$raw_link" "$TEST_HOME/.agents/skills/lark-doc"

  run_skillctl_capture status
  status_output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "绝对同目标状态查询成功退出"
  assert_contains "$status_output" $'全局\t外部软链冲突\tlark-doc\tlark-doc' "绝对同目标状态视为外部链接"

  run_skillctl_capture activate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "绝对同目标激活安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc")" "$raw_link" "绝对同目标链接不被激活覆盖"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "绝对同目标激活视为外部链接"

  run_skillctl_capture deactivate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "绝对同目标停用安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc")" "$raw_link" "绝对同目标链接不被停用删除"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "绝对同目标停用视为外部链接"

  run_skillctl_capture profile use core --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "绝对同目标场景切换安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc")" "$raw_link" "绝对同目标链接不被场景清理删除"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "绝对同目标场景清理视为外部链接"

  if [ -L "$TEST_HOME/.agents/skills/lark-doc" ]; then
    rm "$TEST_HOME/.agents/skills/lark-doc"
  fi
  ln -s '../../.skill-library/skills/../skills/lark-doc' "$TEST_HOME/.agents/skills/lark-doc"
  run_skillctl_capture profile use core --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "非标准相对链接场景切换安全退出"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/lark-doc")" '../../.skill-library/skills/../skills/lark-doc' "非标准相对链接不被场景清理删除"
  assert_contains "$output" '[跳过] 外部软链冲突 lark-doc' "非标准相对链接视为外部链接"
  cleanup
  TEST_ROOT=""
}

test_existing_ancestor_symlinks_block_all_scopes() {
  local before after output project
  make_fixture
  rm -rf "$TEST_HOME/.agents"
  mkdir -p "$TEST_HOME/external-agents/skills"
  ln -s "$TEST_HOME/external-agents" "$TEST_HOME/.agents"
  ln -s "$LIBRARY/skills/lark-doc" "$TEST_HOME/external-agents/skills/lark-doc"
  project="$TEST_ROOT/project"
  mkdir -p "$project" "$TEST_ROOT/external-project"
  ln -s "$TEST_ROOT/external-project" "$project/.agents"
  before="$(snapshot_tree "$TEST_ROOT")"

  run_skillctl_capture activate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下激活安全退出"
  assert_contains "$output" '[跳过] 目标路径含软链' "祖先软链拒绝激活"

  run_skillctl_capture deactivate lark-doc --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下停用安全退出"
  assert_contains "$output" '[跳过] 目标路径含软链' "祖先软链拒绝停用"

  run_skillctl_capture profile use core --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "祖先软链下场景切换安全退出"
  assert_contains "$output" '[跳过] 目标路径含软链' "祖先软链拒绝场景切换"

  run_skillctl_capture project use core "$project" --apply
  output="$SKILLCTL_OUTPUT"
  assert_eq "$SKILLCTL_STATUS" "0" "项目祖先软链下场景切换安全退出"
  assert_contains "$output" '[跳过] 目标路径含软链' "项目祖先软链拒绝写入"

  after="$(snapshot_tree "$TEST_ROOT")"
  assert_eq "$after" "$before" "祖先软链下所有 apply 都不改动树"
  cleanup
  TEST_ROOT=""
}

test_deactivate_profile_and_project_dry_runs_leave_tree_unchanged() {
  local before after project
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "预演前受管激活成功退出"
  project="$TEST_ROOT/project"
  mkdir -p "$project"
  before="$(snapshot_tree "$TEST_ROOT")"

  run_skillctl_capture deactivate lark-doc
  assert_eq "$SKILLCTL_STATUS" "0" "停用预演成功退出"
  run_skillctl_capture profile use core
  assert_eq "$SKILLCTL_STATUS" "0" "场景包预演成功退出"
  run_skillctl_capture project use core "$project"
  assert_eq "$SKILLCTL_STATUS" "0" "项目作用域预演成功退出"

  after="$(snapshot_tree "$TEST_ROOT")"
  assert_eq "$after" "$before" "停用、场景包和项目预演均不改动树"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_dry_run_leaves_global_tree_unchanged
  test_activation_is_relative_and_idempotent
  test_conflicts_and_missing_skills_are_preserved
  test_deactivate_only_removes_managed_link
  test_profile_use_preserves_manual_but_still_prunes_others
  test_project_scope_is_absolute_and_isolated
  test_skills_active_overrides_default_global_directory
  test_same_target_nonstandard_links_are_external
  test_existing_ancestor_symlinks_block_all_scopes
  test_deactivate_profile_and_project_dry_runs_leave_tree_unchanged
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
