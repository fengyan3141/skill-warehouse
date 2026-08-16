#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MIGRATE="$ROOT/migrate-skills.sh"
SYNC="$ROOT/sync-skills.sh"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

# 这个套件里每条调用都显式传 HOME="$TEST_HOME"（由 new_home 生成），migrate-skills.sh
# 的仓库目标默认就是 $HOME/.skill-library（跟着每次调用各自的 HOME 走），
# sync-skills.sh 的写入目标也都是 $HOME 派生路径，本来就没有真实环境风险。
# 这里仍先跑一次公共初始化兜底这条测试目前用不到的 SKILL_APPLICATIONS_DIR/
# SKILL_ALIASES/SKILL_PACKAGE_ROOT。但 SKILL_LIBRARY_ROOT/SKILL_ADAPTERS/
# SKILLS_ACTIVE/SKILL_GLOBAL_DIR 都要 unset：这几个变量固定 export 后不会跟着
# 每条调用各自的 HOME="$TEST_HOME" 一起变，会让 migrate 写错仓库目录（已经在
# 这里踩过一次）；SKILL_ADAPTERS 额外需要保留默认值，因为
# test_sync_ignore_and_prune_are_scoped 等用例是在验证 sync-skills.sh 对包自带
# 真实 config/adapters/tools.tsv（比如 trae 的 ~/.trae/skills 映射）的真实行为，
# 不是要伪造一份假适配器表。
ENV_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skill-scripts-env.XXXXXX")"
trap 'rm -rf "$ENV_HOME"' EXIT HUP INT TERM
skill_test_env_init "$ENV_HOME"
unset SKILL_LIBRARY_ROOT SKILL_ADAPTERS SKILLS_ACTIVE SKILL_GLOBAL_DIR

migrate_backup() {
  printf '%s\n' "$TEST_HOME/backup-fixed"
}

test_migrate_dry_run_is_read_only() {
  local backup before after output status
  new_home
  make_skill "$TEST_HOME/.agents/skills/example-1.0.0" example
  make_skill "$TEST_HOME/.claude/skills/other" other
  mkdir -p "$TEST_HOME/.agents/skills/empty-shell"
  backup="$(migrate_backup)"

  before="$(find "$TEST_HOME" -print | sort)"
  output="$(HOME="$TEST_HOME" SKILLS_BACKUP="$backup" /bin/bash "$MIGRATE" 2>&1)"
  status=$?
  after="$(find "$TEST_HOME" -print | sort)"

  assert_eq "$status" 0 "migrate dry-run exits successfully"
  assert_eq "$after" "$before" "migrate dry-run changes nothing"
  assert_contains "$output" "empty-shell（没有 SKILL.md）" "migrate reports shell directories without crashing"
  assert_not_exists "$TEST_HOME/.skill-library" "migrate dry-run does not create the warehouse"
  assert_not_exists "$backup" "migrate dry-run does not create a backup"
  cleanup_home
}

test_migrate_warehouse_target_and_backup() {
  local backup
  new_home
  make_skill "$TEST_HOME/.agents/skills/example" example
  make_skill "$TEST_HOME/.claude/skills/other" other
  backup="$(migrate_backup)"

  HOME="$TEST_HOME" SKILLS_BACKUP="$backup" /bin/bash "$MIGRATE" --apply --conflict=identical >/tmp/skill-migrate-warehouse-test.log 2>&1

  assert_exists "$TEST_HOME/.skill-library/skills/example/SKILL.md" "迁移进入非扫描仓库"
  assert_not_exists "$TEST_HOME/.agents/skills/example" "已迁真实目录不留在全局扫描区"
  assert_exists "$TEST_HOME/.skill-library/skills/other/SKILL.md" "第二个来源也进入仓库"
  assert_not_exists "$TEST_HOME/.claude/skills/other" "已迁 Claude Skill 不留在扫描区"
  assert_exists "$backup/.agents/skills/example/SKILL.md" "应用前备份原全局 Skill"
  assert_exists "$backup/.claude/skills/other/SKILL.md" "应用前备份 Claude Skill"
  # "已迁真实目录不留在全局扫描区" above already proves migration itself
  # leaves no real dir or symlink behind; rebuilding the active shelf is a
  # separate, explicit `skillctl profile use core --apply` step.
  cleanup_home
}

