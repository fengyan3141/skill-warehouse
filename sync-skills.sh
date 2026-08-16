#!/bin/bash
# Safely distribute the active Skill shelf to link-mode tool adapters.
# Default mode is a read-only preview.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# Dev package layout has lib/ and config/ as siblings of this script; the
# installed layout (Task 10) puts this script in bin/ with lib/ and config/
# one level up as siblings of bin/. Detect which one we're in.
if [ -d "$SCRIPT_DIR/lib" ] && [ -d "$SCRIPT_DIR/config" ]; then
  PACKAGE_ROOT="$SCRIPT_DIR"
else
  PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
fi
SRC="${SKILLS_SRC:-$HOME/.agents/skills}"
IGNORE_FILE="${SKILLS_IGNORE:-$HOME/.agents/.skillignore}"
ADAPTERS_FILE="${SKILL_ADAPTERS:-$PACKAGE_ROOT/config/adapters/tools.tsv}"

APPLY=0
PRUNE=0
DISCONNECT=0
EXPLICIT_TARGETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --prune) PRUNE=1; shift ;;
    --disconnect) DISCONNECT=1; shift ;;
    --target)
      [ "$#" -ge 2 ] || { printf '缺少 --target 参数值\n' >&2; exit 2; }
      EXPLICIT_TARGETS+=("$2")
      shift 2
      ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
done

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'

run() {
  if [ "$APPLY" -eq 1 ]; then
    "$@"
  else
    printf '%s    [dry-run]' "$D"
    printf ' %q' "$@"
    printf '%s\n' "$N"
  fi
}

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

[ -d "$SRC" ] || { printf '%s源目录不存在: %s%s\n' "$R" "$SRC" "$N"; exit 1; }

TARGETS=()
HAS_EXPLICIT_TARGETS=0
if [ "${#EXPLICIT_TARGETS[@]}" -gt 0 ]; then
  TARGETS=("${EXPLICIT_TARGETS[@]}")
  HAS_EXPLICIT_TARGETS=1
else
  [ -f "$ADAPTERS_FILE" ] || { printf '%s软件适配器配置不存在: %s%s\n' "$R" "$ADAPTERS_FILE" "$N" >&2; exit 1; }
  while IFS="$(printf '\t')" read -r a_id _a_display a_mode a_global _a_project _a_cli _a_app _a_verify; do
    [ -n "$a_id" ] || continue
    case "$a_id" in \#*) continue ;; esac
    [ "$a_mode" = "link" ] || continue
    # 不依赖 shell 的 tilde 展开（那对带引号的字符串本来就不生效）——这里是
    # 显式用参数展开去掉字面 ~ 前缀，再手动拼上 $HOME，是故意的写法。
    # shellcheck disable=SC2088
    case "$a_global" in
      "~"|"~/"*) TARGETS+=("$HOME${a_global#\~}") ;;
      *) TARGETS+=("$a_global") ;;
    esac
  done < "$ADAPTERS_FILE"
fi

relpath() {
  local to="$1" from="$2" up=""
  while [ "${to#"$from"/}" = "$to" ] && [ "$from" != "/" ]; do
    from="$(dirname "$from")"
    up="../$up"
  done
  if [ "$from" = "/" ]; then
    printf '%s' "$to"
  else
    printf '%s' "${up}${to#"$from"/}"
  fi
}

IGN_GLOBAL="|"
IGN_PAIRS=()
if [ -f "$IGNORE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "${line%%#*}")"
    [ -z "$line" ] && continue
    case "$line" in
      *@*) IGN_PAIRS+=("$line") ;;
      *) IGN_GLOBAL="${IGN_GLOBAL}${line}|" ;;
    esac
  done < "$IGNORE_FILE"
fi

