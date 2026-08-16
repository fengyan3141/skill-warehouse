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
PROFILE_DIR="$PACKAGE_ROOT/config/profiles"
SKILLCTL_BIN="$SCRIPT_DIR/skillctl"
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

html_escape() {
  local s
  s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

# 顶部统计卡片：全部/已激活/仓库中/已归档/缺失或冲突，各数一遍
# skillctl status 的输出，跟 render_skills_table 里的状态分类口径保持一致
# （已激活/仓库中/已归档各一类，真实目录冲突、外部软链冲突、缺失合并成一类）。
render_stats_cards() {
  local status_output archived_count manifest
  status_output="$("$SKILLCTL_BIN" status 2>/dev/null)" || {
    printf '<p class="empty-note">无法读取状态统计。</p>\n'
    return 0
  }

  # 已归档这一格特意不数 skillctl status 里的"已归档"标签——那个标签只在
  # "刚归档、catalog 还没重建"的一瞬间才会出现（catalog.tsv 只收录仓库里
  # 现存的 skills/ 目录，一旦重建，被归档的 id 就整行从 catalog 消失，
  # status 也就再也不会报它"已归档"），正常情况下永远是 0，跟下面"归档"
  # 表格里看到的历史记录对不上、容易让人误以为归档没被追踪。这里改成跟
  # render_archive_section 同一个数据源（扫 archive/*/manifest.tsv 数行数），
  # 保证这张卡片上的数字和往下滚动看到的表格行数一致。
  archived_count=0
  for manifest in "$SKILL_LIBRARY_ROOT"/archive/*/manifest.tsv; do
    [ -f "$manifest" ] || continue
    archived_count=$((archived_count + $(grep -c . "$manifest")))
  done

  awk -F '\t' -v archived_count="$archived_count" '
    $1 == "全局" { total++; count[$2]++ }
    END {
      issue = count["真实目录冲突"] + count["外部软链冲突"] + count["缺失"]
      printf "<div class=\"stat-cards\">\n"
      printf "<div class=\"stat-card\"><span class=\"stat-value\">%d</span><span class=\"stat-label\">全部 Skill</span></div>\n", total + 0
      printf "<div class=\"stat-card stat-active\"><span class=\"stat-value\">%d</span><span class=\"stat-label\">已激活</span></div>\n", count["已激活"] + 0
      printf "<div class=\"stat-card stat-warehouse\"><span class=\"stat-value\">%d</span><span class=\"stat-label\">仓库中</span></div>\n", count["仓库中"] + 0
      printf "<div class=\"stat-card stat-archived\"><span class=\"stat-value\">%d</span><span class=\"stat-label\">已归档</span></div>\n", archived_count + 0
      printf "<div class=\"stat-card stat-issue\"><span class=\"stat-value\">%d</span><span class=\"stat-label\">缺失/冲突</span></div>\n", issue + 0
      printf "</div>\n"
    }
  ' <<< "$status_output"
}

render_skills_table() {
  local status_map_file profiles_map_file catalog_id pfile pname plist

  status_map_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-status.XXXXXX")"
  profiles_map_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-profiles.XXXXXX")"
  trap 'rm -f "$status_map_file" "$profiles_map_file"' RETURN

  if ! "$SKILLCTL_BIN" status > "$status_map_file.raw"; then
    printf '生成面板失败：无法读取 Skill 状态（%s status 执行失败，检查是否有可执行权限）\n' "$SKILLCTL_BIN" >&2
    rm -f "$status_map_file.raw"
    return 1
  fi
  awk -F '\t' '$1 == "全局" { print $4 "\t" $2 }' "$status_map_file.raw" > "$status_map_file"
  rm -f "$status_map_file.raw"

  : > "$profiles_map_file"
  while IFS="$(printf '\t')" read -r catalog_id _rest; do
    [ -n "$catalog_id" ] || continue
    plist=""
    for pfile in "$PROFILE_DIR"/*; do
      [ -f "$pfile" ] || continue
      grep -F -x "$catalog_id" "$pfile" >/dev/null 2>&1 || continue
      pname="$(basename "$pfile")"
      if [ -n "$plist" ]; then plist="$plist,$pname"; else plist="$pname"; fi
    done
    printf '%s\t%s\n' "$catalog_id" "$plist" >> "$profiles_map_file"
  done < "$CATALOG_FILE"

  printf '<table id="skills-table"><thead><tr><th>状态</th><th>中文名称</th><th>英文 ID</th><th>分类</th><th>所属场景包</th><th>简介</th></tr></thead><tbody>\n'
  awk -F '\t' -v status_map_file="$status_map_file" -v profiles_map_file="$profiles_map_file" '
    function html_escape(s) {
      gsub(/&/, "\\&amp;", s)
      gsub(/</, "\\&lt;", s)
      gsub(/>/, "\\&gt;", s)
      gsub(/"/, "\\&quot;", s)
      return s
    }
    function status_class(label) {
      if (label == "已激活") return "chip-active"
      if (label == "仓库中") return "chip-warehouse"
      if (label == "已归档") return "chip-archived"
      if (label == "缺失") return "chip-missing"
      return "chip-conflict"
    }
    BEGIN {
      while ((getline sline < status_map_file) > 0) {
        split(sline, f, "\t")
        if (f[1] != "") status_by_id[f[1]] = f[2]
      }
      close(status_map_file)
      while ((getline pline < profiles_map_file) > 0) {
        split(pline, f, "\t")
        if (f[1] != "") profiles_by_id[f[1]] = f[2]
      }
      close(profiles_map_file)
    }
    NF == 8 {
      raw_id = $1
      id = html_escape($1)
      display = html_escape($3)
      category = html_escape($5)
      description = html_escape($8)
      raw_status = (raw_id in status_by_id) ? status_by_id[raw_id] : "缺失"
      status = html_escape(raw_status)
      raw_profiles = (raw_id in profiles_by_id) ? profiles_by_id[raw_id] : ""
      profiles = html_escape(raw_profiles)
      cls = status_class(raw_status)
      search = tolower(id " " display " " category " " profiles " " description)
      printf "<tr data-search=\"%s\" data-status=\"%s\" data-category=\"%s\" data-id=\"%s\" onclick=\"onSkillRowClick(this)\">\n", search, status, category, id
      printf "  <td><span class=\"chip %s\">%s</span></td>\n", cls, status
      printf "  <td>%s</td>\n", display
      printf "  <td><code class=\"technical-id\">%s</code></td>\n", id
      printf "  <td>%s</td>\n", category
      printf "  <td>%s</td>\n", profiles
      printf "  <td>%s</td>\n", description
      printf "</tr>\n"
    }
  ' "$CATALOG_FILE"
  printf '</tbody></table>\n'
  rm -f "$status_map_file" "$profiles_map_file"
  trap - RETURN
}

render_profiles_section() {
  local pfile pname count members display_line member_id member_html
  printf '<table><thead><tr><th>场景包</th><th>数量</th><th>成员</th></tr></thead><tbody>\n'
  for pfile in "$PROFILE_DIR"/*; do
    [ -f "$pfile" ] || continue
    pname="$(basename "$pfile")"
    # 数量和成员列表都只数"仓库里真能找到"的——场景包文件里的 id 如果被
    # 归档/删掉了，直接跳过不显示，不显示裸 id 也不显示缺失标记；数量因此
    # 也要跟着改成实际显示了几个，不能再拿文件行数直接当数量，不然两边
    # 会对不上。
    count=0
    members=""
    while IFS= read -r member_id; do
      [ -n "$member_id" ] || continue
      display_line="$(awk -F '\t' -v id="$member_id" 'NF == 8 && $1 == id { print $3; exit }' "$CATALOG_FILE")"
      [ -n "$display_line" ] || continue
      member_html="$(html_escape "$display_line")"
      count=$((count + 1))
      if [ -n "$members" ]; then members="${members}、${member_html}"; else members="$member_html"; fi
    done < <(sed '/^[[:space:]]*$/d; /^[[:space:]]*#/d' "$pfile")
    [ -n "$members" ] || members='<span class="empty-note">场景包文件里的成员都不在仓库中</span>'
    printf '<tr><td><code class="technical-id">%s</code></td><td>%s</td><td>%s</td></tr>\n' \
      "$(html_escape "$pname")" "$count" "$members"
  done
  printf '</tbody></table>\n'
}

render_archive_section() {
  local manifest skill_id archive_id _sha256 archived_at profiles _managed_links display_name found
  found=0
  printf '<table><thead><tr><th>中文名称</th><th>英文 ID</th><th>归档版本</th><th>归档时间</th><th>原场景包</th></tr></thead><tbody>\n'
  for manifest in "$SKILL_LIBRARY_ROOT"/archive/*/manifest.tsv; do
    [ -f "$manifest" ] || continue
    while IFS="$(printf '\t')" read -r skill_id archive_id _sha256 archived_at profiles _managed_links; do
      [ -n "$skill_id" ] || continue
      found=1
      display_name="$(awk -F '\t' -v id="$skill_id" 'NF == 8 && $1 == id { print $3; exit }' "$CATALOG_FILE")"
      [ -n "$display_name" ] || display_name="$skill_id"
      printf '<tr><td>%s</td><td><code class="technical-id">%s</code></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(html_escape "$display_name")" "$(html_escape "$skill_id")" "$(html_escape "$archive_id")" \
        "$(html_escape "$archived_at")" "$(html_escape "$profiles")"
    done < "$manifest"
  done
  printf '</tbody></table>\n'
  if [ "$found" -eq 0 ]; then
    printf '<p class="empty-note">暂无归档版本。</p>\n'
  fi
}

render_adapters_section() {
  local adapters_file detect_output id display mode global_dir _project_dir _cli_command _app_name _verification status mode_label command_text
  adapters_file="${SKILL_ADAPTERS:-$PACKAGE_ROOT/config/adapters/tools.tsv}"
  [ -f "$adapters_file" ] || { printf '<p class="empty-note">软件适配器配置不存在。</p>\n'; return 0; }

  detect_output="$("$SKILLCTL_BIN" tools detect 2>/dev/null || true)"

  printf '<table><thead><tr><th>软件</th><th>状态</th><th>接入方式</th><th>安全命令</th></tr></thead><tbody>\n'
  while IFS=';' read -r id display mode global_dir _project_dir _cli_command _app_name _verification; do
    [ -n "$id" ] || continue
    case "$id" in \#*) continue ;; esac
    status="$(printf '%s\n' "$detect_output" | awk -F '\t' -v id="$id" '$1 == id { print $2; exit }')"
    [ -n "$status" ] || status="未检测到"
    if [ "$mode" = "native" ]; then
      mode_label="原生"
      command_text="（原生模式，自动共享全局 Skill 目录，无需命令）"
    else
      mode_label="软链"
      # 这里的 ~ 是给用户看的字面文本（面板上一键复制的命令），不是要展开
      # 的路径，故意不用 $HOME 拼接。
      # shellcheck disable=SC2088
      command_text="~/.skill-library/bin/skillctl tools connect $id --apply"
    fi
    printf '<tr><td>%s <code class="technical-id">%s</code></td><td><span class="chip %s">%s</span></td><td>%s</td><td>' \
      "$(html_escape "$display")" "$(html_escape "$id")" "$(adapter_status_class "$status")" "$(html_escape "$status")" "$(html_escape "$mode_label")"
    if [ "$mode" = "native" ]; then
      printf '<span class="empty-note">%s</span>' "$(html_escape "$command_text")"
    else
      printf '<code class="technical-id">%s</code> <button type="button" class="copy-btn" onclick="copyCommand(this, %s)">复制</button>' \
        "$(html_escape "$command_text")" "$(js_string_literal "$command_text")"
    fi
    printf '</td></tr>\n'
  done < <(tr '\t' ';' < "$adapters_file")
  printf '</tbody></table>\n'
}

adapter_status_class() {
  case "$1" in
    已检测) printf 'chip-active\n' ;;
    可能是残留目录) printf 'chip-archived\n' ;;
    *) printf 'chip-missing\n' ;;
  esac
}

