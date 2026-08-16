#!/bin/bash
# 所有测试套件的公共环境隔离前置。统一把每一个会读写真实环境的 SKILL_* /
# SKILLS_* 变量都指向同一个测试自己的假 HOME 目录，一次性 export 到当前测试
# 进程的环境里；调用方后续 shell 出 skillctl / build-*.sh / migrate-skills.sh
# 等脚本时不用在每一行调用前手动重复列一遍 var=value 前缀——正因为过去是
# "每条调用自己拼一遍要传哪些变量"，才会出现某条调用漏拼了一个变量、悄悄
# 落回真实默认值（$HOME/.skill-library、$HOME/.agents/skills、真实
# /Applications、包自带的 config/aliases.tsv 等）的风险。
#
# 用法：
#   . "$SCRIPT_DIR/test_env_common.sh"
#   TEST_HOME="$TEST_ROOT/home"
#   mkdir -p "$TEST_HOME"
#   skill_test_env_init "$TEST_HOME"
#   # 之后直接 /bin/bash "$SKILLCTL" ...，不用再拼 HOME=... SKILL_xxx=...
#
# 覆盖范围（读代码确认过的、会指向真实环境的变量，逐一列出，任何一个漏设
# 都可能碰到真实文件——这正是本文件存在的意义）：
#   HOME                    影响 $HOME/.skill-library、$HOME/.agents/skills 等一切 $HOME/ 派生默认值
#   SKILL_LIBRARY_ROOT      skillctl 仓库根目录，默认 $HOME/.skill-library
#   SKILLS_ACTIVE           skillctl 里优先级最高的"当前激活货架"目录覆盖
#   SKILL_GLOBAL_DIR        SKILLS_ACTIVE 未设时的次级覆盖，默认 $HOME/.agents/skills
#   SKILL_PROJECT_DIR       项目级货架目录，默认是运行时 $(pwd -P)/.agents/skills（不是 $HOME 派生，最容易漏）
#   SKILL_APPLICATIONS_DIR  软件检测扫描目录，默认硬编码真实 /Applications（同样不是 $HOME 派生）
#   SKILL_ALIASES           中文别名目录文件，默认落在包自带的 config/aliases.tsv（真实仓库文件，可能被测试写坏）
#   SKILL_ADAPTERS          软件适配器清单，默认落在包自带的 config/adapters/tools.tsv
#   SKILL_ROUTE_EVALS       路由验收样例文件，默认落在包自带的 config/route-evals.tsv
#   SKILL_PACKAGE_ROOT      install-manager.sh 的安装源，默认是脚本自己所在目录（真实源码树）
#   SKILLS_BACKUP           migrate-skills.sh 的备份目录覆盖
set -uo pipefail

skill_test_env_init() {
  local home="$1"
  [ -n "$home" ] || { printf 'skill_test_env_init: 必须传入 TEST_HOME 路径\n' >&2; return 1; }
  mkdir -p \
    "$home/.agents/skills" \
    "$home/.claude/skills" \
    "$home/.codex/skills" \
    "$home/.project-agents-skills" \
    "$home/Applications" \
    "$home/config" \
    "$home/package-root" \
    "$home/.skills-backup"

  export HOME="$home"
  export SKILL_LIBRARY_ROOT="$home/.skill-library"
  export SKILLS_ACTIVE="$home/.agents/skills"
  export SKILL_GLOBAL_DIR="$home/.agents/skills"
  export SKILL_PROJECT_DIR="$home/.project-agents-skills"
  export SKILL_APPLICATIONS_DIR="$home/Applications"
  export SKILL_ALIASES="$home/config/aliases.tsv"
  export SKILL_ADAPTERS="$home/config/adapters.tsv"
  export SKILL_ROUTE_EVALS="$home/config/route-evals.tsv"
  export SKILL_PACKAGE_ROOT="$home/package-root"
  export SKILLS_BACKUP="$home/.skills-backup"

  [ -f "$SKILL_ALIASES" ] || printf '%s\n' '# id	display_zh	aliases_zh	category	triggers	excludes' > "$SKILL_ALIASES"
  [ -f "$SKILL_ADAPTERS" ] || : > "$SKILL_ADAPTERS"
  [ -f "$SKILL_ROUTE_EVALS" ] || : > "$SKILL_ROUTE_EVALS"
}

# 哨兵检查：对一批真实目录做递归快照，返回一个可比较的字符串。测试隔离回归
# 套件（test_env_isolation.sh）用它验证"调用点不重复列变量、只靠 skill_test_env_init
# 已经 export 好的环境跑命令时，也不会碰真实文件"。
# 用法：skill_test_env_snapshot_real_dirs <真实 HOME 目录> <真实 package 目录>
skill_test_env_snapshot_real_dirs() {
  local real_home="$1" real_package_root="$2" dir
  for dir in "$real_home/.skill-library" "$real_home/.agents/skills" /Applications \
    "$real_package_root/config"; do
    [ -e "$dir" ] || continue
    find "$dir" -maxdepth 3 -print 2>/dev/null
  done | LC_ALL=C sort
}
