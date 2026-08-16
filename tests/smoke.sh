#!/bin/bash
# tests/smoke.sh — end-to-end regression test for the core skillctl command
# chain, run explicitly under /bin/bash (macOS's system bash, 3.2).
#
# `bash -n` only catches syntax errors; it cannot catch runtime-only
# incompatibilities. This project has already shipped one such bug: setting
# IFS to a control character (`$'\001'`) parsed fine under `bash -n` and
# under newer bash, but silently failed to split fields at all under real
# bash 3.2. This script exists so that class of bug gets caught by running
# the actual command chain, not by grepping for known-bad syntax patterns.
#
# Run this after any change to skillctl / sync-skills.sh / build-catalog.sh
# — it is not a one-off, it is the project's regression test.
#
# Builds a throwaway HOME with a minimal fake catalog, two fake skills, and
# one fake "link" mode tool, then drives:
#   status -> import -> activate -> profile use -> tools detect ->
#   tools connect -> deactivate -> doctor -> lint -> eject
#
# activate runs before profile use on purpose: it regression-tests the
# manual.list protection (see step 4/10 below) — a skill activated on its own
# via `activate` must survive a later `profile use` for an unrelated
# profile, not get silently pruned by it.
#
# `eject` runs last on purpose: it physicalizes every managed symlink still
# standing, which permanently changes the nature of the fixture — nothing
# after it could exercise link-based behavior anymore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKILLCTL="$PACKAGE_ROOT/skillctl"
BASH_BIN="/bin/bash"

[ -x "$BASH_BIN" ] || { printf '需要系统自带 %s，未找到，无法跑冒烟测试\n' "$BASH_BIN" >&2; exit 1; }
[ -f "$SKILLCTL" ] || { printf 'skillctl 不存在: %s\n' "$SKILLCTL" >&2; exit 1; }

pass=0
fail=0
ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
not_ok() { printf 'not ok - %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    printf '  got:  %s\n  want: %s\n' "$1" "$2" >&2
    not_ok "$3"
  fi
}

assert_exists() { if [ -e "$1" ] || [ -L "$1" ]; then ok "$2"; else not_ok "$2"; fi; }
assert_not_exists() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok "$2"; else not_ok "$2"; fi; }
assert_contains() { if printf '%s' "$1" | grep -F -- "$2" >/dev/null; then ok "$3"; else not_ok "$3"; fi; }
assert_not_contains() { if ! printf '%s' "$1" | grep -F -- "$2" >/dev/null; then ok "$3"; else not_ok "$3"; fi; }

TEST_HOME=""
cleanup() {
  [ -n "$TEST_HOME" ] || return 0
  chmod -R u+rwX "$TEST_HOME" 2>/dev/null || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT HUP INT TERM

SKILLCTL_OUTPUT=""
SKILLCTL_STATUS=""
run() {
  set +e
  SKILLCTL_OUTPUT="$(HOME="$TEST_HOME" SKILL_LIBRARY_ROOT="$LIBRARY" SKILL_ADAPTERS="$ADAPTERS" SKILL_ALIASES="$ALIASES" "$BASH_BIN" "$SKILLCTL" "$@" 2>&1)"
  SKILLCTL_STATUS=$?
  set -e
}

make_skill() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  printf '%s\n' '---' "name: $name" "description: 冒烟测试用 skill $name" '---' '冒烟测试内容' > "$dir/SKILL.md"
}

add_catalog_row() {
  local id="$1" display="$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "skills/$id" "$display" '' 'smoke' "$display" '' "冒烟测试 $display" >> "$LIBRARY/catalog.tsv"
}

# ---------- 搭建假环境 ----------

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-smoke.XXXXXX")"
TEST_HOME="$(cd "$TEST_HOME" && pwd -P)"
LIBRARY="$TEST_HOME/.skill-library"
ADAPTERS="$TEST_HOME/tools.tsv"
ALIASES="$TEST_HOME/aliases.tsv"
FAKE_TOOL_DIR="$TEST_HOME/.fake-tool/skills"
MANUAL_LIST="$LIBRARY/state/manual.list"

