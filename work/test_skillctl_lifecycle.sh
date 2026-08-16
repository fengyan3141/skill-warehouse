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
ALIASES=""
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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-lifecycle-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ALIASES="$SKILL_ALIASES"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"
  printf '%s\n' '# id	display_zh	aliases_zh	category	triggers	excludes' > "$ALIASES"
  printf 'known-skill\t已知技能\t老技能\ttest\t已知\t\n' >> "$ALIASES"
  add_catalog_row "known-skill" "已知技能"
  make_skill "$LIBRARY/skills/known-skill" "known-skill"
}

make_incoming() {
  local dir="$1" id="$2" body="${3:-body}"
  make_skill "$dir" "$id" "$body"
}

run_skillctl_capture() {
  if SKILLCTL_OUTPUT="$(/bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

test_import_without_display_name_defaults_to_id() {
  local incoming written_display
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"

  run_skillctl_capture import "$incoming"
  assert_eq "$SKILLCTL_STATUS" "0" "无 --display-name 时预演仍成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "默认等于 id" "预演提示 display_name 将默认为 id"
  assert_not_exists "$LIBRARY/skills/test-skill" "预演不创建仓库目录"

  run_skillctl_capture import "$incoming" --apply
  assert_eq "$SKILLCTL_STATUS" "0" "无 --display-name 时 apply 仍能完成导入"
  assert_exists "$LIBRARY/skills/test-skill" "无 --display-name apply 创建仓库目录"
  written_display="$(awk -F '\t' -v id="test-skill" '$1 == id { print $2; exit }' "$ALIASES")"
  assert_eq "$written_display" "test-skill" "别名文件里 display_name 默认等于 id"
  cleanup
  TEST_ROOT=""
}

test_import_creates_skill_and_keeps_source() {
  local incoming before after
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"

  before="$(snapshot_tree "$TEST_ROOT")"
  run_skillctl_capture import "$incoming" --display-name '测试技能'
  assert_eq "$SKILLCTL_STATUS" "0" "导入预演成功退出"
  after="$(snapshot_tree "$TEST_ROOT")"
  assert_eq "$after" "$before" "导入预演不改动临时目录"
  assert_contains "$SKILLCTL_OUTPUT" '[预演] 导入 test-skill' "导入预演输出中文动作"

  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "导入成功退出"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "导入复制 Skill 到仓库"
  assert_exists "$incoming/SKILL.md" "导入不删除来源"
  assert_contains "$(cat "$ALIASES")" "$(printf 'test-skill\t测试技能')" "导入写入中文别名"
  cleanup
  TEST_ROOT=""
}

test_import_identical_is_noop() {
  local incoming before_hash after_hash
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "首次导入成功退出"
  before_hash="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"

  run_skillctl_capture import "$incoming" --apply
  assert_eq "$SKILLCTL_STATUS" "0" "重复导入相同内容成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "已存在" "重复导入报告已存在"
  after_hash="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"
  assert_eq "$after_hash" "$before_hash" "相同内容导入不改动仓库文件"
  cleanup
  TEST_ROOT=""
}

test_import_differing_without_replace_blocks() {
  local incoming incoming2 before after
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill" "body one"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "首次导入成功退出"

  incoming2="$TEST_ROOT/incoming2"
  make_incoming "$incoming2" "test-skill" "body two, different content"

  run_skillctl_capture import "$incoming2"
  assert_contains "$SKILLCTL_OUTPUT" "replace" "内容不同预演提示需要 --replace"

  before="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"
  run_skillctl_capture import "$incoming2" --apply
  assert_contains "$SKILLCTL_OUTPUT" "replace" "未指定 --replace 时 apply 仍被拒绝"
  after="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"
  assert_eq "$after" "$before" "内容冲突且未替换时仓库不变"
  cleanup
  TEST_ROOT=""
}

test_import_replace_archives_old_version() {
  local incoming incoming2 count
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill" "body one"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "首次导入成功退出"

  incoming2="$TEST_ROOT/incoming2"
  make_incoming "$incoming2" "test-skill" "body two, replaced content"

  run_skillctl_capture import "$incoming2" --replace --apply
  assert_eq "$SKILLCTL_STATUS" "0" "替换导入成功退出"
  assert_contains "$(cat "$LIBRARY/skills/test-skill/SKILL.md")" "body two" "替换后仓库内容为新版本"
  count="$(find "$LIBRARY/archive/test-skill" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq "$count" "1" "旧版本移入归档目录"
  assert_exists "$LIBRARY/archive/test-skill/manifest.tsv" "归档写入清单"
  cleanup
  TEST_ROOT=""
}

test_import_recursive_source_refused() {
  make_fixture
  run_skillctl_capture import "$LIBRARY/skills"
  assert_contains "$SKILLCTL_OUTPUT" "仓库内部" "拒绝来源位于仓库内部"
  assert_not_exists "$LIBRARY/skills/skills" "拒绝仓库内部来源不产生新目录"

  run_skillctl_capture import "$TEST_HOME"
  assert_contains "$SKILLCTL_OUTPUT" "祖先目录" "拒绝来源是仓库祖先目录"
  cleanup
  TEST_ROOT=""
}

# 回归测试：真实发现的坑——install-manager.sh --apply 之后，一个全新账户的
# ~/.skill-library 下既没有 skills/ 也没有 catalog.tsv（装机脚本明确不碰
# 这几样）。import 是唯一该在这种"一张白纸"状态下能跑通的命令（它是"从零
# 建仓库"的入口，自己会建 skills/、最后用 rebuild_catalog_or_warn 建出
# catalog.tsv），但它曾经在真正执行前被一刀切的 require_catalog 挡在门口，
# 报"目录不存在: .../catalog.tsv"——这个坑所有既有测试都没测出来，因为每个
# 测试夹具的 make_fixture() 都会顺手预先建一个空 catalog.tsv，恰好绕开了
# 这条路径，只有真的模拟"刚装完、什么都没有"的干净账户才会踩到。
test_import_works_before_catalog_exists() {
  local incoming
  make_fixture
  rm -rf "$LIBRARY/skills" "$LIBRARY/catalog.tsv"
  assert_not_exists "$LIBRARY/catalog.tsv" "夹具模拟全新安装：catalog.tsv 尚不存在"
  assert_not_exists "$LIBRARY/skills" "夹具模拟全新安装：skills 目录尚不存在"

  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "catalog.tsv 不存在时 import 仍能成功导入"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "全新安装下 import 创建仓库目录"
  assert_exists "$LIBRARY/catalog.tsv" "import 完成后自动建出 catalog.tsv"

  run_skillctl_capture status
  assert_eq "$SKILLCTL_STATUS" "0" "import 建出 catalog.tsv 后 status 恢复正常"
  assert_contains "$SKILLCTL_OUTPUT" "test-skill" "status 能看到刚导入的 Skill"
  cleanup
  TEST_ROOT=""
}

test_archive_moves_to_nested_dir_with_manifest() {
  local incoming archive_id_dir archive_id manifest
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --activate --apply
  assert_eq "$SKILLCTL_STATUS" "0" "导入并激活成功退出"
  assert_exists "$TEST_HOME/.agents/skills/test-skill" "导入激活创建受管软链"

  run_skillctl_capture archive test-skill
  assert_eq "$SKILLCTL_STATUS" "0" "归档预演成功退出"
  assert_contains "$SKILLCTL_OUTPUT" '[预演] 归档 test-skill' "归档预演输出中文动作"
  assert_exists "$LIBRARY/skills/test-skill" "归档预演不移动 Skill"
  assert_exists "$TEST_HOME/.agents/skills/test-skill" "归档预演不移除受管软链"

  run_skillctl_capture archive test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "归档成功退出"
  assert_not_exists "$LIBRARY/skills/test-skill" "归档移出活动仓库"
  assert_exists "$LIBRARY/archive/test-skill" "归档目录保留版本"
  assert_not_exists "$TEST_HOME/.agents/skills/test-skill" "归档移除受管软链"

  manifest="$(cat "$LIBRARY/archive/test-skill/manifest.tsv")"
  assert_contains "$manifest" "$(printf 'test-skill\t')" "归档清单记录 Skill ID"
  assert_contains "$manifest" "$TEST_HOME/.agents/skills" "归档清单记录受管链接"

  archive_id_dir="$(find "$LIBRARY/archive/test-skill" -mindepth 1 -maxdepth 1 -type d | head -1)"
  assert_exists "$archive_id_dir/SKILL.md" "归档保留 Skill 内容"
  archive_id="$(basename "$archive_id_dir")"
  case "$archive_id" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-????????) ok "归档 ID 符合时间戳加哈希格式" ;;
    *) not_ok "归档 ID 符合时间戳加哈希格式" ;;
  esac
  cleanup
  TEST_ROOT=""
}

