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
BIN_DIR=""
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
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-adapters-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ADAPTERS="$SKILL_ADAPTERS"
  APPS_DIR="$SKILL_APPLICATIONS_DIR"
  BIN_DIR="$TEST_ROOT/bin"
  mkdir -p "$LIBRARY/skills" "$BIN_DIR"
  : > "$LIBRARY/catalog.tsv"

  cat > "$ADAPTERS" <<'EOF'
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
codex	Codex	native	~/.agents/skills	.agents/skills	codex	Codex	已验证
cursor	Cursor	native	~/.agents/skills	.agents/skills	cursor	Cursor	已验证
claude-code	Claude Code	link	~/.claude/skills	.claude/skills	claude-code-fixture-cli	Claude Code	已验证
kiro	Kiro	link	~/.kiro/skills	.kiro/skills	kiro-fixture-cli	Kiro	已验证
untrusted-tool	未验证工具	link	~/.untrusted/skills	.untrusted/skills	untrusted-fixture-cli	UntrustedApp	unverified
EOF

  cat > "$BIN_DIR/codex" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$BIN_DIR/codex"

  mkdir -p "$TEST_HOME/.kiro/skills"

  add_catalog_row "lark-doc" "飞书文档"
  add_catalog_row "warehouse-only" "仅在仓库"
  make_skill "$LIBRARY/skills/lark-doc" "lark-doc"
  make_skill "$LIBRARY/skills/warehouse-only" "warehouse-only"
}

run_skillctl_capture() {
  if SKILLCTL_OUTPUT="$(PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
      /bin/bash "$SKILLCTL" "$@" 2>&1)"; then
    SKILLCTL_STATUS=0
  else
    SKILLCTL_STATUS=$?
  fi
}

test_detect_reports_native_and_residual() {
  make_fixture
  run_skillctl_capture tools detect
  assert_eq "$SKILLCTL_STATUS" "0" "检测命令成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "$(printf 'codex\t已检测\t原生')" "检测原生工具"
  assert_contains "$SKILLCTL_OUTPUT" "$(printf 'kiro\t可能是残留目录\t软链')" "区分只有配置目录的状态"
  assert_contains "$SKILLCTL_OUTPUT" "$(printf 'cursor\t未检测到\t原生')" "未安装的原生工具报告未检测到"
  cleanup
  TEST_ROOT=""
}

test_connect_syncs_only_active_set_and_is_idempotent() {
  local first second
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  assert_eq "$SKILLCTL_STATUS" "0" "激活成功退出"

  run_skillctl_capture tools connect claude-code
  assert_eq "$SKILLCTL_STATUS" "0" "连接预演成功退出"
  assert_not_exists "$TEST_HOME/.claude/skills/lark-doc" "连接预演不创建软链"

  run_skillctl_capture tools connect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "连接成功退出"
  assert_eq "$(readlink "$TEST_HOME/.claude/skills/lark-doc")" "../../.agents/skills/lark-doc" "适配器只同步当前激活集合"
  assert_not_exists "$TEST_HOME/.claude/skills/warehouse-only" "适配器不分发整个仓库"

  first="$(readlink "$TEST_HOME/.claude/skills/lark-doc")"
  run_skillctl_capture tools connect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "重复连接成功退出"
  second="$(readlink "$TEST_HOME/.claude/skills/lark-doc")"
  assert_eq "$second" "$first" "重复连接保持幂等"
  cleanup
  TEST_ROOT=""
}

