#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKILLCTL="$ROOT/skillctl"
BUILD="$ROOT/build-dashboard.sh"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
TEST_HOME=""
LIBRARY=""
ADAPTERS=""
HTML=""
BUILD_OUTPUT=""
BUILD_STATUS=""

cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
  fi
  return 0
}
trap cleanup EXIT HUP INT TERM

add_catalog_row() {
  local id="$1" relative_path="$2" display="$3" aliases="$4" category="$5" triggers="$6" excludes="$7" description="$8"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$relative_path" "$display" "$aliases" "$category" "$triggers" "$excludes" "$description" >> "$LIBRARY/catalog.tsv"
}

make_fixture() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skill-dashboard-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  TEST_HOME="$TEST_ROOT/home"
  mkdir -p "$TEST_HOME"
  skill_test_env_init "$TEST_HOME"
  LIBRARY="$SKILL_LIBRARY_ROOT"
  ADAPTERS="$SKILL_ADAPTERS"
  HTML="$LIBRARY/dashboard/index.html"
  mkdir -p "$LIBRARY/skills"
  : > "$LIBRARY/catalog.tsv"

  cat > "$ADAPTERS" <<'EOF'
# id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
codex	Codex	native	~/.agents/skills	.agents/skills	codex-fixture-cli	Codex	已验证
cursor	Cursor	native	~/.agents/skills	.agents/skills	cursor-fixture-cli	Cursor	已验证
gemini-cli	Gemini CLI	native	~/.agents/skills	.agents/skills	gemini-fixture-cli	Gemini CLI	已验证
claude-code	Claude Code	link	~/.claude/skills	.claude/skills	claude-fixture-cli	Claude Code	已验证
kiro	Kiro	link	~/.kiro/skills	.kiro/skills	kiro-fixture-cli	Kiro	已验证
trae	Trae	link	~/.trae/skills	.trae/skills	trae-fixture-cli	Trae	已验证
codebuddy	CodeBuddy	link	~/.codebuddy/skills	.codebuddy/skills	codebuddy-fixture-cli	CodeBuddy	已验证
qoder	Qoder	link	~/.qoder/skills	.qoder/skills	qoder-fixture-cli	Qoder	已验证
EOF

  # 面板现在会把"内置适配器里没检测到的"直接隐藏（噪音过滤，见
  # build-dashboard.sh 里 BUILTIN_TOOL_IDS 那段注释），不像 v1 时不管装没
  # 装都全量展示。这份夹具要验证"每个适配器的信息正确展示"，就必须先让
  # 它们都能被判定为"已检测"——伪造每个 cli_command 对应的可执行文件、
  # 塞进一个只在本次测试生效的 PATH 前缀目录，不去碰真实系统 PATH。
  mkdir -p "$TEST_ROOT/fake-bin"
  local cli
  for cli in codex-fixture-cli cursor-fixture-cli gemini-fixture-cli claude-fixture-cli \
             kiro-fixture-cli trae-fixture-cli codebuddy-fixture-cli qoder-fixture-cli; do
    printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/fake-bin/$cli"
    chmod +x "$TEST_ROOT/fake-bin/$cli"
  done
  export PATH="$TEST_ROOT/fake-bin:$PATH"

  add_catalog_row "ai-product-teardown" "skills/ai-product-teardown" "AI 产品拆解" "产品拆解" "product" "拆解" "" "深度拆解 <AI> 产品 & 架构"
  add_catalog_row "lark-doc" "skills/lark-doc" "飞书文档" "云文档" "lark" "飞书文档" "" "读取并编辑\"飞书\"文档"
  add_catalog_row "warehouse-only" "skills/warehouse-only" "仅在仓库" "" "test" "" "" "尚未激活的 Skill"
  add_catalog_row "conflict-skill" "skills/conflict-skill" "冲突技能" "" "test" "" "" "用于制造真实目录冲突"

  make_skill "$LIBRARY/skills/ai-product-teardown" "ai-product-teardown"
  make_skill "$LIBRARY/skills/lark-doc" "lark-doc"
  make_skill "$LIBRARY/skills/warehouse-only" "warehouse-only"
  make_skill "$LIBRARY/skills/conflict-skill" "conflict-skill"
}

run_skillctl() {
  /bin/bash "$SKILLCTL" "$@" >/dev/null 2>&1
}

run_build_capture() {
  if BUILD_OUTPUT="$(/bin/bash "$BUILD" "$@" 2>&1)"; then
    BUILD_STATUS=0
  else
    BUILD_STATUS=$?
  fi
}