mkdir -p "$LIBRARY/skills" "$TEST_HOME/.agents/skills"
: > "$LIBRARY/catalog.tsv"
printf '%s\n' '# id	display_zh	aliases_zh	category	triggers	excludes' > "$ALIASES"

# 两个假 skill：
#   smoke-fixture-a  — 独立个体，测 activate/deactivate
#   code-review-checklist — 借用仓库真实的 core 场景包（它两个成员之一）
# 之所以借用真实场景包名而不是伪造一个，是因为 PROFILE_DIR 目前硬编码为
# "$PACKAGE_ROOT/config/profiles"，没有像 SKILL_ADAPTERS/SKILL_ALIASES 那样
# 提供环境变量覆盖，没法在沙箱里伪造独立场景包文件。
make_skill "$LIBRARY/skills/smoke-fixture-a" "smoke-fixture-a"
add_catalog_row "smoke-fixture-a" "冒烟测试甲"
make_skill "$LIBRARY/skills/code-review-checklist" "code-review-checklist"
add_catalog_row "code-review-checklist" "冒烟测试乙"

cat > "$ADAPTERS" << EOF
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
fake-link-tool	假工具	link	$FAKE_TOOL_DIR	.fake-tool/skills	__smoke_test_no_such_cli__	__SmokeTestNoSuchApp__	冒烟测试固定适配器
EOF

echo "== 1/10 status =="
run status
assert_eq "$SKILLCTL_STATUS" "0" "status 成功退出"
assert_contains "$SKILLCTL_OUTPUT" "smoke-fixture-a" "status 列出仓库中的假 skill"

echo "== 2/10 import（不给 --display-name，验证默认等于 id）=="
INCOMING="$TEST_HOME/incoming/smoke-imported"
make_skill "$INCOMING" "smoke-imported"
run import "$INCOMING" --apply
assert_eq "$SKILLCTL_STATUS" "0" "import 成功退出"
assert_exists "$LIBRARY/skills/smoke-imported" "import 在仓库里创建目录"
written_display="$(awk -F '\t' -v id="smoke-imported" '$1 == id { print $2; exit }' "$ALIASES")"
assert_eq "$written_display" "smoke-imported" "import 缺省 display_name 等于 id"

echo "== 3/10 activate（单独激活一个不属于任何场景包的孤儿 skill）=="
run activate smoke-fixture-a --apply
assert_eq "$SKILLCTL_STATUS" "0" "activate 成功退出"
assert_exists "$TEST_HOME/.agents/skills/smoke-fixture-a" "activate 建立软链"
assert_eq \
  "$(cd "$TEST_HOME/.agents/skills/smoke-fixture-a" && pwd -P)" \
  "$(cd "$LIBRARY/skills/smoke-fixture-a" && pwd -P)" \
  "软链指向仓库内正确目录"
manual_after_activate="$(cat "$MANUAL_LIST" 2>/dev/null || true)"
assert_contains "$manual_after_activate" "smoke-fixture-a" "activate 把 id 写入 manual.list"

# 回归断言：以前 profile_ids() 的目标集合是 core∪场景包，会把上面这个孤儿
# skill 静默清掉（真实发现，见提交记录）；修复后目标集合是
# core∪场景包∪manual.list，孤儿 skill 应该在切换场景包（这里就是 core 本身，
# 借它两个真实成员之一）之后依然存活。旧版本这里断言的是
# "先 profile use 再 activate 来绕开这个问题"，现在反过来正面验证修复本身，
# 不再留一套自相矛盾的预期。
echo "== 4/10 profile use core（孤儿 skill 必须挺过切换）=="
run profile use core --apply
assert_eq "$SKILLCTL_STATUS" "0" "profile use 成功退出"
assert_exists "$TEST_HOME/.agents/skills/code-review-checklist" "profile use 建立场景包成员软链"
assert_eq \
  "$(cd "$TEST_HOME/.agents/skills/code-review-checklist" && pwd -P)" \
  "$(cd "$LIBRARY/skills/code-review-checklist" && pwd -P)" \
  "场景包软链指向仓库内正确目录"