is_ignored() {
  local skill="$1" target="$2" suffix pair pair_skill pair_target
  case "$IGN_GLOBAL" in *"|$skill|"*) return 0 ;; esac
  suffix="${target#"$HOME"/}"
  for pair in ${IGN_PAIRS[@]+"${IGN_PAIRS[@]}"}; do
    pair_skill="$(trim "${pair%%@*}")"
    pair_target="$(trim "${pair##*@}")"
    if [ "$pair_skill" = "$skill" ] && [ "$pair_target" = "$suffix" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$DISCONNECT" -eq 1 ]; then
  printf '源: %s\n' "$SRC"
  if [ "$APPLY" -ne 1 ]; then
    printf '%s== 预演模式，不会改任何东西 ==%s\n' "$Y" "$N"
  fi
  printf '\n'
  for target in "${TARGETS[@]}"; do
    printf '── %s\n' "$target"
    if [ -L "$target" ]; then
      printf '%s   目标 skills 目录本身是软链，为避免相对路径指错，跳过%s\n\n' "$R" "$N"
      continue
    fi
    if [ ! -d "$target" ]; then
      printf '%s   目录不存在，跳过%s\n\n' "$D" "$N"
      continue
    fi
    relative="$(relpath "$SRC" "$target")"
    n_disconnected=0
    for link in "$target"/*; do
      [ -L "$link" ] || continue
      name="$(basename "$link")"
      wanted="$relative/$name"
      if [ "$(readlink "$link")" = "$wanted" ]; then
        printf '   %s断开%s %s\n' "$Y" "$N" "$name"
        run rm -f "$link"
        n_disconnected=$((n_disconnected + 1))
      fi
    done
    printf '   断开 %s\n\n' "$n_disconnected"
  done
  printf '%s完成。%s\n' "$G" "$N"
  if [ "$APPLY" -ne 1 ]; then
    printf '这是预演。确认后再运行：%s --disconnect --apply\n' "$0"
  fi
  exit 0
fi

SKILLS=()
for item in "$SRC"/*; do
  [ -e "$item" ] || continue
  name="$(basename "$item")"
  case "$name" in .*) continue ;; esac
  if [ -f "$item/SKILL.md" ]; then
    SKILLS+=("$name")
  elif [ -d "$item" ]; then
    printf '%s⚠ 跳过 %s：根目录没有 SKILL.md%s\n' "$Y" "$name" "$N"
    for child in "$item"/*; do
      if [ -f "$child/SKILL.md" ]; then
        printf '%s   （这是合集目录；需要把子 skill 分别放到源目录第一层）%s\n' "$D" "$N"
        break
      fi
    done
  fi
done

printf '源: %s\n' "$SRC"
printf '可分发的 skill: %s 个\n' "${#SKILLS[@]}"
if [ "$APPLY" -ne 1 ]; then
  printf '%s== 预演模式，不会改任何东西 ==%s\n' "$Y" "$N"
fi
printf '\n'

for target in "${TARGETS[@]}"; do
  printf '── %s\n' "$target"
  if [ -L "$target" ]; then
    printf '%s   目标 skills 目录本身是软链，为避免相对路径指错，跳过%s\n\n' "$R" "$N"
    continue
  fi
  if [ ! -d "$target" ]; then
    if [ "$HAS_EXPLICIT_TARGETS" -eq 1 ]; then
      if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$target"
      else
        printf '   %s[dry-run] mkdir -p %s%s\n' "$D" "$target" "$N"
      fi
    else
      printf '%s   目录不存在，跳过%s\n\n' "$D" "$N"
      continue
    fi
  fi

  relative="$(relpath "$SRC" "$target")"
  n_new=0; n_ok=0; n_removed=0; n_skip=0; n_real=0; n_foreign=0; n_pruned=0

  for skill in ${SKILLS[@]+"${SKILLS[@]}"}; do
    link="$target/$skill"
    wanted="$relative/$skill"

    if is_ignored "$skill" "$target"; then
      n_skip=$((n_skip + 1))
      if [ -L "$link" ] && [ "$(readlink "$link")" = "$wanted" ]; then
        printf '   %s移除已被排除的托管软链%s %s\n' "$Y" "$N" "$skill"
        run rm -f "$link"
        n_removed=$((n_removed + 1))
      fi
      continue
    fi

    if [ -L "$link" ]; then
      current="$(readlink "$link")"
      if [ "$current" = "$wanted" ]; then
        n_ok=$((n_ok + 1))
      elif [ -e "$link" ] && [ "$(cd "$link" 2>/dev/null && pwd -P)" = "$(cd "$SRC/$skill" && pwd -P)" ]; then
        n_ok=$((n_ok + 1))
      else
        printf '   %s外部软链冲突%s %s (%s)，不改动\n' "$R" "$N" "$skill" "$current"
        printf '     %s→ 想收编进仓库：%sskillctl import %s --apply\n' "$D" "$N" "$link"
        printf '     %s→ 想保留原样：无需操作，skillctl 不会管理此目录%s\n' "$D" "$N"
        n_foreign=$((n_foreign + 1))
      fi
    elif [ -e "$link" ]; then
      printf '   %s真实目录冲突%s %s，不改动\n' "$R" "$N" "$skill"
      printf '     %s→ 想收编进仓库：%sskillctl import %s --apply\n' "$D" "$N" "$link"
      printf '     %s→ 想保留原样：无需操作，skillctl 不会管理此目录%s\n' "$D" "$N"
      n_real=$((n_real + 1))
    else
      printf '   %s新建%s %s\n' "$G" "$N" "$skill"
      run ln -s "$wanted" "$link"
      n_new=$((n_new + 1))
    fi
  done

  if [ "$PRUNE" -eq 1 ]; then
    for broken in "$target"/*; do
      [ -L "$broken" ] || continue
      [ -e "$broken" ] && continue
      broken_name="$(basename "$broken")"
      managed="$relative/$broken_name"
      if [ "$(readlink "$broken")" = "$managed" ]; then
        printf '   %s清理失效的托管软链%s %s\n' "$Y" "$N" "$broken_name"
        run rm -f "$broken"
        n_pruned=$((n_pruned + 1))
      else
        printf '   %s保留无关的失效软链%s %s -> %s\n' "$D" "$N" "$broken_name" "$(readlink "$broken")"
      fi
    done
  fi

  printf '   新建 %s / 已正确 %s / 排除 %s / 移除排除链接 %s / 清理失效 %s / 真实目录冲突 %s / 外部软链冲突 %s\n\n' \
    "$n_new" "$n_ok" "$n_skip" "$n_removed" "$n_pruned" "$n_real" "$n_foreign"
done

printf '%s完成。%s\n' "$G" "$N"
if [ "$APPLY" -ne 1 ]; then
  printf '这是预演。确认后再运行：%s --apply\n' "$0"
fi