test_migrate_safe_conflicts_and_names() {
  local backup
  new_home
  make_skill "$TEST_HOME/.agents/skills/same-1.0.0" same shared
  make_skill "$TEST_HOME/.claude/skills/same" same shared
  make_skill "$TEST_HOME/.agents/skills/different-1.0.0" different agents
  make_skill "$TEST_HOME/.claude/skills/different" different claude
  make_skill "$TEST_HOME/.agents/skills/gpt-4" gpt-4 legitimate
  make_skill "$TEST_HOME/.agents/skills/vendor-screenwriter" screenwriter shared-screenwriter
  make_skill "$TEST_HOME/.codex/skills/screenwriter" screenwriter shared-screenwriter
  make_skill "$TEST_HOME/.claude/skills/new-one" new-one new
  make_skill "$TEST_HOME/.claude/skills/market-research-1.0.0" 'Market Research' invalid
  make_skill "$TEST_HOME/.claude/skills/memory-1.0.2" 'Memory' invalid
  make_skill "$TEST_HOME/.claude/skills/self-improving-1.1.3" 'Self-Improving Agent (With Self-Reflection)' invalid
  backup="$(migrate_backup)"

  HOME="$TEST_HOME" SKILLS_BACKUP="$backup" /bin/bash "$MIGRATE" --apply --conflict=identical >/tmp/skill-migrate-test.log 2>&1

  assert_exists "$TEST_HOME/.skill-library/skills/same/SKILL.md" "identical duplicate is normalized"
  assert_not_exists "$TEST_HOME/.claude/skills/same" "identical source duplicate is moved out"
  assert_exists "$TEST_HOME/.skill-library/skills/different/SKILL.md" "first-seen versioned skill is normalized"
  assert_exists "$TEST_HOME/.claude/skills/different/SKILL.md" "different conflict remains untouched"
  assert_exists "$TEST_HOME/.skill-library/skills/gpt-4/SKILL.md" "legitimate numeric skill name is preserved"
  assert_exists "$TEST_HOME/.skill-library/skills/screenwriter/SKILL.md" "folder mismatch is normalized to valid declared skill name"
  assert_not_exists "$TEST_HOME/.agents/skills/vendor-screenwriter" "old mismatched folder name is removed after normalization"
  assert_not_exists "$TEST_HOME/.codex/skills/screenwriter" "declared-name duplicate is recognized and moved out"
  assert_exists "$TEST_HOME/.skill-library/skills/new-one/SKILL.md" "non-conflicting skill is migrated"
  assert_exists "$TEST_HOME/.claude/skills/market-research-1.0.0/SKILL.md" "Market Research is left for manual repair"
  assert_exists "$TEST_HOME/.claude/skills/memory-1.0.2/SKILL.md" "Memory is left for manual repair"
  assert_exists "$TEST_HOME/.claude/skills/self-improving-1.1.3/SKILL.md" "Self-Improving Agent is left for manual repair"
  cleanup_home
}

test_migrate_preview_tracks_planned_moves() {
  local backup
  new_home
  make_skill "$TEST_HOME/.claude/skills/two-source" two-source claude-version
  make_skill "$TEST_HOME/.codex/skills/two-source" two-source codex-version
  backup="$(migrate_backup)"

  output="$(HOME="$TEST_HOME" SKILLS_BACKUP="$backup" /bin/bash "$MIGRATE" --conflict=identical 2>&1 | sed $'s/\033\\[[0-9;]*m//g')"
  migrated_count="$(printf '%s\n' "$output" | grep -c '迁入.*two-source' || true)"
  conflict_count="$(printf '%s\n' "$output" | grep -c '冲突.*two-source' || true)"
  assert_eq "$migrated_count" 1 "preview plans a two-source skill only once"
  assert_eq "$conflict_count" 1 "preview reports the second planned source as a conflict"
  assert_exists "$TEST_HOME/.claude/skills/two-source/SKILL.md" "preview leaves first source untouched"
  assert_exists "$TEST_HOME/.codex/skills/two-source/SKILL.md" "preview leaves second source untouched"
  cleanup_home
}

