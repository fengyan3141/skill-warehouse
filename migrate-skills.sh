#!/bin/bash
# Safely consolidate real skill directories into the unscanned warehouse
# ($SKILL_LIBRARY_ROOT/skills), not ~/.agents/skills. Default mode is a
# read-only preview. The default conflict policy is skip.
set -euo pipefail

DEST="${SKILL_LIBRARY_ROOT:-$HOME/.skill-library}/skills"
SOURCES=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
  "$HOME/.codex/skills"
)
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SKILLS_BACKUP:-$HOME/.skills-backup-$STAMP}"

APPLY=0
CONFLICT="skip"
NORMALIZE=1

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --no-normalize) NORMALIZE=0 ;;
    --conflict=*) CONFLICT="${arg#--conflict=}" ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) printf '未知参数: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

case "$CONFLICT" in
  skip|identical|keep-agents|keep-source) ;;
  *)
    printf '%s\n' '--conflict 只能是 skip / identical / keep-agents / keep-source' >&2
    exit 2
    ;;
esac

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'

run() {
  if [ "$APPLY" -eq 1 ]; then
    "$@"
  else
    printf '%s    [dry-run]' "$D"
    printf ' %q' "$@"
    printf '%s\n' "$N"
  fi
}

backup_sources() {
  local src rel target
  mkdir -p "$BACKUP" || { printf '%s备份目录创建失败，已中止（未进行任何迁移操作）：%s%s\n' "$R" "$BACKUP" "$N" >&2; exit 1; }
  for src in "${SOURCES[@]}"; do
    [ -d "$src" ] || continue
    [ -L "$src" ] && continue
    rel="${src#"$HOME"/}"
    target="$BACKUP/$rel"
    mkdir -p "$(dirname "$target")" || { printf '%s备份目录创建失败，已中止（未进行任何迁移操作）：%s%s\n' "$R" "$target" "$N" >&2; exit 1; }
    if ! /usr/bin/ditto "$src" "$target"; then
      printf '%s备份失败，已中止（未进行任何迁移操作）：%s%s\n' "$R" "$src" "$N" >&2
      exit 1
    fi
  done
}

declared_name() {
  awk '
    NR == 1 && $0 == "---" { front = 1; next }
    front && $0 == "---" { exit }
    front && $0 ~ /^name:[[:space:]]*/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^['\''\"]|['\''\"]$/, "")
      print
      exit
    }
  ' "$1/SKILL.md" 2>/dev/null || true
}

strip_version_text() {
  printf '%s' "$1" | sed -E 's/-v?[0-9]+\.[0-9]+(\.[0-9]+)?$//'
}

valid_skill_name() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}

canonical_name() {
  local dir="$1" base declared
  base="$(basename "$dir")"
  if [ "$NORMALIZE" -ne 1 ] || [ ! -f "$dir/SKILL.md" ]; then
    printf '%s' "$base"
    return
  fi
  declared="$(declared_name "$dir")"
  if valid_skill_name "$declared"; then
    printf '%s' "$declared"
  else
    printf '%s' "$base"
  fi
}

backup_path() {
  local stem="$1" candidate index=1
  candidate="$BACKUP/conflicts/$stem"
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate="$BACKUP/conflicts/$stem.$index"
    index=$((index + 1))
  done
  printf '%s' "$candidate"
}

PLANNED_NAMES=()
PLANNED_SOURCES=()
FOUND_TARGET=""
FOUND_PLANNED=0

record_planned_move() {
  PLANNED_NAMES+=("$1")
  PLANNED_SOURCES+=("$2")
}

