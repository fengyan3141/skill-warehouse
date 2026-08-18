#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PACKAGE="$ROOT"

# This test catches missing or malformed package configuration that would make
# downstream skill selection ambiguous. As of the open-source packaging pass,
# the shipped config/ only carries the two example Skills under examples/
# (commit-message-writer, code-review-checklist) plus the core profile —
# personal scene packages (aipm/frameflow/stock/lark) were stripped.
. "$SCRIPT_DIR/skill_test_helpers.sh"

assert_exists "$PACKAGE/config/aliases.tsv" "中文别名配置存在"
assert_exists "$PACKAGE/config/adapters/tools.tsv" "软件适配器配置存在"
assert_exists "$PACKAGE/config/profiles/core" "场景包 core 存在"
assert_not_exists "$PACKAGE/config/profiles/aipm" "个人场景包 aipm 已剥离"
assert_not_exists "$PACKAGE/config/profiles/frameflow" "个人场景包 frameflow 已剥离"
assert_not_exists "$PACKAGE/config/profiles/stock" "个人场景包 stock 已剥离"
assert_not_exists "$PACKAGE/config/profiles/lark" "个人场景包 lark 已剥离"

if [ -f "$PACKAGE/config/aliases.tsv" ]; then
  assert_eq "$(awk -F '\t' 'NF && $1 !~ /^#/ && NF != 6 {bad++} END {print bad+0}' "$PACKAGE/config/aliases.tsv")" 0 "aliases.tsv 固定为六列"
else
  not_ok "aliases.tsv 固定为六列"
fi

if [ -f "$PACKAGE/config/adapters/tools.tsv" ]; then
  assert_eq "$(awk -F '\t' 'NF && $1 !~ /^#/ && NF != 8 {bad++} END {print bad+0}' "$PACKAGE/config/adapters/tools.tsv")" 0 "tools.tsv 固定为八列"
else
  not_ok "tools.tsv 固定为八列"
fi

new_home

inventory_file=""
for candidate in "$PACKAGE"/config/inventory-*.txt; do
  [ -f "$candidate" ] || continue
  inventory_file="$candidate"
  break
done

if [ -n "$inventory_file" ] && [ -f "$PACKAGE/config/aliases.tsv" ]; then
  sed '/^#/d;/^[[:space:]]*$/d' "$inventory_file" | sort -u > "$TEST_HOME/inventory.sorted"
  awk -F '\t' '$1 !~ /^#/ {print $1}' "$PACKAGE/config/aliases.tsv" | sort -u > "$TEST_HOME/aliases.sorted"
  missing="$(comm -23 "$TEST_HOME/inventory.sorted" "$TEST_HOME/aliases.sorted")"
  assert_eq "$missing" "" "每个有效库存 Skill 都有中文别名记录"
else
  not_ok "每个有效库存 Skill 都有中文别名记录"
fi

if [ -f "$PACKAGE/config/profiles/core" ] && [ -f "$PACKAGE/config/aliases.tsv" ]; then
  sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$PACKAGE/config/profiles/core" | sort -u > "$TEST_HOME/core.sorted"
  missing="$(comm -23 "$TEST_HOME/core.sorted" "$TEST_HOME/aliases.sorted")"
  assert_eq "$missing" "" "场景包 core 只包含有效 ID"
else
  not_ok "场景包 core 只包含有效 ID"
fi

if [ -f "$PACKAGE/config/profiles/core" ]; then
  printf '%s\n' 'commit-message-writer
code-review-checklist' | sort -u > "$TEST_HOME/core.expected"
  sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$PACKAGE/config/profiles/core" | sort -u > "$TEST_HOME/core.actual"
  assert_eq "$(cat "$TEST_HOME/core.actual")" "$(cat "$TEST_HOME/core.expected")" "场景包 core 精确 ID 列表"
else
  not_ok "场景包 core 精确 ID 列表"
fi

if [ -f "$PACKAGE/config/adapters/tools.tsv" ]; then
  adapters="$(awk -F '\t' '$1 !~ /^#/ {print $1}' "$PACKAGE/config/adapters/tools.tsv" | sort)"
  expected_adapters="$(printf '%s\n' claude-code codebuddy codex cursor gemini-cli kiro qoder trae trae-cn windsurf)"
  assert_eq "$adapters" "$expected_adapters" "软件适配器固定为十个批准工具"
  assert_eq "$(awk -F '\t' '$3 == "native" && $4 != "~/.agents/skills" {bad++} END {print bad+0}' "$PACKAGE/config/adapters/tools.tsv")" 0 "原生适配器使用共享全局目录"
else
  not_ok "软件适配器固定为十个批准工具"
  not_ok "原生适配器使用共享全局目录"
fi

cleanup_home

assert_exists "$PACKAGE/examples/commit-message-writer/SKILL.md" "示例 Skill commit-message-writer 存在"
assert_exists "$PACKAGE/examples/code-review-checklist/SKILL.md" "示例 Skill code-review-checklist 存在"
assert_exists "$PACKAGE/LICENSE" "LICENSE 存在"
assert_exists "$PACKAGE/ROADMAP.md" "ROADMAP.md 存在"

if [ -f "$PACKAGE/README.md" ]; then
  readme="$(cat "$PACKAGE/README.md")"
  assert_contains "$readme" "仓库" "README 说明仓库（唯一真源）"
  assert_contains "$readme" "货架" "README 说明货架/受管软链"
  assert_contains "$readme" "install-manager.sh" "README 说明管理组件安装"
  assert_contains "$readme" "skillctl route" "README 给出中文场景的命令示例"
  assert_contains "$readme" "1200" "README 说明路由输出字符上限"
  assert_contains "$readme" "90%" "README 说明 Top1 准确率门槛"
  assert_contains "$readme" "98%" "README 说明 Top3 准确率门槛"
  assert_contains "$readme" "skillctl import" "README 说明导入命令"
  assert_contains "$readme" "skillctl import-github" "README 说明 GitHub 导入命令"
  assert_contains "$readme" "skillctl check-updates" "README 说明检查更新命令"
  assert_contains "$readme" "claude-code" "README 提及适配器"
  assert_contains "$readme" "codebuddy" "README 提及适配器"
  assert_contains "$readme" "qoder" "README 提及适配器"
  assert_contains "$readme" "tools detect" "README 说明新软件检测"
  assert_contains "$readme" "本地服务" "README 说明本地服务模式"
  assert_contains "$readme" "dashboard build" "README 给出面板生成命令"
  assert_contains "$readme" "dashboard serve" "README 给出本地服务启动命令"
  assert_contains "$readme" "完整备份" "README 说明迁移前完整备份"
  assert_contains "$readme" "macOS" "README 声明 macOS only"
  assert_contains "$readme" "skillctl doctor" "README 说明健康检查命令"
  assert_contains "$readme" "skillctl lint" "README 说明内容质量检查命令"
  assert_contains "$readme" "skillctl eject" "README 说明退出机制"
  assert_not_contains "$readme" "OpenClaw" "README 不提及已卸载的 OpenClaw"
  assert_not_contains "$readme" "真实迁移尚未执行" "README 不残留内部进度日志措辞"
else
  not_ok "README.md 存在"
fi

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