test_migrate_skips_symlinked_source() {
  local backup
  new_home
  mkdir -p "$TEST_HOME/external/real-elsewhere"
  make_skill "$TEST_HOME/external/real-elsewhere" linked-elsewhere
  ln -s "$TEST_HOME/external/real-elsewhere" "$TEST_HOME/.agents/skills/linked-elsewhere"
  backup="$(migrate_backup)"

  HOME="$TEST_HOME" SKILLS_BACKUP="$backup" /bin/bash "$MIGRATE" --apply --conflict=identical >/tmp/skill-migrate-symlink-test.log 2>&1

  assert_not_exists "$TEST_HOME/.skill-library/skills/linked-elsewhere" "migration does not follow a foreign symlink in a source directory"
  assert_exists "$TEST_HOME/.agents/skills/linked-elsewhere" "foreign symlink in source is left untouched"
  cleanup_home
}

test_sync_ignore_and_prune_are_scoped() {
  new_home
  mkdir -p "$TEST_HOME/.trae/skills"
  make_skill "$TEST_HOME/.agents/skills/keep" keep
  make_skill "$TEST_HOME/.agents/skills/ignored" ignored

  HOME="$TEST_HOME" bash "$SYNC" --apply >/tmp/skill-sync-test.log 2>&1
  assert_eq "$(readlink "$TEST_HOME/.trae/skills/keep")" "../../.agents/skills/keep" "sync creates relative managed link"
  assert_eq "$(readlink "$TEST_HOME/.trae/skills/ignored")" "../../.agents/skills/ignored" "sync initially links non-ignored skill"

  printf '%s\n' 'ignored @.trae/skills' > "$TEST_HOME/.agents/.skillignore"
  ln -s ../../somewhere-else "$TEST_HOME/.trae/skills/foreign-broken"
  rm -rf "$TEST_HOME/.agents/skills/keep"
  HOME="$TEST_HOME" bash "$SYNC" --apply --prune >/tmp/skill-sync-test.log 2>&1

  assert_not_exists "$TEST_HOME/.trae/skills/ignored" "new ignore rule removes an existing managed link"
  assert_not_exists "$TEST_HOME/.trae/skills/keep" "prune removes a broken managed link"
  assert_eq "$(readlink "$TEST_HOME/.trae/skills/foreign-broken")" "../../somewhere-else" "prune preserves unrelated broken links"
  cleanup_home
}

test_sync_preserves_foreign_live_link() {
  new_home
  mkdir -p "$TEST_HOME/.trae/skills" "$TEST_HOME/custom/foreign"
  make_skill "$TEST_HOME/.agents/skills/example" example
  make_skill "$TEST_HOME/custom/foreign" foreign
  ln -s ../../custom/foreign "$TEST_HOME/.trae/skills/example"

  output="$(HOME="$TEST_HOME" bash "$SYNC" --apply 2>&1)"
  assert_eq "$(readlink "$TEST_HOME/.trae/skills/example")" "../../custom/foreign" "sync preserves a foreign live symlink"
  assert_contains "$output" "外部软链冲突" "sync reports foreign link conflict"
  cleanup_home
}

assert_exists "$MIGRATE" "corrected migrate script exists"
assert_exists "$SYNC" "corrected sync script exists"

if [ -e "$MIGRATE" ] && [ -e "$SYNC" ]; then
  test_migrate_dry_run_is_read_only
  test_migrate_warehouse_target_and_backup
  test_migrate_safe_conflicts_and_names
  test_migrate_preview_tracks_planned_moves
  test_migrate_skips_symlinked_source
  test_sync_ignore_and_prune_are_scoped
  test_sync_preserves_foreign_live_link
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
