#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALLER="$ROOT/install-manager.sh"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
TEST_HOME=""
LIBRARY=""
INSTALLER_OUTPUT=""
INSTALLER_STATUS=""

cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
  fi
  return 0
}
trap cleanup EXIT HUP INT TERM

make_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-install-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  # 这个套件默认就是要装"当前真实包"进沙箱化的 LIBRARY，SKILL_PACKAGE_ROOT
  # 的默认值（install-manager.sh 自己所在目录）本来就该是真实源码——沙箱要
  # 隔离的是写入目标（SKILL_LIBRARY_ROOT），不是这个只读源。unset 掉换回
  # install-manager.sh 自己的默认解析逻辑；run_installer_from_package_capture
  # 测坏包场景时会显式覆盖成假包路径。
  unset SKILL_PACKAGE_ROOT
  LIBRARY="$SKILL_LIBRARY_ROOT"
  mkdir -p "$LIBRARY/skills/keep" "$LIBRARY/archive/some-id/20260101-000000-deadbeef" "$LIBRARY/state"
  printf '%s\n' '---' 'name: keep' 'description: 测试' '---' 'body' > "$LIBRARY/skills/keep/SKILL.md"
  printf 'marker\n' > "$LIBRARY/archive/some-id/20260101-000000-deadbeef/marker.txt"
  printf 'state-marker\n' > "$LIBRARY/state/marker.txt"
  printf 'id\trelative_path\tdisplay\talias\tcategory\ttriggers\texcludes\tdescription\n' > "$LIBRARY/catalog.tsv"
}

run_installer_capture() {
  if INSTALLER_OUTPUT="$(/bin/bash "$INSTALLER" "$@" 2>&1)"; then
    INSTALLER_STATUS=0
  else
    INSTALLER_STATUS=$?
  fi
}

run_installer_from_package_capture() {
  local package_root="$1"
  shift
  if INSTALLER_OUTPUT="$(SKILL_PACKAGE_ROOT="$package_root" /bin/bash "$INSTALLER" "$@" 2>&1)"; then
    INSTALLER_STATUS=0
  else
    INSTALLER_STATUS=$?
  fi
}

test_dry_run_leaves_tree_unchanged() {
  local before after
  make_fixture
  before="$(find "$TEST_ROOT" -print | LC_ALL=C sort)"
  run_installer_capture
  assert_eq "$INSTALLER_STATUS" "0" "预演成功退出"
  after="$(find "$TEST_ROOT" -print | LC_ALL=C sort)"
  assert_eq "$after" "$before" "管理组件安装器默认只预演"
  cleanup
  TEST_ROOT=""
}

test_initial_install_creates_managed_files_without_touching_skills() {
  local skill_hash_before skill_hash_after archive_marker_before archive_marker_after state_marker_before state_marker_after
  make_fixture
  skill_hash_before="$(shasum -a 256 "$LIBRARY/skills/keep/SKILL.md")"
  archive_marker_before="$(cat "$LIBRARY/archive/some-id/20260101-000000-deadbeef/marker.txt")"
  state_marker_before="$(cat "$LIBRARY/state/marker.txt")"
  catalog_before="$(cat "$LIBRARY/catalog.tsv")"

  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "首次安装成功退出"
  assert_exists "$LIBRARY/bin/skillctl" "安装稳定 skillctl 路径"
  assert_exists "$LIBRARY/bin/build-catalog.sh" "安装 build-catalog.sh"
  assert_exists "$LIBRARY/bin/build-dashboard.sh" "安装 build-dashboard.sh"
  assert_exists "$LIBRARY/bin/evaluate-router.sh" "安装 evaluate-router.sh"
  assert_exists "$LIBRARY/bin/sync-skills.sh" "安装 sync-skills.sh"
  assert_not_exists "$LIBRARY/bin/migrate-skills.sh" "不安装迁移脚本到运行时管理组件"
  assert_exists "$LIBRARY/config/aliases.tsv" "安装中文别名配置"
  assert_exists "$LIBRARY/config/adapters/tools.tsv" "安装软件适配器配置"
  assert_exists "$LIBRARY/config/profiles/core" "安装场景包配置"
  assert_exists "$LIBRARY/lib/skill-lib.sh" "安装共用函数"

  skill_hash_after="$(shasum -a 256 "$LIBRARY/skills/keep/SKILL.md")"
  archive_marker_after="$(cat "$LIBRARY/archive/some-id/20260101-000000-deadbeef/marker.txt")"
  state_marker_after="$(cat "$LIBRARY/state/marker.txt")"
  catalog_after="$(cat "$LIBRARY/catalog.tsv")"
  assert_eq "$skill_hash_after" "$skill_hash_before" "安装器不改 Skill"
  assert_eq "$archive_marker_after" "$archive_marker_before" "安装器不改归档目录"
  assert_eq "$state_marker_after" "$state_marker_before" "安装器不改状态目录"
  assert_eq "$catalog_after" "$catalog_before" "安装器不改 catalog.tsv"

  if [ -x "$LIBRARY/bin/skillctl" ]; then
    ok "安装后 skillctl 可执行"
  else
    not_ok "安装后 skillctl 可执行"
  fi
  cleanup
  TEST_ROOT=""
}