test_archive_blocks_on_unregistered_reference() {
  local incoming
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "blocked-skill"
  run_skillctl_capture import "$incoming" --display-name '受阻技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "受阻技能导入成功退出"

  mkdir -p "$TEST_HOME/.agents/skills/blocked-skill"
  run_skillctl_capture archive blocked-skill --apply
  assert_eq "$SKILLCTL_STATUS" "1" "无法确认归属时归档失败"
  assert_contains "$SKILLCTL_OUTPUT" "无法确认归属" "归档报告未登记引用"
  assert_exists "$LIBRARY/skills/blocked-skill" "阻塞时仓库版本不移动"
  assert_not_exists "$LIBRARY/archive/blocked-skill" "阻塞时不创建归档目录"
  cleanup
  TEST_ROOT=""
}

test_restore_without_and_with_reactivate() {
  local incoming
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --activate --apply
  assert_eq "$SKILLCTL_STATUS" "0" "导入并激活成功退出"
  run_skillctl_capture archive test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "归档前置成功退出"
  assert_not_exists "$LIBRARY/skills/test-skill" "归档前置：Skill 已移出仓库"

  run_skillctl_capture restore test-skill
  assert_eq "$SKILLCTL_STATUS" "0" "恢复预演成功退出"
  assert_not_exists "$LIBRARY/skills/test-skill" "恢复预演不移动内容"

  run_skillctl_capture restore test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "恢复成功退出"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "恢复返回仓库"
  assert_not_exists "$TEST_HOME/.agents/skills/test-skill" "未指定 reactivate 不恢复受管软链"

  run_skillctl_capture activate test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "二次归档前重新激活成功退出"
  run_skillctl_capture archive test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "二次归档成功退出"
  run_skillctl_capture restore test-skill --reactivate --apply
  assert_eq "$SKILLCTL_STATUS" "0" "显式恢复并重新激活成功退出"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "再次恢复返回仓库"
  assert_exists "$TEST_HOME/.agents/skills/test-skill" "显式 reactivate 恢复安全链接"
  assert_eq "$(readlink "$TEST_HOME/.agents/skills/test-skill")" "../../.skill-library/skills/test-skill" "reactivate 恢复标准相对软链"
  cleanup
  TEST_ROOT=""
}

