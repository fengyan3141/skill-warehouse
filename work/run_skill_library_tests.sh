#!/bin/bash
# Master test runner for the layered Skill library. Runs every isolated
# test suite in a fixed order, then bash -n on every shell entrypoint.
# Never touches real user directories.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PACKAGE="$ROOT"

TESTS=(
  test_env_isolation.sh
  test_skill_package_contract.sh
  test_catalog.sh
  test_skillctl_route.sh
  test_router_evaluation.sh
  test_skillctl_activation.sh
  test_skillctl_export.sh
  test_skillctl_lifecycle.sh
  test_skillctl_cli.sh
  test_skillctl_lint.sh
  test_skillctl_dashboard_autobuild.sh
  test_tool_adapters.sh
  test_skillctl_eject.sh
  test_skillctl_doctor.sh
  test_dashboard.sh
  test_skill_scripts.sh
  test_manager_install.sh
  test_skill_router_package.sh
)

ENTRYPOINTS=(
  "$PACKAGE/skillctl"
  "$PACKAGE/build-catalog.sh"
  "$PACKAGE/build-dashboard.sh"
  "$PACKAGE/evaluate-router.sh"
  "$PACKAGE/sync-skills.sh"
  "$PACKAGE/migrate-skills.sh"
  "$PACKAGE/install-manager.sh"
  "$PACKAGE/双击我安装.command"
)

total_pass=0
total_fail=0
suite_failures=0
syntax_failures=0

printf '== 中文标点静态扫描 ==\n\n'
if ! "$SCRIPT_DIR/check_cjk_punctuation_after_var.sh"; then
  printf '\n裸 $变量 紧跟非 ASCII 字符：这是本项目已经踩过三次的已知坑（见 CLAUDE.md），\n必须先修成 ${变量} 再继续，其余测试不再执行。\n' >&2
  exit 1
fi
printf '\n'

printf '== 测试套件 ==\n\n'
for t in "${TESTS[@]}"; do
  path="$SCRIPT_DIR/$t"
  if [ ! -f "$path" ]; then
    printf '缺少测试文件: %s\n' "$t" >&2
    suite_failures=$((suite_failures + 1))
    continue
  fi
  printf -- '--- %s ---\n' "$t"
  output="$(/bin/bash "$path" 2>&1)"
  status=$?
  printf '%s\n' "$output"
  suite_pass="$(printf '%s\n' "$output" | grep -o 'passed=[0-9]*' | tail -1 | cut -d= -f2)"
  suite_fail="$(printf '%s\n' "$output" | grep -o 'failed=[0-9]*' | tail -1 | cut -d= -f2)"
  total_pass=$((total_pass + ${suite_pass:-0}))
  total_fail=$((total_fail + ${suite_fail:-0}))
  if [ "$status" -ne 0 ]; then
    suite_failures=$((suite_failures + 1))
    printf '*** %s 退出码非零 (%s) ***\n' "$t" "$status" >&2
  fi
  printf '\n'
done

printf '== 语法检查 ==\n\n'
for entry in "${ENTRYPOINTS[@]}"; do
  if [ ! -f "$entry" ]; then
    printf '缺少入口: %s\n' "$entry" >&2
    syntax_failures=$((syntax_failures + 1))
    continue
  fi
  if /bin/bash -n "$entry" 2>&1; then
    printf 'ok - bash -n %s\n' "$entry"
  else
    printf 'not ok - bash -n %s\n' "$entry" >&2
    syntax_failures=$((syntax_failures + 1))
  fi
done

printf '\n== 汇总 ==\n'
printf '测试套件数: %s\n' "${#TESTS[@]}"
printf '断言通过: %s\n' "$total_pass"
printf '断言失败: %s\n' "$total_fail"
printf '异常退出的套件数: %s\n' "$suite_failures"
printf '语法检查失败数: %s\n' "$syntax_failures"

if [ "$total_fail" -eq 0 ] && [ "$suite_failures" -eq 0 ] && [ "$syntax_failures" -eq 0 ]; then
  printf '\n全部通过。\n'
  exit 0
else
  printf '\n存在失败，见上方详情。\n' >&2
  exit 1
fi