test_dashboard_dry_run_creates_nothing() {
  make_fixture
  local before after
  before="$(find "$TEST_ROOT" -print | LC_ALL=C sort)"
  run_build_capture
  assert_eq "$BUILD_STATUS" "0" "面板预演成功退出"
  after="$(find "$TEST_ROOT" -print | LC_ALL=C sort)"
  assert_eq "$after" "$before" "面板预演不生成任何文件"
  assert_not_exists "$HTML" "面板预演不创建 index.html"
  cleanup
  TEST_ROOT=""
}

test_dashboard_content_and_escaping() {
  local html
  make_fixture
  run_skillctl activate ai-product-teardown --apply
  run_skillctl activate lark-doc --apply
  mkdir -p "$TEST_HOME/.agents/skills/conflict-skill"

  run_build_capture --apply
  assert_eq "$BUILD_STATUS" "0" "面板生成成功退出"
  assert_exists "$HTML" "面板生成 index.html"
  html="$(cat "$HTML")"

  assert_contains "$html" '<html lang="zh-CN">' "面板声明中文"
  assert_contains "$html" 'AI 产品拆解' "面板显示中文名称"
  assert_contains "$html" 'ai-product-teardown' "面板保留弱化英文 ID"
  assert_contains "$html" '&amp;' "HTML 转义与号"
  assert_contains "$html" '&lt;' "HTML 转义小于号"
  assert_contains "$html" '&gt;' "HTML 转义大于号"
  assert_contains "$html" '&quot;飞书&quot;' "HTML 转义引号"
  assert_contains "$html" '静态快照' "面板明确标注这是静态快照"
  assert_contains "$html" "Skill 文件夹" "面板头部显示 Skill 文件夹地址"
  assert_contains "$html" "$LIBRARY/skills" "文件夹地址是真实绝对路径，随环境自动识别"
  # v2：静态构建和 dashboard serve 共用同一份前端脚本，字符串 "fetch(" 本身
  # 会出现在文件里（写请求那几个函数体内），但这些函数体最前面都是
  # "if (!LIVE) return;"，LIVE 只在 dashboard-server.py 注入的
  # window.__DASHBOARD_LIVE__ 存在时才为真——静态构建的 build-dashboard.sh
  # 只读那个变量、从不写它，所以真正该断言的不变量是"这次生成的 HTML 里没
  # 有那个赋值语句"，而不是"整份脚本里不出现 fetch( 这个词"。
  assert_not_contains "$html" '__DASHBOARD_LIVE__ =' "静态快照不注入 LIVE 标记，写请求代码路径不可达"
  assert_contains "$html" '常驻模式' "面板提供常驻模式点选入口"
  assert_contains "$html" '移入仓库模式' "面板提供移入仓库模式点选入口"
  assert_contains "$html" '删除模式' "面板提供删除模式点选入口"

  assert_contains "$html" '仅在仓库' "面板显示未激活 Skill"
  assert_contains "$html" 'chip-warehouse' "未激活 Skill 标记为仓库中状态"
  assert_contains "$html" 'chip-active' "已激活 Skill 有对应状态样式"
  assert_contains "$html" 'chip-conflict' "真实目录冲突有对应状态样式"

  # 真实包的 config/profiles/core 里登记了 commit-message-writer /
  # code-review-checklist，但这个夹具的 catalog 里没有这两个 id（PROFILE_DIR
  # 硬编码指向真实包配置，测试没法伪造独立场景包文件）——这正好是"场景包
  # 里的成员被归档/移除了，但场景包文件没跟着更新"的真实场景：仓库里查不到
  # 的成员直接不显示，数量也要跟着只数实际显示了几个（这里是 0，不是文件
  # 行数 2），并且有一句空态提示，不能显示成一个看着像 bug 的空单元格。
  local profiles_section
  profiles_section="$(awk '/id="profiles-section"/,/<\/section>/' "$HTML")"
  assert_not_contains "$profiles_section" "commit-message-writer" "catalog 里没有的场景包成员直接不显示"
  assert_contains "$profiles_section" '<td>0</td>' "数量只数实际能在仓库里找到的成员，不是场景包文件的行数"
  assert_contains "$profiles_section" "场景包文件里的成员都不在仓库中" "全部成员都缺失时给出空态提示"

  # 夹具里 4 个 Skill，ai-product-teardown 和 lark-doc 两个被 activate 了，
  # 顶部统计磁贴的"已激活"数量应该正好是 2，不多不少。
  local active_stat
  active_stat="$(printf '%s' "$html" | grep -o 'stat-active"><span class="stat-value">[0-9]*' | grep -o '[0-9]*$')"
  assert_eq "$active_stat" "2" "统计磁贴已激活数量与真实激活的 Skill 数一致"

  local adapter_id
  for adapter_id in codex cursor gemini-cli claude-code kiro trae codebuddy qoder; do
    assert_contains "$html" "$adapter_id" "面板显示适配器 $adapter_id"
  done
  assert_contains "$html" 'skillctl tools connect claude-code --apply' "面板展示可复制的连接命令"
  cleanup
  TEST_ROOT=""
}

