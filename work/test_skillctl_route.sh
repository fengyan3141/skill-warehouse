#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKILLCTL="$ROOT/skillctl"
. "$SCRIPT_DIR/skill_test_helpers.sh"
. "$SCRIPT_DIR/test_env_common.sh"

TEST_ROOT=""
SNAPSHOT_BEFORE=""
SNAPSHOT_AFTER=""
ENV_HOME=""

cleanup() {
  [ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
  [ -n "$SNAPSHOT_BEFORE" ] && rm -f "$SNAPSHOT_BEFORE"
  [ -n "$SNAPSHOT_AFTER" ] && rm -f "$SNAPSHOT_AFTER"
  [ -n "$ENV_HOME" ] && rm -rf "$ENV_HOME"
}
trap cleanup EXIT HUP INT TERM

snapshot_tree() {
  find "$1" -print | sort | while IFS= read -r path; do
    if [ -L "$path" ]; then
      printf 'link\t%s\t%s\n' "$path" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'file\t%s\t%s\n' "$path" "$(shasum -a 256 "$path" | awk '{print $1}')"
    elif [ -d "$path" ]; then
      printf 'dir\t%s\n' "$path"
    fi
  done
}

write_catalog() {
  local long_description
  printf '%s\n' \
    $'ai-product-teardown\tskills/ai-product-teardown\tAI 产品拆解\t产品拆解,竞品拆解,逆向分析,反向工程\tproduct\t产品,拆解,竞品,架构\t简单评价,一句话评价\t系统拆解 AI 产品' \
    $'ai-pm-resume-writer\tskills/ai-pm-resume-writer\tAI 产品经理简历\t简历优化,岗位简历,改简历\tcareer\t简历,JD,求职,项目经历\t普通写作\t优化 AI 产品经理简历' \
    $'lark-approval\tskills/lark-approval\t飞书审批\t审批待办,发起审批\tlark\t飞书,审批,待办\t文档编辑\t处理飞书审批' \
    $'lark-doc\tskills/lark-doc\t飞书文档\t云文档,文档编辑,读取飞书文档\tlark\t飞书文档,docx,wiki\t表格,多维表格,云盘\t读取和编辑飞书文档' \
    $'lark-sheets\tskills/lark-sheets\t飞书电子表格\t电子表格,飞书表格,单元格\tlark\t飞书表格,单元格,公式\t多维表格\t修改飞书表格公式' \
    $'skill-router\tskills/skill-router\t技能调度器\t技能路由,查找技能,选择技能\tsystem\t技能,路由,调度\t\t本地选择技能' > "$1/catalog.tsv"
  long_description="$(awk 'BEGIN { for (i = 0; i < 1300; i++) printf "长" }')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'long-skill' 'skills/long-skill' '超长输出' '超长别名' 'product' '超长任务' '' "$long_description" >> "$1/catalog.tsv"
}

make_fixture() {
  local skill description_1199 description_1200 description_1201
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-route-test.XXXXXX")"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  FIXTURE_LIBRARY="$TEST_ROOT/library"
  FIXTURE_HOME="$TEST_ROOT/home"
  mkdir -p "$FIXTURE_LIBRARY/skills" "$FIXTURE_LIBRARY/archive" "$FIXTURE_HOME/.agents/skills" "$FIXTURE_HOME/foreign"

  for skill in ai-product-teardown ai-pm-resume-writer lark-approval lark-doc lark-sheets skill-router long-skill; do
    mkdir -p "$FIXTURE_LIBRARY/skills/$skill"
  done
  mkdir -p "$FIXTURE_LIBRARY/archive/missing-skill-20260814"
  write_catalog "$FIXTURE_LIBRARY"
  ln -s ../../../library/skills/ai-product-teardown "$FIXTURE_HOME/.agents/skills/ai-product-teardown"
  mkdir -p "$FIXTURE_HOME/.agents/skills/lark-doc"
  ln -s "$FIXTURE_HOME/foreign" "$FIXTURE_HOME/.agents/skills/lark-sheets"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'missing-skill' 'skills/missing-skill' '缺失技能' '旧技能' 'product' '旧技能' '' '已归档的旧技能' >> "$FIXTURE_LIBRARY/catalog.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'gone-skill' 'skills/gone-skill' '不存在技能' '遗失技能' 'product' '遗失技能' '' '不存在于仓库' >> "$FIXTURE_LIBRARY/catalog.tsv"
  description_1199="$(awk 'BEGIN { for (i = 0; i < 1180; i++) printf "a" }')"
  description_1200="$(awk 'BEGIN { for (i = 0; i < 1181; i++) printf "a" }')"
  description_1201="$(awk 'BEGIN { for (i = 0; i < 1182; i++) printf "a" }')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'budget-1199' 'skills/budget-1199' 'D' '预算1199' 'product' '预算1199' '' "$description_1199" >> "$FIXTURE_LIBRARY/catalog.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'budget-1200' 'skills/budget-1200' 'D' '预算1200' 'product' '预算1200' '' "$description_1200" >> "$FIXTURE_LIBRARY/catalog.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'budget-1201' 'skills/budget-1201' 'D' '预算1201' 'product' '预算1201' '' "$description_1201" >> "$FIXTURE_LIBRARY/catalog.tsv"
}

test_read_only_chinese_listing_search_and_route() {
  local library home output output_many expected count chars before after status_output archive_status
  local output_1199 output_1200 output_1201
  make_fixture
  library="$FIXTURE_LIBRARY"
  home="$FIXTURE_HOME"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" list)"
  assert_contains "$output" $'AI 产品拆解\tai-product-teardown' "列表以中文名称优先"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" search '竞品拆解')"
  assert_contains "$output" $'AI 产品拆解\tai-product-teardown' "中文别名可搜索"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" search 'LARK-SHEETS')"
  assert_contains "$output" $'飞书电子表格\tlark-sheets' "英文 ID 搜索忽略 ASCII 大小写"

  SNAPSHOT_BEFORE="$(mktemp "${TMPDIR:-/tmp}/skillctl-before.XXXXXX")"
  SNAPSHOT_AFTER="$(mktemp "${TMPDIR:-/tmp}/skillctl-after.XXXXXX")"
  { snapshot_tree "$library"; snapshot_tree "$home"; } > "$SNAPSHOT_BEFORE"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '帮我拆一下这个 AI 产品')"
  assert_eq "$(printf '%s\n' "$output" | head -1 | cut -f2)" "ai-product-teardown" "中文自然语言命中产品拆解"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '帮我修改飞书表格里的公式')"
  assert_eq "$(printf '%s\n' "$output" | head -1 | cut -f2)" "lark-sheets" "排除边界避免误选飞书文档"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '你好，今天天气怎么样')"
  assert_eq "$output" "" "普通请求不强行匹配 Skill"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route ' AI-PRODUCT-TEARDOWN ')"
  assert_eq "$(printf '%s\n' "$output" | cut -f1)" "100" "精确英文 ID 得分为一百分"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '竞品拆解')"
  assert_eq "$(printf '%s\n' "$output" | cut -f1)" "95" "精确中文别名得分为九十五分"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '我想做反向工程')"
  assert_eq "$(printf '%s\n' "$output" | cut -f1)" "60" "包含中文别名得分为六十分"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '帮我找技能路由')"
  assert_eq "$output" "" "system 类不按触发词参与路由"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '查找技能')"
  assert_eq "$(printf '%s\n' "$output" | cut -f2)" "skill-router" "system 类允许精确别名匹配"

  output_many="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '飞书 表格 简历 产品')"
  count="$(printf '%s\n' "$output_many" | awk 'NF {n++} END {print n+0}')"
  assert_eq "$count" "3" "路由最多返回三个候选"
  chars="$(printf '%s' "$output_many" | wc -m | tr -d ' ')"
  [ "$chars" -le 1200 ] && ok "路由输出不超过 1200 字符" || not_ok "路由输出不超过 1200 字符"

  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '超长任务')"
  assert_eq "$output" "" "单条候选超过上限时不截断输出"

  output_1199="$TEST_ROOT/route-1199.out"
  output_1200="$TEST_ROOT/route-1200.out"
  output_1201="$TEST_ROOT/route-1201.out"
  HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route 'budget-1199' > "$output_1199"
  chars="$(LC_ALL=C wc -m < "$output_1199" | tr -d ' ')"
  assert_eq "$chars" "1199" "路由 stdout 可精确达到 1199 字符"
  HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route 'budget-1200' > "$output_1200"
  chars="$(LC_ALL=C wc -m < "$output_1200" | tr -d ' ')"
  assert_eq "$chars" "1200" "路由 stdout 可精确达到 1200 字符"
  HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route 'budget-1201' > "$output_1201"
  chars="$(LC_ALL=C wc -m < "$output_1201" | tr -d ' ')"
  [ "$chars" -le 1200 ] && ok "路由不会产生 1201 字符的 stdout" || not_ok "路由不会产生 1201 字符的 stdout"

  expected="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" route '帮我拆一下这个 AI 产品')"
  output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" https_proxy='http://127.0.0.1:1' http_proxy='http://127.0.0.1:1' /bin/bash "$SKILLCTL" route '帮我拆一下这个 AI 产品')"
  assert_eq "$output" "$expected" "无效网络代理不影响本地路由"

  status_output="$(HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" status)"
  assert_contains "$status_output" $'全局\t已激活\t' "状态显示受管软链已激活"
  assert_contains "$status_output" $'全局\t仓库中\t' "状态显示仓库中的技能"
  assert_contains "$status_output" $'全局\t已归档\t' "状态显示归档技能"
  assert_contains "$status_output" $'全局\t缺失\t' "状态显示缺失技能"
  assert_contains "$status_output" $'全局\t真实目录冲突\t' "状态显示真实目录冲突"
  assert_contains "$status_output" $'全局\t外部软链冲突\t' "状态显示外部软链冲突"

  mkdir -p "$TEST_ROOT/no-maxdepth-bin"
  printf '%s\n' \
    '#!/bin/bash' \
    'for argument in "$@"; do' \
    '  [ "$argument" != "-maxdepth" ] || exit 64' \
    'done' \
    'exec /usr/bin/find "$@"' > "$TEST_ROOT/no-maxdepth-bin/find"
  chmod +x "$TEST_ROOT/no-maxdepth-bin/find"
  archive_status="$(PATH="$TEST_ROOT/no-maxdepth-bin:$PATH" HOME="$home" SKILL_LIBRARY_ROOT="$library" /bin/bash "$SKILLCTL" status)"
  assert_contains "$archive_status" $'全局\t已归档\t缺失技能\tmissing-skill' "不依赖 -maxdepth 也能识别带后缀的归档目录"

  { snapshot_tree "$library"; snapshot_tree "$home"; } > "$SNAPSHOT_AFTER"
  before="$(<"$SNAPSHOT_BEFORE")"
  after="$(<"$SNAPSHOT_AFTER")"
  assert_eq "$after" "$before" "路由和查询不改动夹具目录"
}

assert_exists "$SKILLCTL" "skillctl 入口存在"

# 这个套件里每条调用都显式传 HOME="$home" SKILL_LIBRARY_ROOT="$library"——
# make_fixture 手搭的 FIXTURE_HOME/FIXTURE_LIBRARY 之间还有依赖精确层级的
# 相对软链（../../../），不改这部分调用点、保持现状最安全。这里仍先跑一次
# 公共初始化，把这条测试目前用不到的 SKILL_ADAPTERS/SKILL_ALIASES/
# SKILL_APPLICATIONS_DIR/SKILL_PACKAGE_ROOT 也兜底指到沙箱里。
# 但 SKILLS_ACTIVE/SKILL_GLOBAL_DIR 必须 unset：这两个变量优先级比 HOME 高，
# 一旦固定 export 成 ENV_HOME 下的路径，就不会跟着每条调用各自的
# HOME="$home" 一起变，会让 status 读到错误的货架目录（已经在这里踩过一次）。
ENV_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skillctl-route-env.XXXXXX")"
skill_test_env_init "$ENV_HOME"
unset SKILLS_ACTIVE SKILL_GLOBAL_DIR

if [ -f "$SKILLCTL" ]; then
  test_read_only_chinese_listing_search_and_route
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
