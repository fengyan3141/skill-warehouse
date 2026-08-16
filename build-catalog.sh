#!/bin/bash
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

SKILL_LIBRARY_ROOT="${SKILL_LIBRARY_ROOT:-$HOME/.skill-library}"
SKILLS_DIR="$SKILL_LIBRARY_ROOT/skills"
ALIASES_FILE="${SKILL_ALIASES:-$PACKAGE_ROOT/config/aliases.tsv}"
APPLY=0

. "$PACKAGE_ROOT/lib/skill-lib.sh"

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      printf '用法: %s [--apply]\n' "$0"
      exit 0
      ;;
    *)
      printf '未知参数: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

generate_catalog() {
  local skill_dir id description relative_path

  [ -d "$SKILLS_DIR" ] || {
    printf 'skills 目录不存在: %s\n' "$SKILLS_DIR" >&2
    return 1
  }
  [ -f "$ALIASES_FILE" ] || {
    printf '别名配置不存在: %s\n' "$ALIASES_FILE" >&2
    return 1
  }

  for skill_dir in "$SKILLS_DIR"/*; do
    [ -d "$skill_dir" ] && [ ! -L "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    id="$(skill_declared_name "$skill_dir")"
    valid_skill_name "$id" || continue
    description="$(skill_description "$skill_dir")"
    relative_path="skills/$(basename "$skill_dir")"

    awk -F '\t' -v id="$id" -v relative_path="$relative_path" -v description="$description" '
      $0 !~ /^#/ && NF >= 6 && $1 == id {
        print id "\t" relative_path "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" description
        found = 1
        exit
      }
      END {
        if (!found) print id "\t" relative_path "\t\t\t\t\t\t" description
      }
    ' "$ALIASES_FILE"
  done
}

if [ "$APPLY" -ne 1 ]; then
  printf '预演模式，不会生成或替换 catalog.tsv；确认后运行: %s --apply\n' "$0"
  exit 0
fi

[ -d "$SKILL_LIBRARY_ROOT" ] || {
  printf 'Skill 仓库不存在: %s\n' "$SKILL_LIBRARY_ROOT" >&2
  exit 1
}

tmp="$(mktemp "$SKILL_LIBRARY_ROOT/.catalog.tsv.XXXXXX")"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
generate_catalog > "$tmp"
awk -F '\t' 'NF != 8 { exit 1 }' "$tmp"
atomic_replace "$tmp" "$SKILL_LIBRARY_ROOT/catalog.tsv"
trap - EXIT HUP INT TERM