test_restore_blocks_when_skill_already_present() {
  local incoming
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "导入成功退出"

  run_skillctl_capture restore test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "1" "仓库已有同名 Skill 时恢复失败"
  assert_contains "$SKILLCTL_OUTPUT" "已存在" "恢复报告同名冲突"
  cleanup
  TEST_ROOT=""
}

test_restore_reactivation_collision_is_skipped() {
  local incoming
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --activate --apply
  run_skillctl_capture archive test-skill --apply
  assert_eq "$SKILLCTL_STATUS" "0" "归档成功退出"

  mkdir -p "$TEST_HOME/.agents/skills/test-skill"
  run_skillctl_capture restore test-skill --reactivate --apply
  assert_eq "$SKILLCTL_STATUS" "0" "重新激活冲突时恢复仍成功退出"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "内容仍然恢复"
  assert_contains "$SKILLCTL_OUTPUT" '[跳过] 真实目录冲突 test-skill' "重新激活冲突被跳过"
  if [ -L "$TEST_HOME/.agents/skills/test-skill" ]; then
    not_ok "占用目录未被替换为软链"
  else
    ok "占用目录未被替换为软链"
  fi
  cleanup
  TEST_ROOT=""
}

test_replace_rollback_restores_old_version_on_staging_conflict() {
  local incoming incoming2 old_hash new_hash
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "test-skill" "body one"
  run_skillctl_capture import "$incoming" --display-name '测试技能' --apply
  assert_eq "$SKILLCTL_STATUS" "0" "首次导入成功退出"
  old_hash="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"

  incoming2="$TEST_ROOT/incoming2"
  make_incoming "$incoming2" "test-skill" "body two, replaced content"
  mkdir -p "$LIBRARY/skills/.staging-test-skill/blocked"

  run_skillctl_capture import "$incoming2" --replace --apply
  assert_eq "$SKILLCTL_STATUS" "1" "复制失败的替换返回失败"
  assert_contains "$SKILLCTL_OUTPUT" "已回滚" "替换失败报告已回滚"
  assert_exists "$LIBRARY/skills/test-skill/SKILL.md" "回滚后仓库仍有 Skill"
  new_hash="$(shasum -a 256 "$LIBRARY/skills/test-skill/SKILL.md" | awk '{print $1}')"
  assert_eq "$new_hash" "$old_hash" "回滚恢复为旧版本内容"
  cleanup
  TEST_ROOT=""
}

test_import_reuses_existing_alias_without_display_name() {
  local incoming
  make_fixture
  incoming="$TEST_ROOT/incoming"
  make_incoming "$incoming" "known-skill" "different body from catalog fixture"

  run_skillctl_capture import "$incoming" --replace --apply
  assert_eq "$SKILLCTL_STATUS" "0" "已登记别名无需 --display-name 也能导入"
  assert_contains "$(cat "$LIBRARY/skills/known-skill/SKILL.md")" "different body" "已登记别名导入覆盖内容"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_import_without_display_name_defaults_to_id
  test_import_creates_skill_and_keeps_source
  test_import_identical_is_noop
  test_import_differing_without_replace_blocks
  test_import_replace_archives_old_version
  test_import_recursive_source_refused
  test_import_works_before_catalog_exists
  test_archive_moves_to_nested_dir_with_manifest
  test_archive_blocks_on_unregistered_reference
  test_restore_without_and_with_reactivate
  test_restore_blocks_when_skill_already_present
  test_restore_reactivation_collision_is_skipped
  test_replace_rollback_restores_old_version_on_staging_conflict
  test_import_reuses_existing_alias_without_display_name
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