test_connect_preserves_real_dir_and_foreign_link() {
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  mkdir -p "$TEST_HOME/.claude/skills/lark-doc"
  run_skillctl_capture tools connect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "真实目录冲突时连接仍成功退出"
  assert_exists "$TEST_HOME/.claude/skills/lark-doc" "真实目录冲突时保留原目录"
  if [ -L "$TEST_HOME/.claude/skills/lark-doc" ]; then
    not_ok "真实目录未被替换为软链"
  else
    ok "真实目录未被替换为软链"
  fi

  rm -rf "$TEST_HOME/.claude/skills/lark-doc"
  mkdir -p "$TEST_HOME/external"
  ln -s "$TEST_HOME/external" "$TEST_HOME/.claude/skills/lark-doc"
  run_skillctl_capture tools connect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "外部软链冲突时连接仍成功退出"
  assert_eq "$(readlink "$TEST_HOME/.claude/skills/lark-doc")" "$TEST_HOME/external" "外部软链不被覆盖"
  cleanup
  TEST_ROOT=""
}

test_connect_refuses_unverified_without_flag() {
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  mkdir -p "$TEST_HOME/.untrusted/skills"

  run_skillctl_capture tools connect untrusted-tool --apply
  assert_eq "$SKILLCTL_STATUS" "1" "未验证适配器默认拒绝连接"
  assert_contains "$SKILLCTL_OUTPUT" "allow-unverified" "未验证适配器提示所需旗标"
  assert_not_exists "$TEST_HOME/.untrusted/skills/lark-doc" "未验证适配器拒绝时不创建软链"

  run_skillctl_capture tools connect untrusted-tool --allow-unverified --apply
  assert_eq "$SKILLCTL_STATUS" "0" "显式允许未验证适配器后连接成功"
  assert_eq "$(readlink "$TEST_HOME/.untrusted/skills/lark-doc")" "../../.agents/skills/lark-doc" "显式允许后创建标准相对软链"
  cleanup
  TEST_ROOT=""
}

test_disconnect_removes_only_managed_links() {
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  run_skillctl_capture tools connect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "连接成功退出"

  mkdir -p "$TEST_HOME/external"
  ln -s "$TEST_HOME/external" "$TEST_HOME/.claude/skills/foreign-tool"
  mkdir -p "$TEST_HOME/.claude/skills/real-tool"

  run_skillctl_capture tools disconnect claude-code
  assert_eq "$SKILLCTL_STATUS" "0" "断开预演成功退出"
  assert_exists "$TEST_HOME/.claude/skills/lark-doc" "断开预演不移除软链"

  run_skillctl_capture tools disconnect claude-code --apply
  assert_eq "$SKILLCTL_STATUS" "0" "断开成功退出"
  assert_not_exists "$TEST_HOME/.claude/skills/lark-doc" "断开移除受管软链"
  assert_eq "$(readlink "$TEST_HOME/.claude/skills/foreign-tool")" "$TEST_HOME/external" "断开保留外部软链"
  assert_exists "$TEST_HOME/.claude/skills/real-tool" "断开保留真实目录"
  cleanup
  TEST_ROOT=""
}

test_native_connect_and_disconnect_are_noop() {
  local before after
  make_fixture
  run_skillctl_capture activate lark-doc --apply
  before="$(find "$TEST_HOME/.agents/skills" -print | LC_ALL=C sort)"

  run_skillctl_capture tools connect codex --apply
  assert_eq "$SKILLCTL_STATUS" "0" "原生适配器连接成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "原生模式" "原生适配器连接报告无需操作"
  after="$(find "$TEST_HOME/.agents/skills" -print | LC_ALL=C sort)"
  assert_eq "$after" "$before" "原生适配器连接不改动全局目录"

  run_skillctl_capture tools disconnect codex --apply
  assert_eq "$SKILLCTL_STATUS" "0" "原生适配器断开成功退出"
  assert_contains "$SKILLCTL_OUTPUT" "原生模式" "原生适配器断开报告无需操作"
  cleanup
  TEST_ROOT=""
}

assert_exists "$SKILLCTL" "skillctl 入口存在"
if [ -f "$SKILLCTL" ]; then
  test_detect_reports_native_and_residual
  test_connect_syncs_only_active_set_and_is_idempotent
  test_connect_preserves_real_dir_and_foreign_link
  test_connect_refuses_unverified_without_flag
  test_disconnect_removes_only_managed_links
  test_native_connect_and_disconnect_are_noop
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