find_existing_target() {
  local bare="$1" candidate index=0
  FOUND_TARGET=""
  FOUND_PLANNED=0
  if [ -e "$DEST/$bare" ] || [ -L "$DEST/$bare" ]; then
    FOUND_TARGET="$DEST/$bare"
    return
  fi
  for candidate in "$DEST"/*; do
    [ -d "$candidate" ] || continue
    [ -L "$candidate" ] && continue
    [ -f "$candidate/SKILL.md" ] || continue
    if [ "$(canonical_name "$candidate")" = "$bare" ]; then
      FOUND_TARGET="$candidate"
      return
    fi
  done
  while [ "$index" -lt "${#PLANNED_NAMES[@]}" ]; do
    if [ "${PLANNED_NAMES[$index]}" = "$bare" ]; then
      FOUND_TARGET="${PLANNED_SOURCES[$index]}"
      FOUND_PLANNED=1
      return
    fi
    index=$((index + 1))
  done
  FOUND_TARGET="$DEST/$bare"
}

move_source_over_target() {
  local source="$1" target="$2" final="$3" saved
  saved="$(backup_path "$(basename "$target").from-agents")"
  if [ "$APPLY" -ne 1 ]; then
    run mv "$target" "$saved"
    run mv "$source" "$final"
    return
  fi
  mv "$target" "$saved"
  if ! mv "$source" "$final"; then
    printf '%s迁入失败，正在恢复原目标%s\n' "$R" "$N" >&2
    mv "$saved" "$target" || true
    return 1
  fi
}

printf '%s目标（唯一真源）:%s %s\n' "$B" "$N" "$DEST"
printf '%s来源:%s %s\n' "$B" "$N" "${SOURCES[*]}"
printf '%s冲突策略:%s %s\n' "$B" "$N" "$CONFLICT"
printf '%s备份目录:%s %s\n' "$B" "$N" "$BACKUP"
if [ "$APPLY" -ne 1 ]; then
  printf '%s== 预演模式，不会改任何东西 ==%s\n' "$Y" "$N"
fi
printf '\n'

if [ "$APPLY" -eq 1 ]; then
  mkdir -p "$DEST" || { printf '%s仓库目录创建失败: %s%s\n' "$R" "$DEST" "$N" >&2; exit 1; }
  printf '%s【应用前】备份现有来源目录到 %s%s\n' "$B" "$BACKUP" "$N"
  backup_sources
  printf '  %s备份完成%s\n\n' "$G" "$N"
fi

run mkdir -p "$BACKUP/conflicts"

n_ren=0; n_mv=0; n_conf=0; n_same=0; n_skip=0; n_bad=0

printf '%s【第 1 步】安全去掉目录版本后缀%s\n' "$B" "$N"
if [ "$NORMALIZE" -eq 1 ]; then
  for item in "$DEST"/*; do
    [ -d "$item" ] || continue
    [ -L "$item" ] && continue
    [ -f "$item/SKILL.md" ] || continue
    old="$(basename "$item")"
    bare="$(canonical_name "$item")"
    [ "$old" = "$bare" ] && continue
    if [ -e "$DEST/$bare" ] || [ -L "$DEST/$bare" ]; then
      printf '  %s暂缓%s %s → %s（裸名已存在）\n' "$Y" "$N" "$old" "$bare"
      continue
    fi
    printf '  %s改名%s %s → %s\n' "$G" "$N" "$old" "$bare"
    run mv "$item" "$DEST/$bare"
    n_ren=$((n_ren + 1))
  done
else
  printf '%s  （版本后缀归一已关闭）%s\n' "$D" "$N"
fi
printf '\n'

printf '%s【第 2 步】迁入来源目录%s\n' "$B" "$N"
for src in "${SOURCES[@]}"; do
  [ -d "$src" ] || { printf '  %s%s 不存在，跳过%s\n' "$D" "$src" "$N"; continue; }
  printf '  ── %s\n' "$src"
  for item in "$src"/*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    [ -L "$item" ] && continue
    [ -d "$item" ] || continue
    name="$(basename "$item")"
    case "$name" in .*) continue ;; esac
    if [ ! -f "$item/SKILL.md" ]; then
      printf '     %s非 skill%s %s（没有 SKILL.md），不动\n' "$Y" "$N" "$name"
      n_bad=$((n_bad + 1))
      continue
    fi

    declared="$(declared_name "$item")"
    if ! valid_skill_name "$declared"; then
      printf '     %s不兼容的 name%s %s（声明为 “%s”），不自动迁移\n' "$Y" "$N" "$name" "$declared"
      n_bad=$((n_bad + 1))
      continue
    fi

    bare="$(canonical_name "$item")"
    find_existing_target "$bare"
    target="$FOUND_TARGET"
    target_is_planned="$FOUND_PLANNED"
    final="$DEST/$bare"

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      printf '     %s迁入%s %s → %s\n' "$G" "$N" "$name" "$final"
      run mv "$item" "$final"
      if [ "$APPLY" -ne 1 ]; then
        record_planned_move "$bare" "$item"
      fi
      n_mv=$((n_mv + 1))
      continue
    fi

    n_conf=$((n_conf + 1))
    printf '     %s冲突%s %s\n' "$Y" "$N" "$bare"
    printf '        来源: %s\n' "$item"
    printf '        已有: %s\n' "$target"

    case "$CONFLICT" in
      skip)
        printf '        → 两边不同或未核验，保持原样\n'
        n_skip=$((n_skip + 1))
        ;;
      identical)
        if diff -qr "$item" "$target" >/dev/null 2>&1; then
          saved="$(backup_path "$name.identical-from-$(basename "$(dirname "$src")")")"
          printf '        → 全目录内容相同；来源副本移入备份\n'
          run mv "$item" "$saved"
          if [ "$target_is_planned" -ne 1 ] && [ "$NORMALIZE" -eq 1 ] && [ "$(basename "$target")" != "$bare" ] && [ ! -e "$final" ]; then
            run mv "$target" "$final"
          fi
          n_same=$((n_same + 1))
        else
          printf '        → 内容不同，安全跳过，等待人工选择\n'
          n_skip=$((n_skip + 1))
        fi
        ;;
      keep-agents)
        saved="$(backup_path "$name.from-$(basename "$(dirname "$src")")")"
        printf '        → 保留共享库版本；来源移入备份\n'
        run mv "$item" "$saved"
        if [ "$target_is_planned" -ne 1 ] && [ "$NORMALIZE" -eq 1 ] && [ "$(basename "$target")" != "$bare" ] && [ ! -e "$final" ]; then
          run mv "$target" "$final"
        fi
        ;;
      keep-source)
        printf '        → 使用来源版本；共享库版本移入备份\n'
        move_source_over_target "$item" "$target" "$final"
        ;;
    esac
  done
done
printf '\n'

printf '%s【第 3 步】收尾检查%s\n' "$B" "$N"
for item in "$DEST"/*; do
  if [ -L "$item" ]; then
    name="$(basename "$item")"
    if [ ! -e "$item" ]; then
      printf '  %s失效软链%s %s -> %s\n' "$R" "$N" "$name" "$(readlink "$item")"
    elif [ -d "$item" ] && [ ! -f "$item/SKILL.md" ]; then
      printf '  %s软链指向的不是单个 skill%s %s -> %s\n' "$Y" "$N" "$name" "$(readlink "$item")"
    fi
  elif [ -e "$item" ]; then
    name="$(basename "$item")"
    if [ -d "$item" ] && [ ! -f "$item/SKILL.md" ]; then
      printf '  %s空壳目录%s %s（没有 SKILL.md）\n' "$Y" "$N" "$name"
    fi
  fi
done
printf '\n'

printf '%s汇总%s  改名 %s / 迁入 %s / 冲突 %s / 完全相同 %s / 跳过 %s / 非 skill %s\n' \
  "$B" "$N" "$n_ren" "$n_mv" "$n_conf" "$n_same" "$n_skip" "$n_bad"

if [ "$APPLY" -eq 1 ]; then
  printf '%s迁移步骤完成。%s 备份位于 %s\n' "$G" "$N" "$BACKUP"
else
  printf '这是预演。安全起步建议：%s --apply --conflict=identical\n' "$0"
fi