test_dashboard_generation_failure_preserves_previous_html() {
  local before_hash after_hash catalog_backup
  make_fixture
  run_build_capture --apply
  assert_eq "$BUILD_STATUS" "0" "首次生成成功退出"
  before_hash="$(shasum -a 256 "$HTML" | awk '{print $1}')"

  catalog_backup="$TEST_ROOT/catalog.tsv.bak"
  mv "$LIBRARY/catalog.tsv" "$catalog_backup"

  run_build_capture --apply
  assert_eq "$BUILD_STATUS" "1" "目录缺失时生成失败"
  after_hash="$(shasum -a 256 "$HTML" | awk '{print $1}')"
  assert_eq "$after_hash" "$before_hash" "生成失败保留旧面板"

  mv "$catalog_backup" "$LIBRARY/catalog.tsv"
  cleanup
  TEST_ROOT=""
}

test_dashboard_read_only_and_atomic() {
  local skill_hash_before skill_hash_after
  make_fixture
  run_skillctl activate lark-doc --apply
  skill_hash_before="$(shasum -a 256 "$LIBRARY/skills/lark-doc/SKILL.md" | awk '{print $1}')"

  run_build_capture --apply
  assert_eq "$BUILD_STATUS" "0" "面板生成成功退出"
  skill_hash_after="$(shasum -a 256 "$LIBRARY/skills/lark-doc/SKILL.md" | awk '{print $1}')"
  assert_eq "$skill_hash_after" "$skill_hash_before" "面板生成不改动 Skill 文件"

  if [ -L "$HTML" ]; then
    not_ok "面板输出不是软链"
  else
    ok "面板输出不是软链"
  fi
  cleanup
  TEST_ROOT=""
}

test_skillctl_dashboard_subcommands() {
  make_fixture
  run_skillctl activate lark-doc --apply

  if /bin/bash "$SKILLCTL" dashboard build --apply >/dev/null 2>&1; then
    ok "skillctl dashboard build 成功退出"
  else
    not_ok "skillctl dashboard build 成功退出"
  fi
  assert_exists "$HTML" "skillctl dashboard build 生成面板"

  # Shadow the real macOS `open` with a fake recorder so the test never
  # pops an actual browser window as a side effect.
  local bin_dir marker status
  bin_dir="$TEST_ROOT/bin"
  marker="$TEST_ROOT/open-marker.txt"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/open" <<SH
#!/bin/sh
printf '%s\n' "\$1" > "$marker"
exit 0
SH
  chmod +x "$bin_dir/open"

  if PATH="$bin_dir:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$SKILLCTL" dashboard open >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  assert_eq "$status" "0" "面板存在时 open 成功退出"
  assert_eq "$(cat "$marker" 2>/dev/null || true)" "$HTML" "open 调用传入正确的面板路径"
  cleanup
  TEST_ROOT=""
}

test_skillctl_dashboard_open_requires_existing_html() {
  make_fixture
  local output status
  if output="$(/bin/bash "$SKILLCTL" dashboard open 2>&1)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$status" "1" "面板不存在时 open 失败"
  assert_contains "$output" "尚未生成" "open 提示需要先生成面板"
  cleanup
  TEST_ROOT=""
}

assert_exists "$BUILD" "build-dashboard.sh 入口存在"
if [ -f "$BUILD" ] && [ -f "$SKILLCTL" ]; then
  test_dashboard_dry_run_creates_nothing
  test_dashboard_content_and_escaping
  test_dashboard_generation_failure_preserves_previous_html
  test_dashboard_read_only_and_atomic
  test_skillctl_dashboard_subcommands
  test_skillctl_dashboard_open_requires_existing_html
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
