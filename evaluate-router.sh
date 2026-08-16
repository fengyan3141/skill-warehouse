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
CATALOG_FILE="$SKILL_LIBRARY_ROOT/catalog.tsv"
FIXTURES_FILE="${SKILL_ROUTE_EVALS:-$PACKAGE_ROOT/config/route-evals.tsv}"
WRITE_STATUS=0
APPLY=0

usage() {
  printf '%s\n' '用法：evaluate-router.sh [--fixtures 文件] [--write-status --apply]'
}

catalog_sha256() {
  shasum -a 256 "$CATALOG_FILE" | awk '{ print $1 }'
}

print_metrics() {
  local top1_hit="$1" top3_hit="$2" clear_total="$3" ambiguous_bad="$4" ambiguous_total="$5" auto_route="$6"

  awk -v top1_hit="$top1_hit" -v top3_hit="$top3_hit" -v clear_total="$clear_total" \
    -v ambiguous_bad="$ambiguous_bad" -v ambiguous_total="$ambiguous_total" -v auto_route="$auto_route" '
    BEGIN {
      printf "top1=%.6f\n", (clear_total > 0 ? top1_hit / clear_total : 0)
      printf "top3=%.6f\n", (clear_total > 0 ? top3_hit / clear_total : 0)
      printf "ambiguous_false_select=%.6f\n", (ambiguous_total > 0 ? ambiguous_bad / ambiguous_total : 0)
      printf "AUTO_ROUTE=%s\n", auto_route
    }
  '
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixtures)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      FIXTURES_FILE="$2"
      shift 2
      ;;
    --write-status)
      WRITE_STATUS=1
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$WRITE_STATUS" -ne "$APPLY" ]; then
  printf '%s\n' '写入状态必须同时显式指定 --write-status --apply' >&2
  exit 2
fi

[ -f "$CATALOG_FILE" ] || { printf '目录不存在: %s\n' "$CATALOG_FILE" >&2; exit 1; }
[ -f "$FIXTURES_FILE" ] || { printf '评测夹具不存在: %s\n' "$FIXTURES_FILE" >&2; exit 1; }

clear_total=0
top1_hit=0
top3_hit=0
ambiguous_total=0
ambiguous_bad=0
evaluation_error=0
tab="$(printf '\t')"

while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in
    *"$tab"*) ;;
    *)
      printf '评测夹具字段不足\n' >&2
      evaluation_error=1
      continue
      ;;
  esac
  class="${row%%"$tab"*}"
  remainder="${row#*"$tab"}"
  case "$remainder" in
    *"$tab"*) ;;
    *)
      printf '评测夹具字段不足\n' >&2
      evaluation_error=1
      continue
      ;;
  esac
  expected_id="${remainder%%"$tab"*}"
  query="${remainder#*"$tab"}"
  [ "$class" = "class" ] && continue

  case "$class" in
    clear|ambiguous|none) ;;
    *)
      printf '无效评测类别：%s\n' "$class" >&2
      evaluation_error=1
      continue
      ;;
  esac

  if [ "$class" = "clear" ] && [ -z "$expected_id" ]; then
    printf 'clear 评测缺少 expected_id\n' >&2
    evaluation_error=1
    continue
  fi
  if [ -z "$query" ]; then
    printf '评测夹具缺少 query\n' >&2
    evaluation_error=1
    continue
  fi

  route_output=""
  if ! route_output="$(/bin/bash "$SCRIPT_DIR/skillctl" route "$query")"; then
    printf '路由评测失败：%s\n' "$query" >&2
    evaluation_error=1
    continue
  fi

  case "$class" in
    clear)
      clear_total=$((clear_total + 1))
      top1_id="$(printf '%s\n' "$route_output" | awk -F '\t' 'NR == 1 { print $2 }')"
      if [ "$top1_id" = "$expected_id" ]; then
        top1_hit=$((top1_hit + 1))
      fi
      if printf '%s\n' "$route_output" | awk -F '\t' -v expected_id="$expected_id" '$2 == expected_id { found = 1 } END { exit(found ? 0 : 1) }'; then
        top3_hit=$((top3_hit + 1))
      fi
      ;;
    ambiguous)
      ambiguous_total=$((ambiguous_total + 1))
      candidate_count="$(printf '%s\n' "$route_output" | awk 'NF { count++ } END { print count + 0 }')"
      if [ "$candidate_count" -eq 1 ]; then
        ambiguous_bad=$((ambiguous_bad + 1))
      fi
      ;;
    none)
      ;;
  esac
done < "$FIXTURES_FILE"

top1_ok="$(awk -v hit="$top1_hit" -v total="$clear_total" 'BEGIN { print (total > 0 && hit / total >= 0.90) ? 1 : 0 }')"
top3_ok="$(awk -v hit="$top3_hit" -v total="$clear_total" 'BEGIN { print (total > 0 && hit / total >= 0.98) ? 1 : 0 }')"
ambiguous_ok="$(awk -v bad="$ambiguous_bad" -v total="$ambiguous_total" 'BEGIN { print (total > 0 && bad / total <= 0.05) ? 1 : 0 }')"

auto_route=disabled
if [ "$evaluation_error" -eq 0 ] && [ "$top1_ok" = "1" ] && [ "$top3_ok" = "1" ] && [ "$ambiguous_ok" = "1" ]; then
  auto_route=enabled
fi

print_metrics "$top1_hit" "$top3_hit" "$clear_total" "$ambiguous_bad" "$ambiguous_total" "$auto_route"

if [ "$WRITE_STATUS" -eq 1 ]; then
  state_dir="$SKILL_LIBRARY_ROOT/state"
  mkdir -p "$state_dir"
  tmp_file="$(mktemp "$state_dir/.router-gate.tsv.XXXXXX")"
  trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(catalog_sha256)" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(awk -v hit="$top1_hit" -v total="$clear_total" 'BEGIN { printf "%.6f", (total > 0 ? hit / total : 0) }')" \
    "$(awk -v hit="$top3_hit" -v total="$clear_total" 'BEGIN { printf "%.6f", (total > 0 ? hit / total : 0) }')" \
    "$(awk -v bad="$ambiguous_bad" -v total="$ambiguous_total" 'BEGIN { printf "%.6f", (total > 0 ? bad / total : 0) }')" \
    "$auto_route" > "$tmp_file"
  mv "$tmp_file" "$state_dir/router-gate.tsv"
  trap - EXIT HUP INT TERM
fi

[ "$auto_route" = "enabled" ]