test_installed_scripts_resolve_own_config_from_bin_layout() {
  local list_output
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "安装成功退出"

  if list_output="$(/bin/bash "$LIBRARY/bin/skillctl" list 2>&1)"; then
    ok "已安装的 skillctl 能在 bin/ 布局下找到 lib 与 config"
  else
    not_ok "已安装的 skillctl 能在 bin/ 布局下找到 lib 与 config"
  fi
  assert_not_contains "$list_output" "共享函数不存在" "已安装 skillctl 找到共用函数"
  cleanup
  TEST_ROOT=""
}

test_upgrade_backs_up_previous_manager() {
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "首次安装成功退出"
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "二次安装（升级）成功退出"
  assert_exists "$LIBRARY/manager-backups" "升级前备份旧管理组件"
  local backup_count
  backup_count="$(find "$LIBRARY/manager-backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq "$backup_count" "1" "每次升级产生一份带时间戳的备份"
  assert_exists "$LIBRARY/manager-backups"/*/bin/skillctl "备份包含旧版 skillctl"
  cleanup
  TEST_ROOT=""
}

test_invalid_staged_package_rolls_back() {
  local before_hash after_hash broken_package real_package
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "首次安装成功退出"
  before_hash="$(shasum -a 256 "$LIBRARY/bin/skillctl" | awk '{print $1}')"

  # Build a throwaway broken-package copy under TEST_ROOT so this never
  # touches the real repo package, even transiently.
  real_package="$ROOT"
  broken_package="$TEST_ROOT/broken-package"
  mkdir -p "$broken_package/lib"
  cp "$real_package"/skillctl "$real_package"/build-catalog.sh "$real_package"/build-dashboard.sh \
    "$real_package"/dashboard-server.py "$real_package"/evaluate-router.sh "$real_package"/sync-skills.sh \
    "$broken_package/"
  cp "$real_package/lib/skill-lib.sh" "$broken_package/lib/skill-lib.sh"
  cp -R "$real_package/config" "$broken_package/config"
  printf 'if [ then broken shell syntax\n' >> "$broken_package/skillctl"

  run_installer_from_package_capture "$broken_package" --apply
  assert_eq "$INSTALLER_STATUS" "1" "非法打包内容安装失败"
  assert_contains "$INSTALLER_OUTPUT" "语法校验失败" "安装器报告语法校验失败"

  after_hash="$(shasum -a 256 "$LIBRARY/bin/skillctl" | awk '{print $1}')"
  assert_eq "$after_hash" "$before_hash" "校验失败时已安装的管理组件哈希不变"
  cleanup
  TEST_ROOT=""
}

test_upgrade_preserves_personal_aliases_and_profiles_but_syncs_adapters() {
  local aliases_before profiles_core_before adapters_before adapters_after mystuff_before
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "首次安装成功退出"

  # 首次安装后模拟"用户已经定制过"：往 aliases.tsv 加一行私货、改动
  # core（包里也有同名文件）、新增一个包里根本没有的场景包文件。
  printf 'my-real-skill\t我的真实技能\t别名\tpersonal\t触发词\t\n' >> "$LIBRARY/config/aliases.tsv"
  printf 'my-real-skill\n' >> "$LIBRARY/config/profiles/core"
  printf 'commit-message-writer\n' > "$LIBRARY/config/profiles/mystuff"
  printf 'INJECTED-MARKER\ttest\tnative\t~/.agents/skills\t.agents/skills\ttest\tTest\ttest\n' >> "$LIBRARY/config/adapters/tools.tsv"

  aliases_before="$(cat "$LIBRARY/config/aliases.tsv")"
  profiles_core_before="$(cat "$LIBRARY/config/profiles/core")"
  mystuff_before="$(cat "$LIBRARY/config/profiles/mystuff")"
  adapters_before="$(cat "$LIBRARY/config/adapters/tools.tsv")"

  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "二次安装（升级）成功退出"

  assert_eq "$(cat "$LIBRARY/config/aliases.tsv")" "$aliases_before" "升级不覆盖已定制的 aliases.tsv"
  assert_eq "$(cat "$LIBRARY/config/profiles/core")" "$profiles_core_before" "升级不覆盖已定制的 core 场景包（哪怕包里也有同名文件）"
  assert_eq "$(cat "$LIBRARY/config/profiles/mystuff")" "$mystuff_before" "升级不动包里根本没有的自定义场景包"
  assert_contains "$INSTALLER_OUTPUT" "保留已有的 config/aliases.tsv" "输出说明为什么没动 aliases.tsv"
  assert_contains "$INSTALLER_OUTPUT" "保留已有的 config/profiles/core" "输出说明为什么没动 core"

  adapters_after="$(cat "$LIBRARY/config/adapters/tools.tsv")"
  assert_not_contains "$adapters_after" "INJECTED-MARKER" "adapters/tools.tsv 仍然整体跟包同步（不是个人数据）"
  [ "$adapters_after" != "$adapters_before" ] && ok "adapters/tools.tsv 升级后恢复成包里的版本" || not_ok "adapters/tools.tsv 升级后恢复成包里的版本"
  cleanup
  TEST_ROOT=""
}

test_upgrade_seeds_new_package_profile_not_present_locally() {
  local extended_package
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "首次安装成功退出"
  assert_not_exists "$LIBRARY/config/profiles/extra-from-package" "升级前本地还没有这个场景包"

  # 造一份比真实包多一个场景包文件的临时包，模拟"包这次升级新增了一个
  # 场景包，本地之前没有"的场景——新场景包应该被种进来，不受"已存在就不
  # 覆盖"规则影响（规则只保护本地已经有的文件）。
  extended_package="$TEST_ROOT/extended-package"
  mkdir -p "$extended_package"
  /usr/bin/rsync -a --exclude=work --exclude=CLAUDE.md --exclude=.git "$ROOT/" "$extended_package/"
  printf 'skill-router\n' > "$extended_package/config/profiles/extra-from-package"

  run_installer_from_package_capture "$extended_package" --apply
  assert_eq "$INSTALLER_STATUS" "0" "升级到扩展包成功退出"
  assert_exists "$LIBRARY/config/profiles/extra-from-package" "包里新增的场景包会被种进本地（本地之前没有，不算覆盖）"
  assert_eq "$(cat "$LIBRARY/config/profiles/extra-from-package")" "skill-router" "新种入的场景包内容跟包一致"
  cleanup
  TEST_ROOT=""
}

test_installer_does_not_touch_shell_profile_or_path() {
  make_fixture
  run_installer_capture --apply
  assert_eq "$INSTALLER_STATUS" "0" "安装成功退出"
  assert_not_exists "$TEST_HOME/.zshrc" "安装器不修改 shell PATH"
  assert_not_exists "$TEST_HOME/.bash_profile" "安装器不创建 bash profile"
  assert_not_exists "$TEST_HOME/.profile" "安装器不创建通用 profile"
  cleanup
  TEST_ROOT=""
}

assert_exists "$INSTALLER" "安装器入口存在"
if [ -f "$INSTALLER" ]; then
  test_dry_run_leaves_tree_unchanged
  test_initial_install_creates_managed_files_without_touching_skills
  test_installed_scripts_resolve_own_config_from_bin_layout
  test_upgrade_backs_up_previous_manager
  test_upgrade_preserves_personal_aliases_and_profiles_but_syncs_adapters
  test_upgrade_seeds_new_package_profile_not_present_locally
  test_invalid_staged_package_rolls_back
  test_installer_does_not_touch_shell_profile_or_path
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
