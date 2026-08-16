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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-export-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"
  add_catalog_row "demo-skill" "演示技能"
  make_skill "$LIBRARY/skills/demo-skill" "demo-skill" "演示正文"
  mkdir -p "$LIBRARY/skills/demo-skill/scripts"
  printf '#!/bin/sh\necho hi\n' > "$LIBRARY/skills/demo-skill/scripts/run.sh"
}

run_skillctl_capture() {
  if SKILLCTL_OUTPUT="$(/bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

test_export_default_destination_is_clean_copy_on_desktop() {
  local before after dest
  make_fixture
  before="$(snapshot_tree "$LIBRARY")"
  dest="$TEST_HOME/Desktop/skill-export-demo-skill"

  run_skillctl_capture export demo-skill
  assert_eq "$SKILLCTL_STATUS" "0" "导出默认目标成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "[已导出] demo-skill -> $dest" "导出报告目标路径"
  assert_exists "$dest/SKILL.md" "导出目标含 SKILL.md"
  assert_exists "$dest/scripts/run.sh" "导出目标含内容子目录"
  assert_not_exists "$dest/catalog.tsv" "导出目标不含仓库 catalog"
  assert_not_exists "$dest/.staging-demo-skill" "导出目标不含暂存痕迹"

  after="$(snapshot_tree "$LIBRARY")"
  assert_eq "$after" "$before" "导出不改动仓库内容（只读，不需要 --apply）"
  cleanup
  TEST_ROOT=""
}

test_export_output_flag_writes_to_custom_absolute_path() {
  local dest
  make_fixture
  dest="$TEST_HOME/custom/nested/export-out"

  run_skillctl_capture export demo-skill --output "$dest"
  assert_eq "$SKILLCTL_STATUS" "0" "自定义目标成功退出"
  assert_exists "$dest/SKILL.md" "自定义目标含 SKILL.md"
  assert_eq "$(cat "$dest/scripts/run.sh")" "$(cat "$LIBRARY/skills/demo-skill/scripts/run.sh")" "自定义目标内容与仓库一致"
  cleanup
  TEST_ROOT=""
}

test_export_rejects_relative_output_path() {
  make_fixture
  run_skillctl_capture export demo-skill --output relative/path
  assert_eq "$SKILLCTL_STATUS" "2" "相对 --output 路径失败退出"
  assert_contains "$SKILLCTL_OUTPUT" "必须是绝对路径" "相对路径给出明确错误"
  assert_not_contains "$SKILLCTL_OUTPUT" "invalid option" "错误信息不因 -- 开头触发 printf 参数解析错误"
  assert_not_exists "$TEST_HOME/relative" "拒绝时不创建任何目录"
  cleanup
  TEST_ROOT=""
}

test_export_refuses_to_overwrite_existing_destination() {
  local dest marker
  make_fixture
  dest="$TEST_HOME/already-here"
  mkdir -p "$dest"
  marker="$dest/keep-me.txt"
  printf 'do not touch\n' > "$marker"

  run_skillctl_capture export demo-skill --output "$dest"
  assert_eq "$SKILLCTL_STATUS" "1" "目标已存在时失败退出"
  assert_contains "$SKILLCTL_OUTPUT" "已存在" "提示目标已存在"
  assert_eq "$(cat "$marker")" "do not touch" "已存在目标的内容未被覆盖"
  assert_not_exists "$dest/SKILL.md" "已存在目标未被写入导出内容"
  cleanup
  TEST_ROOT=""
}

test_export_unknown_id_fails_clearly() {
  make_fixture
  run_skillctl_capture export nonexistent-skill-xyz
  assert_eq "$SKILLCTL_STATUS" "1" "未登记 id 导出失败退出"
  assert_contains "$SKILLCTL_OUTPUT" "未登记 Skill" "报告未登记"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl status" "提示下一步查看 status 或 search"
  cleanup
  TEST_ROOT=""
}

test_export_bad_arguments_show_usage_hint() {
  make_fixture
  run_skillctl_capture export
  assert_eq "$SKILLCTL_STATUS" "2" "缺少 id 时用法错误退出"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl export <id>" "用法错误给出正确格式"
  assert_contains "$SKILLCTL_OUTPUT" "skillctl help" "用法错误提示完整参考"

  run_skillctl_capture export demo-skill --apply
  assert_eq "$SKILLCTL_STATUS" "2" "误传 --apply（只读命令不需要）用法错误退出"

  run_skillctl_capture export demo-skill --output
  assert_eq "$SKILLCTL_STATUS" "2" "--output 缺值时用法错误退出"

  run_skillctl_capture export demo-skill --bogus-flag value
  assert_eq "$SKILLCTL_STATUS" "2" "未知参数用法错误退出"
  cleanup
  TEST_ROOT=""
}

test_export_does_not_require_apply_flag() {
  make_fixture
  run_skillctl_capture export demo-skill
  assert_eq "$SKILLCTL_STATUS" "0" "不带 --apply 也能直接导出（只读操作）"
  cleanup
  TEST_ROOT=""
}

test_export_default_destination_is_clean_copy_on_desktop
test_export_output_flag_writes_to_custom_absolute_path
test_export_rejects_relative_output_path
test_export_refuses_to_overwrite_existing_destination
test_export_unknown_id_fails_clearly
test_export_bad_arguments_show_usage_hint
test_export_does_not_require_apply_flag

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
