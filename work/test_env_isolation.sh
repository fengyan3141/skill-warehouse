#!/bin/bash
# 验收 test_env_common.sh 本身：证明调用点只要经过 skill_test_env_init 初始化过
# 一次，后面即使不在每条命令前手动重复列 HOME=/SKILL_xxx= 前缀（也就是"故意
# 不设某个变量"、指望它已经在环境里），也不会碰真实的 ~/.skill-library、
# ~/.agents/skills、/Applications、包自带 config/ 目录。
# 做法：跑之前跑之后各对这些真实目录拍一次快照，要求逐字节一致。
set -uo pipefail

REAL_HOME="$HOME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PACKAGE="$ROOT"
SKILLCTL="$PACKAGE/skillctl"
INSTALLER="$PACKAGE/install-manager.sh"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
  fi
  return 0
}
trap cleanup EXIT HUP INT TERM

add_catalog_row() {
  local library="$1" id="$2" display="$3"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'test' "$display" '' "测试 $display" >> "$library/catalog.tsv"
}

test_no_manual_var_prefix_never_touches_real_dirs() {
  local before after test_home library

  before="$(skill_test_env_snapshot_real_dirs "$REAL_HOME" "$PACKAGE")"

  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-env-isolation-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  test_home="$TEST_ROOT/home"
  mkdir -p "$test_home"
  skill_test_env_init "$test_home"

  library="$SKILL_LIBRARY_ROOT"
  mkdir -p "$library/skills"
  : > "$library/catalog.tsv"
  make_skill "$library/skills/isolation-fixture" "isolation-fixture"
  add_catalog_row "$library" "isolation-fixture" "隔离夹具"

  # 刻意不在下面任何一条调用前手动拼 HOME=/SKILL_xxx= 前缀——全部依赖
  # skill_test_env_init 已经 export 好的进程环境，覆盖会读 SKILL_APPLICATIONS_DIR
  # 的 tools detect/doctor、会读 SKILL_ALIASES 的 search、会读 SKILL_ADAPTERS 的
  # dashboard build、会写 SKILLS_ACTIVE 的 activate、会读 SKILL_PACKAGE_ROOT 的
  # install-manager 预演。
  /bin/bash "$SKILLCTL" status >/dev/null 2>&1
  /bin/bash "$SKILLCTL" search '隔离' >/dev/null 2>&1
  /bin/bash "$SKILLCTL" tools detect >/dev/null 2>&1
  /bin/bash "$SKILLCTL" doctor >/dev/null 2>&1
  /bin/bash "$SKILLCTL" activate isolation-fixture --apply >/dev/null 2>&1
  /bin/bash "$SKILLCTL" dashboard build --apply >/dev/null 2>&1
  /bin/bash "$INSTALLER" >/dev/null 2>&1

  after="$(skill_test_env_snapshot_real_dirs "$REAL_HOME" "$PACKAGE")"

  assert_eq "$after" "$before" "调用点省略变量前缀跑完一整轮命令后，真实目录快照与跑之前逐字节一致"

  cleanup
  TEST_ROOT=""
}

test_no_manual_var_prefix_never_touches_real_dirs

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
