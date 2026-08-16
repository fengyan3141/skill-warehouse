#!/usr/bin/env bash

pass=0
fail=0

ok() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

not_ok() {
  printf 'not ok - %s\n' "$1" >&2
  fail=$((fail + 1))
}

assert_exists() {
  if [ -e "$1" ]; then ok "$2"; else not_ok "$2"; fi
}

assert_not_exists() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then ok "$2"; else not_ok "$2"; fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else
    printf '  got:  %s\n  want: %s\n' "$1" "$2" >&2
    not_ok "$3"
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -F -- "$2" >/dev/null; then ok "$3"; else not_ok "$3"; fi
}

assert_not_contains() {
  if ! printf '%s' "$1" | grep -F -- "$2" >/dev/null; then ok "$3"; else not_ok "$3"; fi
}

make_skill() {
  local dir="$1" name="$2" body="${3:-body}"
  mkdir -p "$dir"
  printf '%s\n' '---' "name: $name" "description: test $name" '---' "$body" > "$dir/SKILL.md"
}

new_home() {
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skill-script-test.XXXXXX")"
  mkdir -p "$TEST_HOME/.agents/skills" "$TEST_HOME/.claude/skills" "$TEST_HOME/.codex/skills"
}

cleanup_home() {
  chmod -R u+rwX "$TEST_HOME" 2>/dev/null || true
  rm -rf "$TEST_HOME"
}