js_string_literal() {
  local s
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf "'%s'" "$s"
}

generate_dashboard() {
  local generated_at
  [ -f "$CATALOG_FILE" ] || { printf '目录不存在: %s\n' "$CATALOG_FILE" >&2; return 1; }
  [ -f "$SKILLCTL_BIN" ] || { printf 'skillctl 不存在: %s\n' "$SKILLCTL_BIN" >&2; return 1; }
  generated_at="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  cat <<'HTML_HEAD'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Skill 仓库面板</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #F8FAFC;
    --surface: #FFFFFF;
    --surface-2: #F1F5F9;
    --text: #0F172A;
    --text-muted: #64748B;
    --border: #E2E8F0;
    --primary: #4F46E5;
    --primary-fg: #FFFFFF;
    --primary-bg: #4F46E51F;
    --ring: #4F46E5;
    --success: #16A34A;
    --success-bg: #16A34A1F;
    --warning: #A16207;
    --warning-bg: #A162071F;
    --danger: #DC2626;
    --danger-bg: #DC26261F;
    --neutral: #64748B;
    --neutral-bg: #64748B1F;
    --shadow-sm: 0 1px 2px rgba(15, 23, 42, 0.06);
    --shadow-md: 0 6px 20px rgba(15, 23, 42, 0.08);
    --radius: 10px;
    --radius-sm: 6px;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0B1120;
      --surface: #121A2C;
      --surface-2: #1B2436;
      --text: #F1F5F9;
      --text-muted: #94A3B8;
      --border: #263248;
      --primary: #818CF8;
      --primary-fg: #0B1120;
      --primary-bg: #818CF81F;
      --ring: #818CF8;
      --success: #4ADE80;
      --success-bg: #4ADE801F;
      --warning: #FBBF24;
      --warning-bg: #FBBF241F;
      --danger: #F87171;
      --danger-bg: #F871711F;
      --neutral: #94A3B8;
      --neutral-bg: #94A3B81F;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3);
      --shadow-md: 0 6px 24px rgba(0, 0, 0, 0.45);
    }
  }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    -webkit-font-smoothing: antialiased;
    margin: 0;
    padding: 32px 24px 96px;
    background: var(--bg);
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }
  .page { max-width: 1280px; margin: 0 auto; }
  .page-header { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 24px; }
  h1 { font-size: 1.5rem; font-weight: 650; margin: 0 0 6px; letter-spacing: -0.01em; }
  .subtitle { color: var(--text-muted); font-size: 0.88rem; margin: 0; }
  .readonly-badge { display: inline-block; padding: 3px 10px; border-radius: 999px; background: var(--primary); color: var(--primary-fg); font-size: 0.72rem; font-weight: 600; margin-left: 8px; vertical-align: 2px; }
  .stat-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 24px; }
  .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px 16px; box-shadow: var(--shadow-sm); border-left: 3px solid var(--border); }
  .stat-card .stat-value { display: block; font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
  .stat-card .stat-label { display: block; font-size: 0.78rem; color: var(--text-muted); margin-top: 2px; }
  .stat-card.stat-active { border-left-color: var(--success); }
  .stat-card.stat-active .stat-value { color: var(--success); }
  .stat-card.stat-warehouse { border-left-color: var(--neutral); }
  .stat-card.stat-archived { border-left-color: var(--warning); }
  .stat-card.stat-archived .stat-value { color: var(--warning); }
  .stat-card.stat-issue { border-left-color: var(--danger); }
  .stat-card.stat-issue .stat-value { color: var(--danger); }
  section { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 18px 20px; margin-bottom: 20px; box-shadow: var(--shadow-sm); }
  h2 { font-size: 0.95rem; font-weight: 650; margin: 0 0 14px; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
  .controls { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-bottom: 14px; }
  input[type=search], select {
    padding: 7px 12px; border-radius: var(--radius-sm); border: 1px solid var(--border);
    background: var(--surface-2); color: var(--text); font-size: 0.85rem;
  }
  input[type=search] { width: 260px; }
  input[type=search]:focus, select:focus, button:focus-visible {
    outline: 2px solid var(--ring); outline-offset: 1px;
  }
  table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
  th {
    position: sticky; top: 0; text-align: left; padding: 9px 12px; background: var(--surface-2);
    color: var(--text-muted); font-weight: 600; font-size: 0.76rem; letter-spacing: 0.02em;
    border-bottom: 1px solid var(--border); z-index: 1; white-space: nowrap;
  }
  td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
  #skills-table tbody tr:nth-child(even) { background: var(--surface-2); }
  #skills-table tbody tr:hover { background: var(--success-bg); }
  code.technical-id { color: var(--text-muted); font-size: 0.85em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .chip { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 0.74rem; font-weight: 600; white-space: nowrap; }
  .chip-active { background: var(--success-bg); color: var(--success); }
  .chip-warehouse { background: var(--neutral-bg); color: var(--neutral); }
  .chip-archived { background: var(--warning-bg); color: var(--warning); }
  .chip-missing { background: var(--danger-bg); color: var(--danger); }
  .chip-conflict { background: var(--danger-bg); color: var(--danger); }
  .empty-note { color: var(--text-muted); font-size: 0.85rem; }
  button { font-family: inherit; }
  button.copy-btn {
    font-size: 0.76rem; padding: 3px 10px; cursor: pointer; border-radius: var(--radius-sm);
    border: 1px solid var(--border); background: var(--surface); color: var(--text); transition: background 0.15s ease, border-color 0.15s ease;
  }
  button.copy-btn:hover { background: var(--surface-2); border-color: var(--primary); }
  tr.hidden { display: none; }
  button.mode-toggle-btn {
    font-size: 0.82rem; font-weight: 600; padding: 7px 14px; cursor: pointer; border-radius: var(--radius-sm);
    border: 1px solid var(--border); background: var(--surface); color: var(--text); transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
  }
  button.mode-toggle-btn[data-mode="archive"]:hover { border-color: var(--danger); }
  button.mode-toggle-btn[data-mode="archive"].active { background: var(--danger); border-color: var(--danger); color: #fff; }
  button.mode-toggle-btn[data-mode="toggle"]:hover { border-color: var(--primary); }
  button.mode-toggle-btn[data-mode="toggle"].active { background: var(--primary); border-color: var(--primary); color: var(--primary-fg); }
  #skills-table tbody tr.row-selectable { cursor: pointer; }
  #skills-section.mode-archive #skills-table tbody tr.row-selectable:hover { background: var(--danger-bg); }
  #skills-section.mode-archive #skills-table tbody tr.row-selected { outline: 2px solid var(--danger); outline-offset: -2px; background: var(--danger-bg); }
  #skills-section.mode-toggle #skills-table tbody tr.row-selectable:hover { background: var(--primary-bg); }
  #skills-section.mode-toggle #skills-table tbody tr.row-selected { outline: 2px solid var(--primary); outline-offset: -2px; background: var(--primary-bg); }
  .selection-bar {
    position: fixed; left: 0; right: 0; bottom: 0; padding: 14px 24px; background: var(--surface); color: var(--text);
    border-top: 1px solid var(--border); box-shadow: 0 -4px 16px rgba(15, 23, 42, 0.08);
    display: flex; align-items: center; gap: 12px; justify-content: flex-end;
    transform: translateY(100%); transition: transform 0.15s ease; z-index: 20;
  }
  .selection-bar.visible { transform: translateY(0); }
  .selection-bar .selection-count { margin-right: auto; font-size: 0.88rem; color: var(--text-muted); font-weight: 500; }
  button.selection-confirm-btn {
    color: #fff; border-radius: var(--radius-sm);
    padding: 9px 18px; font-size: 0.88rem; font-weight: 600; cursor: pointer; transition: filter 0.15s ease;
  }
  button.selection-confirm-btn[data-mode="archive"] { background: var(--danger); border: 1px solid var(--danger); }
  button.selection-confirm-btn[data-mode="toggle"] { background: var(--primary); color: var(--primary-fg); border: 1px solid var(--primary); }
  button.selection-confirm-btn:hover { filter: brightness(1.08); }
  .archive-toast {
    position: fixed; bottom: 72px; right: 24px; background: var(--success); color: #fff; padding: 11px 16px;
    border-radius: var(--radius-sm); font-size: 0.85rem; max-width: 360px; box-shadow: var(--shadow-md);
    opacity: 0; transform: translateY(8px); transition: opacity 0.15s ease, transform 0.15s ease; pointer-events: none; z-index: 30;
  }
  .archive-toast.visible { opacity: 1; transform: translateY(0); }
</style>
</head>
<body>
<div class="page">
HTML_HEAD

  printf '<header class="page-header">\n<div>\n'
  printf '<h1>Skill 仓库面板 <span class="readonly-badge">只读面板</span></h1>\n'
  printf '<p class="subtitle">生成时间：%s ・ 本页为静态快照，需重新运行 <code class="technical-id">skillctl dashboard build --apply</code> 才会刷新</p>\n' "$(html_escape "$generated_at")"
  printf '<p class="subtitle">Skill 文件夹：<code class="technical-id">%s</code> <button type="button" class="copy-btn" onclick="copyCommand(this, %s)">复制</button>（粘贴到 Finder"前往文件夹"可直接跳转，快捷键 Cmd+Shift+G）</p>\n' \
    "$(html_escape "$SKILL_LIBRARY_ROOT/skills")" "$(js_string_literal "$SKILL_LIBRARY_ROOT/skills")"
  printf '</div>\n</header>\n'

  render_stats_cards

  printf '<section id="skills-section">\n<h2>Skill 列表</h2>\n'
  printf '<div class="controls">\n'
  printf '<input type="search" id="skill-search" placeholder="按中文名称、别名或英文 ID 搜索…" oninput="applyFilters()">\n'
  printf '<select id="status-filter" onchange="applyFilters()"><option value="">全部状态</option><option value="已激活">已激活</option><option value="仓库中">仓库中</option><option value="已归档">已归档</option><option value="缺失">缺失</option><option value="冲突">冲突</option></select>\n'
  printf '<button type="button" id="toggle-mode-btn" class="mode-toggle-btn" data-mode="toggle" onclick="toggleSelectionMode(%s)">激活/停用模式</button>\n' "$(js_string_literal toggle)"
  printf '<button type="button" id="archive-mode-btn" class="mode-toggle-btn" data-mode="archive" onclick="toggleSelectionMode(%s)">归档模式</button>\n' "$(js_string_literal archive)"
  printf '</div>\n'
  render_skills_table
  printf '</section>\n'

  printf '<div class="selection-bar" id="selection-bar">\n'
  printf '<span class="selection-count" id="selection-count">已选中 0 项</span>\n'
  printf '<button type="button" class="selection-confirm-btn" id="selection-confirm-btn" onclick="copySelectionCommand()">复制命令</button>\n'
  printf '</div>\n'
  printf '<div class="archive-toast" id="archive-toast"></div>\n'

  printf '<section id="profiles-section">\n<h2>场景包</h2>\n'
  render_profiles_section
  printf '</section>\n'

  printf '<section id="archive-section">\n<h2>归档</h2>\n'
  printf '<p class="subtitle">归档文件夹：<code class="technical-id">%s</code> <button type="button" class="copy-btn" onclick="copyCommand(this, %s)">复制</button>（每个 Skill 归档后放在这个文件夹下自己的 &lt;id&gt; 子目录里）</p>\n' \
    "$(html_escape "$SKILL_LIBRARY_ROOT/archive")" "$(js_string_literal "$SKILL_LIBRARY_ROOT/archive")"
  render_archive_section
  printf '</section>\n'

  printf '<section id="adapters-section">\n<h2>软件接入</h2>\n'
  render_adapters_section
  printf '</section>\n'

  printf '</div>\n'

  cat <<'HTML_TAIL'
<script>
function applyFilters() {
  var q = (document.getElementById('skill-search').value || '').toLowerCase();
  var wantStatus = document.getElementById('status-filter').value;
  var rows = document.querySelectorAll('#skills-table tbody tr');
  rows.forEach(function (row) {
    var hay = row.dataset.search || '';
    var status = row.dataset.status || '';
    var matchesText = q === '' || hay.indexOf(q) !== -1;
    var matchesStatus = wantStatus === '' ||
      status === wantStatus ||
      (wantStatus === '冲突' && status.indexOf('冲突') !== -1);
    row.classList.toggle('hidden', !(matchesText && matchesStatus));
  });
}
function copyCommand(btn, text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text);
  }
  var original = btn.textContent;
  btn.textContent = '已复制';
  setTimeout(function () { btn.textContent = original; }, 1200);
}
// 两种点选模式共用同一套选中态和底部浮条：'archive' 每个选中项固定生成
// skillctl archive <id> --apply；'toggle' 按每一行当前的状态（data-status）
// 各自生成 activate 或 deactivate，方便一次多选、混着已激活/仓库中的项目
// 也能批量拿到正确的命令。两种模式互斥，切一个会自动关掉另一个并清空选中。
var selectionMode = null;
var selected = {};
var MODE_BUTTON_IDS = { archive: 'archive-mode-btn', toggle: 'toggle-mode-btn' };
var MODE_LABELS = { archive: '归档模式', toggle: '激活/停用模式' };
function toggleSelectionMode(mode) {
  var nextMode = (selectionMode === mode) ? null : mode;
  if (selectionMode) {
    var prevBtn = document.getElementById(MODE_BUTTON_IDS[selectionMode]);
    prevBtn.classList.remove('active');
    prevBtn.textContent = MODE_LABELS[selectionMode];
    document.getElementById('skills-section').classList.remove('mode-' + selectionMode);
  }
  selected = {};
  selectionMode = nextMode;
  var rows = document.querySelectorAll('#skills-table tbody tr');
  rows.forEach(function (row) {
    row.classList.toggle('row-selectable', !!selectionMode);
    row.classList.remove('row-selected');
  });
  if (selectionMode) {
    var btn = document.getElementById(MODE_BUTTON_IDS[selectionMode]);
    btn.classList.add('active');
    btn.textContent = '退出' + MODE_LABELS[selectionMode];
    document.getElementById('skills-section').classList.add('mode-' + selectionMode);
    var confirmBtn = document.getElementById('selection-confirm-btn');
    confirmBtn.dataset.mode = selectionMode;
    confirmBtn.textContent = selectionMode === 'archive' ? '复制归档命令' : '复制命令';
  }
  updateSelectionBar();
}
function onSkillRowClick(row) {
  if (!selectionMode) return;
  var id = row.dataset.id;
  if (!id) return;
  if (selected[id]) {
    delete selected[id];
    row.classList.remove('row-selected');
  } else {
    selected[id] = true;
    row.classList.add('row-selected');
  }
  updateSelectionBar();
}
function updateSelectionBar() {
  var ids = Object.keys(selected);
  document.getElementById('selection-bar').classList.toggle('visible', ids.length > 0);
  document.getElementById('selection-count').textContent = '已选中 ' + ids.length + ' 项';
}
function commandForSelectedId(id) {
  // 跟"软件接入"表格里的复制命令保持一致，用绝对路径而不是裸 skillctl——
  // 裸命令要求 ~/.skill-library/bin 已经加进 PATH，一个全新终端窗口默认
  // 没有，粘贴直接报 "command not found"，这个坑已经在真实环境里踩过。
  var bin = '~/.skill-library/bin/skillctl ';
  if (selectionMode === 'archive') return bin + 'archive ' + id + ' --apply';
  var row = document.querySelector('#skills-table tbody tr[data-id="' + id + '"]');
  var status = row ? row.dataset.status : '';
  return bin + (status === '已激活' ? 'deactivate ' : 'activate ') + id + ' --apply';
}
function copySelectionCommand() {
  var ids = Object.keys(selected);
  if (ids.length === 0) return;
  var text = ids.map(commandForSelectedId).join('\n');
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text);
  }
  var message = selectionMode === 'archive'
    ? '已复制，请粘贴到终端执行。归档是可恢复的下架，随时能用 restore 恢复。'
    : '已复制，请粘贴到终端执行。';
  showActionToast(message);
}
function showActionToast(message) {
  var toast = document.getElementById('archive-toast');
  toast.textContent = message;
  toast.classList.add('visible');
  clearTimeout(showActionToast._t);
  showActionToast._t = setTimeout(function () { toast.classList.remove('visible'); }, 3200);
}
</script>
</body>
</html>
HTML_TAIL
}

if [ "$APPLY" -ne 1 ]; then
  printf '预演模式，不会生成或替换 dashboard/index.html；确认后运行: %s --apply\n' "$0"
  exit 0
fi

[ -d "$SKILL_LIBRARY_ROOT" ] || {
  printf 'Skill 仓库不存在: %s\n' "$SKILL_LIBRARY_ROOT" >&2
  exit 1
}

mkdir -p "$SKILL_LIBRARY_ROOT/dashboard"
tmp="$(mktemp "$SKILL_LIBRARY_ROOT/dashboard/.index.html.XXXXXX")"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
generate_dashboard > "$tmp"
atomic_replace "$tmp" "$SKILL_LIBRARY_ROOT/dashboard/index.html"
trap - EXIT HUP INT TERM
