#!/bin/bash

skill_declared_name() {
  local dir="$1"

  [ -f "$dir/SKILL.md" ] || return 1
  awk '
    NR == 1 {
      if ($0 != "---") exit 1
      frontmatter = 1
      next
    }
    frontmatter && $0 == "---" { exit }
    frontmatter && $0 ~ /^name:[[:space:]]*/ {
      value = $0
      sub(/^name:[[:space:]]*/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        sub(/^./, "", value)
        sub(/.$/, "", value)
      }
      print value
      exit
    }
  ' "$dir/SKILL.md"
}

skill_description() {
  local dir="$1"

  [ -f "$dir/SKILL.md" ] || return 1
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function emit() {
      if (!printed) {
        gsub(/[[:space:]]+/, " ", description)
        print trim(description)
        printed = 1
      }
    }
    NR == 1 {
      if ($0 != "---") exit 1
      frontmatter = 1
      next
    }
    !frontmatter { exit }
    $0 == "---" {
      if (found) emit()
      exit
    }
    collecting {
      if ($0 ~ /^[[:space:]]/) {
        value = $0
        sub(/^[[:space:]]+/, "", value)
        value = trim(value)
        if (value != "") description = description (description == "" ? "" : " ") value
        next
      }
      emit()
      exit
    }
    $0 ~ /^description:[[:space:]]*/ {
      value = $0
      sub(/^description:[[:space:]]*/, "", value)
      value = trim(value)
      found = 1
      # 值为空也要当成"下一行起才是内容"处理——YAML 的纯量折叠风格允许
      # description: 后面直接换行、缩进写正文，不需要 |/> 这类块标量指示符。
      # 真实数据里 web-access 这个 Skill 就是这么写的，之前没处理这种情况，
      # 导致它的 description 一直被解析成空字符串，catalog.tsv 里这一列
      # 长期缺失，拖累了 search 命中率。
      if (value == "" || value == "|" || value == "|-" || value == ">" || value == ">-") {
        collecting = 1
        next
      }
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        sub(/^./, "", value)
        sub(/.$/, "", value)
      }
      description = value
      emit()
      exit
    }
    END {
      if (frontmatter && found && !printed) emit()
    }
  ' "$dir/SKILL.md"
}

valid_skill_name() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}

atomic_replace() {
  local temp="$1" final="$2"

  [ -f "$temp" ] || return 1
  [ -L "$final" ] && return 1
  { [ ! -e "$final" ] || [ -f "$final" ]; } || return 1
  mv "$temp" "$final"
}

real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" && pwd -P)
}

managed_link_target() {
  [ -L "$1" ] || return 1
  readlink "$1"
}

directory_content_hash() {
  local dir="$1"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  (
    cd "$dir" && find . -type f ! -name '.DS_Store' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  ) | shasum -a 256 | awk '{ print $1 }'
}