assert_exists "$TEST_HOME/.agents/skills/smoke-fixture-a" "手动激活的孤儿 skill 在切换场景包后仍然存活"
assert_not_contains "$SKILLCTL_OUTPUT" "停用" "profile use 输出里没有停用 smoke-fixture-a"

echo "== 5/10 tools detect =="
run tools detect
assert_eq "$SKILLCTL_STATUS" "0" "tools detect 成功退出"
assert_contains "$SKILLCTL_OUTPUT" "fake-link-tool" "tools detect 输出包含假工具"

echo "== 6/10 tools connect =="
run tools connect fake-link-tool --apply
assert_eq "$SKILLCTL_STATUS" "0" "tools connect 成功退出"
assert_exists "$FAKE_TOOL_DIR/smoke-fixture-a" "tools connect 同步 activate 建立的 skill"
assert_exists "$FAKE_TOOL_DIR/code-review-checklist" "tools connect 同步场景包激活的 skill"

echo "== 7/10 deactivate =="
run deactivate smoke-fixture-a --apply
assert_eq "$SKILLCTL_STATUS" "0" "deactivate 成功退出"
assert_not_exists "$TEST_HOME/.agents/skills/smoke-fixture-a" "deactivate 移除软链"
manual_after_deactivate="$(cat "$MANUAL_LIST" 2>/dev/null || true)"
assert_not_contains "$manual_after_deactivate" "smoke-fixture-a" "deactivate 把 id 从 manual.list 移除"

echo "== 8/10 doctor（上一步 deactivate 之后，FAKE_TOOL_DIR 下的 smoke-fixture-a 变成了断链）=="
run doctor
assert_eq "$SKILLCTL_STATUS" "1" "doctor 检测到断链后非零退出"
assert_contains "$SKILLCTL_OUTPUT" "断链" "doctor 报告断链"
assert_contains "$SKILLCTL_OUTPUT" "tools connect fake-link-tool --prune --apply" "doctor 断链修复建议指向 tools connect --prune"

echo "== 9/10 lint =="
run lint
assert_eq "$SKILLCTL_STATUS" "0" "lint 成功退出（假 skill 的 frontmatter 都齐全）"
assert_contains "$SKILLCTL_OUTPUT" "frontmatter 完整" "lint 报告 frontmatter 完整性"

echo "== 10/10 eject（本脚本最后一步：把剩余受管软链物化为真实拷贝，之后夹具不再有 skillctl 管理的软链）=="
run eject
assert_eq "$SKILLCTL_STATUS" "0" "eject 预演成功退出"
assert_contains "$SKILLCTL_OUTPUT" "[预演] 物化" "eject 预演输出物化动作"
assert_exists "$TEST_HOME/.agents/skills/code-review-checklist" "eject 预演不改动软链"

run eject --apply
assert_eq "$SKILLCTL_STATUS" "0" "eject apply 成功退出"
assert_contains "$SKILLCTL_OUTPUT" "已脱离 skillctl 管理" "eject 报告已脱离管理"
if [ -L "$TEST_HOME/.agents/skills/code-review-checklist" ]; then
  not_ok "eject 把全局目录里的场景包软链物化为真实目录"
else
  ok "eject 把全局目录里的场景包软链物化为真实目录"
fi
if [ -L "$FAKE_TOOL_DIR/code-review-checklist" ]; then
  not_ok "eject 把工具目录里的软链物化为真实目录"
else
  ok "eject 把工具目录里的软链物化为真实目录"
fi
assert_exists "$FAKE_TOOL_DIR/code-review-checklist/SKILL.md" "eject 后工具目录仍保留 Skill 内容"
if [ -L "$FAKE_TOOL_DIR/smoke-fixture-a" ]; then
  ok "eject 不碰已经断掉的软链（那是 doctor 的职责，不是 eject 的）"
else
  not_ok "eject 不碰已经断掉的软链（那是 doctor 的职责，不是 eject 的）"
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
