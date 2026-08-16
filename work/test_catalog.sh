#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BUILD="$ROOT/build-catalog.sh"
LIB="$ROOT/lib/skill-lib.sh"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""

cleanup() {
  [ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

write_skill() {
  local directory="$1" content="$2"
  mkdir -p "$directory"
  printf '%s\n' "$content" > "$directory/SKILL.md"
}

test_catalog_folds_descriptions_and_ignores_invalid_skills() {
  local library aliases before catalog field_errors output status
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-catalog-test.XXXXXX")"
  mkdir -p "$TEST_ROOT/home"
  skill_test_env_init "$TEST_ROOT/home"
  library="$SKILL_LIBRARY_ROOT"
  aliases="$SKILL_ALIASES"
  mkdir -p "$library/skills/no-skill"

  write_skill "$library/skills/folded-skill" "---
name: folded-skill
description: >-
  第一行说明，
  第二行继续。
---
body"
  write_skill "$library/skills/literal-skill" "---
name: literal-skill
description: |
  第一行。
  第二行。
---
body"
  write_skill "$library/skills/quoted-skill" "---
name: quoted-skill
description: '单行描述。'
---
body"
  write_skill "$library/skills/bad-name" "---
name: Bad Name
description: 不应进入目录。
---
body"
  printf '%s\n' \
    '# id	display_zh	aliases_zh	category	triggers	excludes' \
    'folded-skill	折叠描述技能	折叠别名	learning	折叠	' > "$aliases"

  before="$(find "$library/skills" -type f | sort)"
  set +e
  output="$(/bin/bash "$BUILD" 2>&1)"
  status=$?
  set -e
  assert_eq "$status" "0" "默认目录生成预演成功"
  assert_not_exists "$library/catalog.tsv" "默认目录生成不写 catalog"
  assert_eq "$(find "$library/skills" -type f | sort)" "$before" "默认目录生成不改 Skill 文件"

  /bin/bash "$BUILD" --apply
  catalog="$(cat "$library/catalog.tsv")"
  field_errors="$(awk -F '\t' 'NF != 8 { n++ } END { print n + 0 }' "$library/catalog.tsv")"

  assert_contains "$catalog" $'folded-skill\tskills/folded-skill\t折叠描述技能' "目录包含中文显示名"
  assert_contains "$catalog" "第一行说明， 第二行继续。" "折叠描述被合并"
  assert_contains "$catalog" "第一行。 第二行。" "literal 描述被压成单行"
  assert_contains "$catalog" "单行描述。" "带引号的单行描述被读取"
  assert_not_contains "$catalog" "Bad Name" "非法名称不进入目录"
  assert_eq "$field_errors" "0" "目录每行固定为八列"
  assert_eq "$(find "$library/skills" -type f | sort)" "$before" "目录生成不改 Skill 文件"
}

test_catalog_failure_preserves_previous_catalog() {
  local library aliases output status
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-catalog-test.XXXXXX")"
  mkdir -p "$TEST_ROOT/home"
  skill_test_env_init "$TEST_ROOT/home"
  library="$SKILL_LIBRARY_ROOT"
  aliases="$SKILL_ALIASES"
  mkdir -p "$library"
  printf '%s\n' 'previous-catalog' > "$library/catalog.tsv"
  printf '%s\n' '# id	display_zh	aliases_zh	category	triggers	excludes' > "$aliases"

  set +e
  output="$(/bin/bash "$BUILD" --apply 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then ok "缺少 skills 目录时生成失败"; else not_ok "缺少 skills 目录时生成失败"; fi
  assert_eq "$(cat "$library/catalog.tsv")" "previous-catalog" "生成失败保留上一版目录"
  assert_contains "$output" "skills" "缺少仓库目录有明确错误"
}

test_atomic_replace_rejects_symlink_and_directory_targets() {
  local link_temp directory_temp external link directory output status
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-catalog-test.XXXXXX")"
  link_temp="$TEST_ROOT/link-replacement.tsv"
  directory_temp="$TEST_ROOT/directory-replacement.tsv"
  external="$TEST_ROOT/external.tsv"
  link="$TEST_ROOT/catalog-link.tsv"
  directory="$TEST_ROOT/catalog-directory"
  printf '%s\n' 'replacement' > "$link_temp"
  printf '%s\n' 'replacement' > "$directory_temp"
  printf '%s\n' 'protected' > "$external"
  ln -s "$external" "$link"
  mkdir "$directory"

  set +e
  output="$(/bin/bash -c '. "$1"; atomic_replace "$2" "$3"' bash "$LIB" "$link_temp" "$link" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then ok "原子替换拒绝外来软链目标"; else not_ok "原子替换拒绝外来软链目标"; fi
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$external" ]; then ok "外来软链保持不变"; else not_ok "外来软链保持不变"; fi
  assert_eq "$(cat "$external")" "protected" "外来软链目标文件保持不变"
  assert_exists "$link_temp" "拒绝软链时临时文件保留"

  set +e
  output="$(/bin/bash -c '. "$1"; atomic_replace "$2" "$3"' bash "$LIB" "$directory_temp" "$directory" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then ok "原子替换拒绝真实目录目标"; else not_ok "原子替换拒绝真实目录目标"; fi
  assert_not_exists "$directory/$(basename "$directory_temp")" "真实目录不接收临时文件"
  assert_exists "$directory_temp" "拒绝目录时临时文件保留"
  assert_eq "$output" "" "拒绝目录不产生额外输出"
}

test_catalog_folds_descriptions_and_ignores_invalid_skills
test_catalog_failure_preserves_previous_catalog
test_atomic_replace_rejects_symlink_and_directory_targets

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
