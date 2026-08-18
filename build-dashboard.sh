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

# 顶部统计卡片：只留全部/已激活/仓库中三项——这三项能一眼看状态、有明确
# 的后续动作（点行、切筛选、用工具栏三个模式按钮）。原来还有"已归档"和
# "缺失/冲突"两张卡片，拿掉了：前者只是个数字、面板上点不了（没有配套的
# 恢复按钮，仓库这边现在也不再自动保留旧版本了）；后者健康状态下永远是
# 0，真出问题时这张卡片也不会告诉你是哪个 skill、什么原因，还是得跑
# skillctl doctor 看详细诊断——两张卡片都是"能看不能点"，不满足这个面板
# "一眼看状态、一键做操作"的定位。
render_stats_cards() {
  printf '<div class="stat-cards">\n'
  render_status_summary_cards
  render_backup_card
  printf '</div>\n'
}

render_status_summary_cards() {
  local status_output
  status_output="$("$SKILLCTL_BIN" status 2>/dev/null)" || {
    printf '<p class="empty-note">无法读取状态统计。</p>\n'
    return 0
  }

  awk -F '\t' '
    $1 == "全局" { total++; count[$2]++ }
    END {
      printf "<div class=\"stat-card\"><span class=\"stat-value\">%d</span><span class=\"stat-label\" data-i18n=\"statTotal\">全部 Skill</span></div>\n", total + 0
      printf "<div class=\"stat-card stat-active\"><span class=\"stat-value\">%d</span><span class=\"stat-label\" data-i18n=\"statActive\">已激活</span></div>\n", count["已激活"] + 0
      printf "<div class=\"stat-card stat-warehouse\"><span class=\"stat-value\">%d</span><span class=\"stat-label\" data-i18n=\"statWarehouse\">仓库中</span></div>\n", count["仓库中"] + 0
    }
  ' <<< "$status_output"
}

# 备份卡片跟另外三张状态卡是同一批生成的，读的是 skillctl backup status
# 的只读输出——静态快照模式下这张卡本身仍然会显示当时的真实状态（未开启/
# 已同步/待同步），只有卡片里那颗"同步备份"按钮跟 check-updates-btn 一样
# 需要本地服务才能点，静态模式下禁用、不提供复制命令的兜底（原因同
# check-updates：单条命令 skillctl backup sync --apply 本身已经够短，禁用
# 态的 title 提示已经把命令写清楚了，不需要再加一层复制交互）。
render_backup_card() {
  local status_output dirty behind extra_class
  status_output="$("$SKILLCTL_BIN" backup status 2>/dev/null)"

  if printf '%s' "$status_output" | grep -q '还不是 Git 仓库'; then
    printf '<div class="stat-card stat-backup-off">\n<div class="stat-card-body">\n'
    printf '<span class="stat-label" data-i18n="statBackup">GitHub 备份</span>\n'
    printf '<p class="stat-hint"><span data-i18n="backupOffHintPre">终端运行 </span><code class="technical-id">skillctl backup init --apply</code><span data-i18n="backupOffHintPost"> 开启</span></p>\n'
    printf '</div>\n</div>\n'
    return 0
  fi

  dirty="$(printf '%s\n' "$status_output" | grep -oE '未提交改动：[0-9]+' | grep -oE '[0-9]+')"
  behind="$(printf '%s\n' "$status_output" | grep -oE '落后远端：[0-9]+' | grep -oE '[0-9]+')"
  dirty="${dirty:-0}"
  behind="${behind:-0}"

  extra_class=""
  if [ "$dirty" != "0" ] || [ "$behind" != "0" ]; then
    extra_class=" stat-backup-pending"
  fi

  # 之前这里还有一行"已同步/待同步"的大字，跟下面这行数字完全同义、纯属
  # 重复——现在状态只靠云朵图标的颜色（图标颜色由外层 stat-backup/
  # stat-backup-pending 这两个 class 驱动，见上面的 CSS）加这行具体数字
  # 传达，不再用一个大词复述一遍。
  printf '<div class="stat-card stat-backup%s">\n<div class="stat-card-body">\n' "$extra_class"
  printf '<span class="stat-label" data-i18n="statBackup">GitHub 备份</span>\n'
  printf '<p class="stat-hint" data-i18n-template="backupHint" data-dirty="%s" data-behind="%s">未提交 %s 项・落后远端 %s 个提交</p>\n' \
    "$(html_escape "$dirty")" "$(html_escape "$behind")" "$(html_escape "$dirty")" "$(html_escape "$behind")"
  printf '<button type="button" id="backup-sync-btn" class="mode-toggle-btn btn-ghost" data-i18n="btnBackupSync" onclick="runBackupSync()" disabled title="需要本地服务：skillctl dashboard serve" data-i18n-title="tooltipNeedsLive">同步到云端</button>\n'
  printf '</div>\n</div>\n'
}

render_skills_table() {
  local status_map_file profiles_map_file batch_map_file batch_raw_file catalog_id relative_path pfile pname plist target bepoch

  status_map_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-status.XXXXXX")"
  profiles_map_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-profiles.XXXXXX")"
  batch_map_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-batch.XXXXXX")"
  batch_raw_file="$(mktemp "${TMPDIR:-/tmp}/skill-dashboard-batch-raw.XXXXXX")"
  trap 'rm -f "$status_map_file" "$profiles_map_file" "$batch_map_file" "$batch_raw_file"' RETURN

  # "导入批次"：用仓库里每个 skill 目录本身的修改时间聚类，而不是只看日
  # 期——按日期分（之前的做法）在真实数据上验证是错的：8月9日一天里，
  # Lark 系列 27 个技能横跨 19:03:56~19:03:59 四秒，同一天里；4月19日那天
  # 12:14:24 一口气导入了 14 个（Superpowers），12:24:36 又单独导入了另
  # 外 11 个——这两批相隔 10 分钟，按日期分会被错误合并成一天 25 个，用
  # 户根本理不清哪个跟哪个是一套。改成按时间间隔聚类：先按秒级时间戳排
  # 序，相邻两个 skill 目录的修改时间只要间隔不超过 $BATCH_GAP_SECONDS
  # （给单个一个个导入的场景留出容错），就算同一批，超过就切一批新的。
  # 这样 Lark 27 个（4 秒内）会聚成一批，4月19日那两批（隔 10 分钟）会正
  # 确分开——用真实仓库数据核对过，两种已知案例都对得上。
  local BATCH_GAP_SECONDS=120
  : > "$batch_raw_file"
  while IFS="$(printf '\t')" read -r catalog_id relative_path _rest; do
    [ -n "$catalog_id" ] || continue
    target="$(real_dir "$SKILL_LIBRARY_ROOT/$relative_path" 2>/dev/null || true)"
    [ -n "$target" ] && [ -d "$target" ] || continue
    bepoch="$(stat -f "%m" "$target" 2>/dev/null || true)"
    [ -n "$bepoch" ] && printf '%s\t%s\n' "$bepoch" "$catalog_id" >> "$batch_raw_file"
  done < "$CATALOG_FILE"
  sort -n -o "$batch_raw_file" "$batch_raw_file"
  awk -F '\t' -v gap="$BATCH_GAP_SECONDS" '
    BEGIN { batch_no = 0; prev = -999999999 }
    {
      if ($1 - prev > gap) { batch_no++ }
      print $2 "\tbatch" batch_no
      prev = $1
    }
  ' "$batch_raw_file" > "$batch_map_file"

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

  printf '<table id="skills-table"><thead><tr><th data-i18n="thStatus">状态</th><th data-i18n="thName">中文名称</th><th data-i18n="thId">英文 ID</th><th data-i18n="thCategory">分类</th><th data-i18n="thProfiles">所属场景包</th><th data-i18n="thDescription">简介</th></tr></thead><tbody>\n'
  awk -F '\t' -v status_map_file="$status_map_file" -v profiles_map_file="$profiles_map_file" -v batch_map_file="$batch_map_file" '
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
      while ((getline bline < batch_map_file) > 0) {
        split(bline, f, "\t")
        if (f[1] != "") batch_by_id[f[1]] = f[2]
      }
      close(batch_map_file)
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
      batch = (raw_id in batch_by_id) ? batch_by_id[raw_id] : ""
      cls = status_class(raw_status)
      search = tolower(id " " display " " category " " profiles " " description)
      printf "<tr data-search=\"%s\" data-status=\"%s\" data-category=\"%s\" data-id=\"%s\" data-batch=\"%s\" onclick=\"onSkillRowClick(this)\">\n", search, status, category, id, batch
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
  printf '<table><thead><tr><th data-i18n="thProfileName">场景包</th><th data-i18n="thProfileCount">数量</th><th data-i18n="thProfileMembers">成员</th></tr></thead><tbody>\n'
  for pfile in "$PROFILE_DIR"/*; do
    [ -f "$pfile" ] || continue
    pname="$(basename "$pfile")"
    # 数量和成员列表都只数"仓库里真能找到"的——场景包文件里的 id 如果被
    # 删掉了，直接跳过不显示，不显示裸 id 也不显示缺失标记；数量因此
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

# tools.tsv 里除了这份内置列表之外的所有行都是用户自己用"+ 添加平台"
# 加的——注册时（cmd_add_custom_tool）就是直接往这个文件追加一行，没有
# 另外单独记一份"哪些是自定义的"清单，靠这份内置 id 列表做差集，跟
# skillctl 那边写入的逻辑保持同一个真源（tools.tsv 本身），两边不会对
# 不上。这份列表只用来决定"未检测到时要不要隐藏"，不影响别的。
BUILTIN_TOOL_IDS=" codex cursor gemini-cli claude-code kiro trae trae-cn codebuddy qoder windsurf "

render_adapters_section() {
  local adapters_file detect_output id display mode _global_dir _project_dir _cli_command _app_name verification status mode_label mode_label_key command_text is_builtin
  adapters_file="${SKILL_ADAPTERS:-$PACKAGE_ROOT/config/adapters/tools.tsv}"
  [ -f "$adapters_file" ] || { printf '<p class="empty-note">软件适配器配置不存在。</p>\n'; return 0; }

  detect_output="$("$SKILLCTL_BIN" tools detect 2>/dev/null || true)"

  printf '<table><thead><tr><th data-i18n="thTool">软件</th><th data-i18n="thStatus">状态</th><th data-i18n="thToolMode">接入方式</th><th data-i18n="thToolCommand">安全命令</th></tr></thead><tbody>\n'
  while IFS=';' read -r id display mode _global_dir _project_dir _cli_command _app_name verification; do
    [ -n "$id" ] || continue
    case "$id" in \#*) continue ;; esac
    status="$(printf '%s\n' "$detect_output" | awk -F '\t' -v id="$id" '$1 == id { print $2; exit }')"
    [ -n "$status" ] || status="未检测到"
    case "$BUILTIN_TOOL_IDS" in *" $id "*) is_builtin="yes" ;; *) is_builtin="no" ;; esac
    # 内置列表里没装/没连的工具摆在这儿不能点、不能操作，纯属噪音，隐藏
    # 掉（真要查这类信息去 skillctl doctor 看）；但用户自己用"添加平台"
    # 注册的不受这条限制——刚注册完、目录还没建出来时本来就是"未检测
    # 到"，这时候恰恰最需要看见它、拿到连接命令去把它接起来，藏起来才是
    # 真的有问题。
    if [ "$is_builtin" = "yes" ]; then
      case "$status" in
        未检测到|可能是残留目录) continue ;;
      esac
    fi
    if [ "$mode" = "native" ]; then
      mode_label="原生"
      mode_label_key="modeNative"
      command_text="（原生模式，自动共享全局 Skill 目录，无需命令）"
    else
      mode_label="软链"
      mode_label_key="modeLink"
      # 这里的 ~ 是给用户看的字面文本（面板上一键复制的命令），不是要展开
      # 的路径，故意不用 $HOME 拼接。
      # shellcheck disable=SC2088
      command_text="~/.skill-library/bin/skillctl tools connect $id"
      [ "$verification" = "unverified" ] && command_text="$command_text --allow-unverified"
      command_text="$command_text --apply"
    fi
    printf '<tr><td>%s <code class="technical-id">%s</code></td><td><span class="chip %s" data-i18n="%s">%s</span></td><td data-i18n="%s">%s</td><td>' \
      "$(html_escape "$display")" "$(html_escape "$id")" "$(adapter_status_class "$status")" "$(adapter_status_i18n_key "$status")" "$(html_escape "$status")" \
      "$mode_label_key" "$(html_escape "$mode_label")"
    if [ "$mode" = "native" ]; then
      printf '<span class="empty-note" data-i18n="toolNativeHint">%s</span>' "$(html_escape "$command_text")"
    else
      printf '<code class="technical-id">%s</code> <button type="button" class="copy-btn tools-connect-btn" data-i18n="copyBtn" onclick="runToolsConnect(this, %s, %s)">复制</button>' \
        "$(html_escape "$command_text")" "$(js_string_literal "$id")" "$(js_string_literal "$command_text")"
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

adapter_status_i18n_key() {
  case "$1" in
    已检测) printf 'toolDetected\n' ;;
    可能是残留目录) printf 'toolResidual\n' ;;
    *) printf 'toolNotDetected\n' ;;
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
<title>Skill 中央仓库</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #F2F3F5;
    --surface: #FFFFFF;
    --surface-2: #F7F8FA;
    --text: #1F2329;
    --text-muted: #4E5969;
    --border: #E5E6EB;
    --border-strong: #D0D3D6;
    --accent2: #7B61FF;
    --accent2-bg: #F1EDFF;
    --primary: #3370FF;
    --primary-fg: #FFFFFF;
    --primary-bg: #ECF1FF;
    --ring: #3370FF;
    --success: #2BA471;
    --success-bg: #E8F8F1;
    --warning: #FF8800;
    --warning-bg: #FFF2E5;
    --danger: #F54A45;
    --danger-bg: #FEECEB;
    --neutral: #8F959E;
    --neutral-bg: #F0F1F3;
    --shadow-sm: 0 1px 2px rgba(31, 35, 41, 0.06);
    --shadow-md: 0 4px 16px rgba(31, 35, 41, 0.1);
    --radius: 8px;
    --radius-sm: 6px;
  }
  /* 之前只有系统级 prefers-color-scheme 一条路，没有"手动选深色/浅色"的
     开关——现在加主题切换按钮，要让手动选择的优先级压过系统设置：跟随
     系统时这条 media query 生效；手动选了"日间"，用 :not([data-theme=
     "light"]) 把这条规则关掉；手动选了"夜间"，靠下面单独的
     :root[data-theme="dark"] 规则（不受 media query 限制）覆盖，同一份
     token 只维护一次，两个选择器共用同一批变量值，不会出现两处数值不
     同步的问题。 */
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #16171A;
      --surface: #1F2023;
      --surface-2: #26282B;
      --text: #E7E9EA;
      --text-muted: #9DA3AB;
      --border: #33353A;
      --border-strong: #44474D;
      --accent2: #A996FF;
      --accent2-bg: #251E42;
      --primary: #5C8DFF;
      --primary-fg: #0B0F1A;
      --primary-bg: #1B2740;
      --ring: #5C8DFF;
      --success: #4CBD8C;
      --success-bg: #163229;
      --warning: #FFA53D;
      --warning-bg: #3A2A14;
      --danger: #FF6B66;
      --danger-bg: #3A1F1E;
      --neutral: #6B7076;
      --neutral-bg: #2A2C30;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3);
      --shadow-md: 0 4px 18px rgba(0, 0, 0, 0.42);
    }
  }
  :root[data-theme="dark"] {
    --bg: #16171A;
    --surface: #1F2023;
    --surface-2: #26282B;
    --text: #E7E9EA;
    --text-muted: #9DA3AB;
    --border: #33353A;
    --border-strong: #44474D;
    --accent2: #A996FF;
    --accent2-bg: #251E42;
    --primary: #5C8DFF;
    --primary-fg: #0B0F1A;
    --primary-bg: #1B2740;
    --ring: #5C8DFF;
    --success: #4CBD8C;
    --success-bg: #163229;
    --warning: #FFA53D;
    --warning-bg: #3A2A14;
    --danger: #FF6B66;
    --danger-bg: #3A1F1E;
    --neutral: #6B7076;
    --neutral-bg: #2A2C30;
    --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.3);
    --shadow-md: 0 4px 18px rgba(0, 0, 0, 0.42);
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", "Segoe UI", "Microsoft YaHei", sans-serif;
    -webkit-font-smoothing: antialiased;
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }

  /* ---------- app shell: 飞书式左侧导航 + 右侧工作区 ---------- */
  .shell { display: flex; align-items: flex-start; min-height: 100vh; }
  .side-nav {
    width: 224px; flex-shrink: 0; position: sticky; top: 0; height: 100vh; overflow-y: auto;
    background: var(--surface); border-right: 1px solid var(--border);
    padding: 18px 12px; display: flex; flex-direction: column; gap: 20px;
  }
  .side-brand { display: flex; align-items: center; gap: 10px; padding: 2px 6px 16px; border-bottom: 1px solid var(--border); }
  .side-logo {
    width: 30px; height: 30px; border-radius: 8px; background: var(--primary); color: var(--primary-fg);
    display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  }
  .side-brand-text strong { display: block; font-size: 13.5px; line-height: 1.3; }
  .side-brand-text small { display: block; font-size: 11px; color: var(--text-muted); margin-top: 1px; }
  .side-nav nav { display: flex; flex-direction: column; gap: 2px; }
  .side-link {
    display: flex; align-items: center; gap: 9px; padding: 8px 10px; border-radius: var(--radius-sm);
    font-size: 13px; font-weight: 500; color: var(--text-muted); text-decoration: none;
  }
  .side-link .side-link-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--border); flex-shrink: 0; }
  .side-link:hover { background: var(--surface-2); color: var(--text); }
  .side-link.active { background: var(--primary-bg); color: var(--primary); font-weight: 700; }
  .side-link.active .side-link-dot { background: var(--primary); }
  .side-foot { margin-top: auto; padding: 10px 10px 2px; font-size: 11px; color: var(--text-muted); border-top: 1px solid var(--border); }

  .page { flex: 1; min-width: 0; max-width: 1180px; margin: 0 auto; padding: 26px 32px 96px; }

  .page-header {
    display: flex; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; gap: 8px;
    margin-bottom: 22px; padding-bottom: 18px; border-bottom: 1px solid var(--border);
  }
  .header-switches { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
  .theme-switch, .lang-switch {
    display: inline-flex; gap: 2px; padding: 3px; border-radius: 999px;
    background: var(--surface-2); border: 1px solid var(--border); flex-shrink: 0;
  }
  button.theme-switch-btn, button.lang-switch-btn {
    width: 28px; height: 28px; display: flex; align-items: center; justify-content: center;
    border-radius: 999px; border: none; background: transparent; color: var(--text-muted); cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }
  button.lang-switch-btn { font-size: 0.72rem; font-weight: 700; letter-spacing: 0.02em; }
  button.theme-switch-btn:hover, button.lang-switch-btn:hover { color: var(--text); }
  button.theme-switch-btn.active, button.lang-switch-btn.active { background: var(--surface); color: var(--primary); box-shadow: var(--shadow-sm); }
  .section-header-row {
    display: flex; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; gap: 12px;
    margin: 0 0 14px; padding-bottom: 12px; border-bottom: 1px solid var(--border);
  }
  .section-header-row h2 { margin: 0; padding-bottom: 0; border-bottom: none; }
  .section-header-row .subtitle { margin: 4px 0 0; }
  h1 { font-size: 1.55rem; font-weight: 700; margin: 0 0 6px; letter-spacing: -0.01em; }
  .subtitle { color: var(--text-muted); font-size: 0.86rem; margin: 0; }
  .stat-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 24px; }
  .stat-card {
    display: flex; align-items: center; gap: 13px;
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 14px 16px; box-shadow: var(--shadow-sm);
  }
  .stat-card::before {
    content: "◆"; flex-shrink: 0; width: 38px; height: 38px; border-radius: 10px;
    display: flex; align-items: center; justify-content: center; font-size: 15px;
    background: var(--neutral-bg); color: var(--neutral);
  }
  .stat-card .stat-value { display: block; font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; line-height: 1.2; }
  .stat-card .stat-label { display: block; font-size: 0.78rem; color: var(--text-muted); margin-top: 2px; }
  .stat-card.stat-active::before { content: "●"; background: var(--success-bg); color: var(--success); }
  .stat-card.stat-active .stat-value { color: var(--success); }
  .stat-card.stat-warehouse::before { content: "▤"; background: var(--primary-bg); color: var(--primary); }
  .stat-card.stat-backup::before { content: "☁"; background: var(--success-bg); color: var(--success); }
  .stat-card.stat-backup-pending::before { content: "☁"; background: var(--warning-bg); color: var(--warning); }
  .stat-card.stat-backup-off::before { content: "☁"; background: var(--neutral-bg); color: var(--neutral); }
  .stat-card-body { flex: 1; min-width: 0; }
  .stat-hint { font-size: 0.72rem; color: var(--text-muted); margin: 4px 0 6px; line-height: 1.4; }
  .stat-card-body button.mode-toggle-btn { margin-top: 2px; }
  section {
    background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 18px 20px; margin-bottom: 20px; box-shadow: var(--shadow-sm); scroll-margin-top: 16px;
  }
  h2 { font-size: 0.95rem; font-weight: 700; margin: 0 0 14px; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
  section > h2::before, .section-header-row h2::before {
    content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 50%;
    background: var(--primary); margin-right: 8px; vertical-align: middle;
  }
  .controls { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 14px; }
  .search-field { position: relative; display: inline-flex; align-items: center; }
  .search-field::before {
    content: "⌕"; position: absolute; left: 11px; font-size: 13px; color: var(--text-muted); pointer-events: none;
  }
  input[type=search] {
    padding: 7px 12px 7px 30px; border-radius: 999px; border: 1px solid var(--border);
    background: var(--surface-2); color: var(--text); font-size: 0.85rem; width: 260px;
  }
  select {
    padding: 6px 10px; border-radius: var(--radius-sm); border: 1px solid var(--border-strong);
    background: var(--surface-2); color: var(--text); font-size: 0.85rem; font-weight: 600;
  }
  input[type=search]:focus, select:focus, button:focus-visible {
    outline: 2px solid var(--ring); outline-offset: 1px;
  }
  table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
  th {
    position: sticky; top: 0; text-align: left; padding: 9px 12px; background: var(--surface-2);
    color: var(--text-muted); font-weight: 600; font-size: 0.76rem; letter-spacing: 0.02em;
    border-bottom: 1px solid var(--border); border-right: 1px solid var(--border); z-index: 1; white-space: nowrap;
  }
  th:last-child { border-right: none; }
  td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); border-right: 1px solid var(--border); vertical-align: top; }
  td:last-child { border-right: none; }
  #skills-table tbody tr:hover { background: var(--primary-bg); }
  code.technical-id {
    color: var(--text-muted); font-size: 0.85em; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .chip { display: inline-flex; align-items: center; gap: 5px; padding: 2px 9px 2px 7px; border-radius: 4px; font-size: 0.74rem; font-weight: 600; white-space: nowrap; }
  .chip::before { content: ""; width: 5px; height: 5px; border-radius: 50%; background: currentColor; flex-shrink: 0; }
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
    font-size: 0.78rem; font-weight: 600; padding: 5px 11px; cursor: pointer; border-radius: var(--radius-sm);
    border: 1px solid var(--border); background: var(--surface); color: var(--text); transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease, filter 0.15s ease;
  }
  /* 三个模式按钮平时就带各自的色调背景（不是只在 hover/active 才有颜色），
     跟仓库那几张统计卡片同一套 -bg token，保证在浅色和深色主题下都有
     足够对比度，不会跟周围的中性灰按钮混在一起看不出来是三个独立操作。 */
  button.mode-toggle-btn[data-mode="activate"] { background: var(--primary-bg); border: 1px solid var(--primary); color: var(--primary); }
  button.mode-toggle-btn[data-mode="activate"]:hover { filter: brightness(1.12); }
  button.mode-toggle-btn[data-mode="activate"].active { background: var(--primary); border-color: var(--primary); color: var(--primary-fg); }
  button.mode-toggle-btn[data-mode="deactivate"] { background: var(--warning-bg); border: 1px solid var(--warning); color: var(--warning); }
  button.mode-toggle-btn[data-mode="deactivate"]:hover { filter: brightness(1.12); }
  button.mode-toggle-btn[data-mode="deactivate"].active { background: var(--warning); border-color: var(--warning); color: #fff; }
  button.mode-toggle-btn[data-mode="delete"] { background: var(--danger-bg); border: 1px solid var(--danger); color: var(--danger); }
  button.mode-toggle-btn[data-mode="delete"]:hover { filter: brightness(1.12); }
  button.mode-toggle-btn[data-mode="delete"].active { background: var(--danger); border-color: var(--danger); color: #fff; }
  /* 三个模式按钮改的是「哪些行会被操作」，从 GitHub 导入/本地拖拽导入/检查更新
     是完全不同类别的动作（往仓库里加东西、查更新），混排在同一行容易被当成
     同一组。用竖线分隔 + 单独的按钮观感区分两类。 */
  /* margin-left: auto 把这一组推到 .controls 这一行的最右侧——跟前面
     "对选中行做操作"那一组隔开，不管窗口多宽，视觉上都固定贴在卡片右
     边，不会随内容宽度巧合地停在中间某个位置。 */
  .controls-secondary { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-left: auto; padding-left: 12px; border-left: 1px solid var(--border); }
  /* 飞书按 App 类型区分颜色（文档蓝、多维表格紫……），这里借用同一套逻辑：
     导入/同步类动作统一用紫色调，跟"三种模式"的蓝/橙/红明确区分开，同时
     跟仓库列表用的中性灰按钮也不会混在一起看不出来能点。 */
  button.mode-toggle-btn.btn-ghost {
    background: var(--accent2-bg); border: 1px solid var(--accent2); color: var(--accent2);
  }
  button.mode-toggle-btn.btn-ghost:hover { filter: brightness(1.12); }
  button.mode-toggle-btn.btn-primary {
    background: var(--primary); border: 1px solid var(--primary); color: var(--primary-fg); font-weight: 700;
  }
  button.mode-toggle-btn.btn-primary:hover { filter: brightness(1.1); }
  button.mode-toggle-btn.btn-primary:disabled { background: var(--primary); border-color: var(--primary); color: var(--primary-fg); opacity: 0.45; }
  #skills-table tbody tr.row-selectable { cursor: pointer; }
  #skills-table tbody tr.row-disabled { opacity: 0.4; }
  #skills-section.mode-delete #skills-table tbody tr.row-selectable:hover { background: var(--danger-bg); }
  #skills-section.mode-delete #skills-table tbody tr.row-selected { outline: 2px solid var(--danger); outline-offset: -2px; background: var(--danger-bg); }
  #skills-section.mode-activate #skills-table tbody tr.row-selectable:hover { background: var(--primary-bg); }
  #skills-section.mode-activate #skills-table tbody tr.row-selected { outline: 2px solid var(--primary); outline-offset: -2px; background: var(--primary-bg); }
  #skills-section.mode-deactivate #skills-table tbody tr.row-selectable:hover { background: var(--warning-bg); }
  #skills-section.mode-deactivate #skills-table tbody tr.row-selected { outline: 2px solid var(--warning); outline-offset: -2px; background: var(--warning-bg); }
  .selection-bar {
    position: fixed; left: 0; right: 0; bottom: 0; padding: 14px 24px; background: var(--surface); color: var(--text);
    border-top: 1px solid var(--border); box-shadow: 0 -4px 16px rgba(31, 35, 41, 0.08);
    display: flex; align-items: center; gap: 12px; justify-content: flex-end;
    transform: translateY(100%); transition: transform 0.15s ease; z-index: 20;
  }
  .selection-bar.visible { transform: translateY(0); }
  .selection-bar .selection-count { margin-right: auto; font-size: 0.88rem; color: var(--text-muted); font-weight: 500; }
  button.selection-confirm-btn {
    color: #fff; border-radius: var(--radius-sm);
    padding: 9px 18px; font-size: 0.88rem; font-weight: 600; cursor: pointer; transition: filter 0.15s ease;
  }
  button.selection-confirm-btn[data-mode="delete"] { background: var(--danger); border: 1px solid var(--danger); }
  button.selection-confirm-btn[data-mode="activate"] { background: var(--primary); color: var(--primary-fg); border: 1px solid var(--primary); }
  button.selection-confirm-btn[data-mode="deactivate"] { background: var(--warning); color: #fff; border: 1px solid var(--warning); }
  button.selection-confirm-btn:disabled { opacity: 0.6; cursor: not-allowed; }
  button.selection-confirm-btn:hover { filter: brightness(1.08); }
  .action-toast {
    position: fixed; bottom: 72px; right: 24px; background: var(--success); color: #fff; padding: 11px 16px;
    border-radius: var(--radius-sm); font-size: 0.85rem; max-width: 360px; box-shadow: var(--shadow-md);
    opacity: 0; transform: translateY(8px); transition: opacity 0.15s ease, transform 0.15s ease; pointer-events: none; z-index: 30;
  }
  .action-toast.visible { opacity: 1; transform: translateY(0); }
  button.mode-toggle-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .gh-modal-overlay {
    position: fixed; inset: 0; background: rgba(31, 35, 41, 0.5); z-index: 50;
    display: flex; align-items: flex-start; justify-content: center; padding: 6vh 16px; overflow-y: auto;
  }
  .gh-modal-overlay.hidden { display: none; }
  .gh-modal {
    background: var(--surface); color: var(--text); border-radius: var(--radius); box-shadow: var(--shadow-md);
    width: min(560px, 100%); padding: 22px 24px; border: 1px solid var(--border);
  }
  .gh-modal-header { display: flex; align-items: flex-start; justify-content: space-between; margin-bottom: 4px; }
  .gh-modal-header h2 { font-size: 1.1rem; margin: 0; }
  .gh-modal-subtitle { font-size: 0.8rem; color: var(--text-muted); margin: 2px 0 16px; }
  .gh-modal-close { background: none; border: none; font-size: 1.3rem; line-height: 1; cursor: pointer; color: var(--text-muted); padding: 2px 8px; border-radius: var(--radius-sm); }
  .gh-modal-close:hover { color: var(--text); background: var(--surface-2); }
  .gh-steps { display: flex; gap: 6px; margin-bottom: 18px; font-size: 0.76rem; color: var(--text-muted); flex-wrap: wrap; }
  .gh-steps .gh-step { padding: 4px 10px; border-radius: 999px; background: var(--surface-2); }
  .gh-steps .gh-step.active { background: var(--primary-bg); color: var(--primary); font-weight: 600; }
  .gh-steps .gh-step.done { background: var(--success-bg); color: var(--success); }
  .gh-field { margin-bottom: 12px; }
  .gh-field label { display: block; font-size: 0.82rem; color: var(--text-muted); margin-bottom: 4px; }
  .gh-field input[type="text"] {
    width: 100%; padding: 9px 11px; border-radius: var(--radius-sm); border: 1px solid var(--border);
    background: var(--bg); color: var(--text); font-size: 0.88rem; font-family: inherit;
  }
  .gh-field input[type="text"]:focus { outline: 2px solid var(--ring); outline-offset: 1px; }
  .gh-field .gh-hint { font-size: 0.74rem; color: var(--text-muted); margin-top: 4px; }
  .gh-checkbox-row { display: flex; align-items: center; gap: 8px; font-size: 0.85rem; margin: 10px 0; }
  .gh-checkbox-row input { margin: 0; }
  .gh-box {
    background: var(--surface-2); border-radius: var(--radius-sm); padding: 12px 14px; font-size: 0.8rem;
    white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    max-height: 320px; overflow-y: auto; border: 1px solid var(--border); margin-bottom: 14px;
  }
  .gh-box.ok { border-color: var(--success); }
  .gh-box.fail { border-color: var(--danger); }
  .gh-box.info { border-color: var(--primary); }
  .gh-path-picks { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
  label.gh-path-pick-cb {
    display: flex; align-items: center; gap: 6px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.78rem; padding: 6px 12px;
    border-radius: 999px; border: 1px solid var(--border-strong); background: var(--surface); color: var(--text);
    cursor: pointer; transition: filter 0.15s ease, border-color 0.15s ease, background 0.15s ease, color 0.15s ease;
  }
  label.gh-path-pick-cb input { margin: 0; }
  label.gh-path-pick-cb:hover { border-color: var(--primary); }
  label.gh-path-pick-cb.checked { border-color: var(--primary); background: var(--primary-bg); color: var(--primary); }
  .batch-list { display: flex; flex-direction: column; gap: 6px; margin-bottom: 6px; max-height: 320px; overflow-y: auto; }
  .batch-row {
    display: flex; align-items: center; gap: 10px; padding: 8px 12px;
    border: 1px solid var(--border); border-radius: var(--radius-sm); background: var(--surface-2);
  }
  .batch-row code.technical-id { flex: 1; background: transparent; }
  .batch-pill { font-size: 0.72rem; font-weight: 600; padding: 2px 9px; border-radius: 999px; white-space: nowrap; }
  .batch-pill.pending { background: var(--neutral-bg); color: var(--neutral); }
  .batch-pill.running { background: var(--primary-bg); color: var(--primary); }
  .batch-pill.ok { background: var(--success-bg); color: var(--success); }
  .batch-pill.fail { background: var(--danger-bg); color: var(--danger); }
  .batch-script-warn { font-size: 0.72rem; color: var(--warning); white-space: nowrap; }
  .gh-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 4px; }
  button.gh-btn { padding: 9px 16px; border-radius: var(--radius-sm); font-size: 0.85rem; font-weight: 600; cursor: pointer; border: 1px solid transparent; transition: filter 0.15s ease; }
  button.gh-btn:hover { filter: brightness(1.08); }
  button.gh-btn:disabled { opacity: 0.55; cursor: not-allowed; filter: none; }
  button.gh-btn-primary { background: var(--primary); color: var(--primary-fg); }
  button.gh-btn-secondary { background: var(--surface-2); color: var(--text); border-color: var(--border); }
  .up-dropzone {
    border: 2px dashed var(--border); border-radius: var(--radius); padding: 36px 16px; text-align: center;
    color: var(--text-muted); font-size: 0.88rem; margin-bottom: 12px; transition: border-color 0.15s ease, background 0.15s ease;
  }
  .up-dropzone.dragover { border-color: var(--primary); background: var(--primary-bg); color: var(--text); }
  .up-dropzone .up-dropzone-hint { font-size: 0.76rem; margin-top: 6px; }
  .up-picked-name { font-size: 0.82rem; color: var(--text); margin: 4px 0 12px; word-break: break-all; }
  .update-badge {
    display: inline-block; margin-left: 6px; padding: 2px 8px; border-radius: 999px; font-size: 0.7rem;
    font-weight: 600; vertical-align: 1px; cursor: default;
  }
  .update-badge.available { background: var(--warning-bg); color: var(--warning); }
  .update-badge.modified { background: var(--neutral-bg); color: var(--neutral); }
  .update-badge.error { background: var(--danger-bg); color: var(--danger); }
  @media (max-width: 860px) {
    .shell { flex-direction: column; }
    .side-nav { position: static; width: 100%; height: auto; flex-direction: row; align-items: center; overflow-x: auto; gap: 14px; }
    .side-brand { border-bottom: none; padding: 0; }
    .side-nav nav { flex-direction: row; }
    .page { padding: 20px 16px 72px; max-width: 100%; }
  }
</style>
</head>
<body>
<script>
// 主题选择要在渲染前就应用，不然会先按系统主题闪一下再跳到用户存的选
// 择——放进 body 最前面、其余脚本和内容之前同步执行，避免这次内容闪烁。
(function () {
  try {
    var t = localStorage.getItem('skill-dashboard-theme');
    if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
  } catch (e) {}
})();
</script>
<script>
// 语言选择同样要在渲染前应用，跟主题那段是同一个道理——避免先按中文（页面
// 生成时烤进 HTML 的默认语言）闪一下再切到用户存的英文选择。这里只标记
// data-lang，真正把每个 [data-i18n] 元素的文字换掉的 applyLanguage() 得等
// DOM 解析完才能跑，在下面的主脚本里、updateThemeSwitchUI() 那个位置调用。
(function () {
  try {
    var l = localStorage.getItem('skill-dashboard-lang');
    if (l === 'en') document.documentElement.dataset.lang = 'en';
  } catch (e) {}
})();
</script>
<div class="shell">
  <aside class="side-nav">
    <div class="side-brand">
      <span class="side-logo"><svg width="18" height="18" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"><rect x="3" y="3" width="6" height="6" rx="1.5"/><rect x="11" y="3" width="6" height="6" rx="1.5" opacity="0.55"/><rect x="3" y="11" width="6" height="6" rx="1.5" opacity="0.55"/><rect x="11" y="11" width="6" height="6" rx="1.5"/></svg></span>
      <div class="side-brand-text"><strong data-i18n="brandTitle">Skill 仓库</strong><small data-i18n="brandSubtitle">本地工作台</small></div>
    </div>
    <nav id="side-nav-links">
      <a class="side-link" href="#top" data-target="top"><span class="side-link-dot"></span><span data-i18n="navOverview">总览</span></a>
      <a class="side-link" href="#skills-section" data-target="skills-section"><span class="side-link-dot"></span><span data-i18n="navSkills">Skill 列表</span></a>
      <a class="side-link" href="#profiles-section" data-target="profiles-section"><span class="side-link-dot"></span><span data-i18n="navProfiles">场景包</span></a>
      <a class="side-link" href="#adapters-section" data-target="adapters-section"><span class="side-link-dot"></span><span data-i18n="navAdapters">软件接入</span></a>
    </nav>
    <div class="side-foot">skillctl dashboard</div>
  </aside>
<div class="page">
<div id="top"></div>
HTML_HEAD

  printf '<header class="page-header">\n<div>\n'
  printf '<h1 data-i18n="h1Title">Skill 中央仓库</h1>\n'
  printf '<p class="subtitle" id="build-subtitle"><span data-i18n="genAtPre">生成时间：</span>%s<span data-i18n="genAtPost"> ・ 本页为静态快照，需重新运行 </span><code class="technical-id">skillctl dashboard build --apply</code><span data-i18n="genAtPost2"> 才会刷新</span></p>\n' "$(html_escape "$generated_at")"
  printf '<p class="subtitle"><span data-i18n="skillFolderPre">Skill 文件夹：</span><code class="technical-id">%s</code> <button type="button" class="copy-btn" data-i18n="copyBtn" onclick="copyCommand(this, %s)">复制</button><span data-i18n="skillFolderPost">（粘贴到 Finder"前往文件夹"可直接跳转，快捷键 Cmd+Shift+G）</span></p>\n' \
    "$(html_escape "$SKILL_LIBRARY_ROOT/skills")" "$(js_string_literal "$SKILL_LIBRARY_ROOT/skills")"
  printf '</div>\n'
  printf '<div class="header-switches">\n'
  printf '<div class="lang-switch" id="lang-switch" role="group" aria-label="语言">\n'
  printf '<button type="button" class="lang-switch-btn" data-lang-choice="zh" onclick="setLangChoice(this.dataset.langChoice)" title="中文">中</button>\n'
  printf '<button type="button" class="lang-switch-btn" data-lang-choice="en" onclick="setLangChoice(this.dataset.langChoice)" title="English">EN</button>\n'
  printf '</div>\n'
  printf '<div class="theme-switch" id="theme-switch" role="group" aria-label="外观">\n'
  printf '<button type="button" class="theme-switch-btn" data-theme-choice="light" onclick="setThemeChoice(this.dataset.themeChoice)" title="日间模式" data-i18n-title="themeLight"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg></button>\n'
  printf '<button type="button" class="theme-switch-btn" data-theme-choice="dark" onclick="setThemeChoice(this.dataset.themeChoice)" title="夜间模式" data-i18n-title="themeDark"><svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z"/></svg></button>\n'
  printf '<button type="button" class="theme-switch-btn" data-theme-choice="system" onclick="setThemeChoice(this.dataset.themeChoice)" title="跟随系统" data-i18n-title="themeSystem"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></svg></button>\n'
  printf '</div>\n'
  printf '</div>\n'
  printf '</header>\n'

  render_stats_cards

  printf '<section id="skills-section">\n<h2 data-i18n="sectionSkills">Skill 列表</h2>\n'
  printf '<div class="controls">\n'
  printf '<input type="search" id="skill-search" placeholder="按中文名称、别名或英文 ID 搜索…" data-i18n-placeholder="searchPlaceholder" oninput="applyFilters()">\n'
  printf '<select id="status-filter" onchange="applyFilters()"><option value="" data-i18n="filterAll">全部状态</option><option value="已激活" data-i18n="statActive">已激活</option><option value="仓库中" data-i18n="statWarehouse">仓库中</option></select>\n'
  printf '<button type="button" id="activate-mode-btn" class="mode-toggle-btn" data-mode="activate" data-i18n="modeActivate" onclick="toggleSelectionMode(%s)">常驻模式</button>\n' "$(js_string_literal activate)"
  printf '<button type="button" id="deactivate-mode-btn" class="mode-toggle-btn" data-mode="deactivate" data-i18n="modeDeactivate" onclick="toggleSelectionMode(%s)">移入仓库模式</button>\n' "$(js_string_literal deactivate)"
  printf '<button type="button" id="delete-mode-btn" class="mode-toggle-btn" data-mode="delete" data-i18n="modeDelete" onclick="toggleSelectionMode(%s)">删除模式</button>\n' "$(js_string_literal delete)"
  printf '<div class="controls-secondary">\n'
  printf '<button type="button" id="github-import-btn" class="mode-toggle-btn btn-ghost" data-i18n="btnGithubImport" onclick="openGithubWizard()" disabled title="需要本地服务：skillctl dashboard serve" data-i18n-title="tooltipNeedsLive">从 GitHub 导入</button>\n'
  printf '<button type="button" id="upload-import-btn" class="mode-toggle-btn btn-ghost" data-i18n="btnUploadImport" onclick="openUploadWizard()" disabled title="需要本地服务：skillctl dashboard serve" data-i18n-title="tooltipNeedsLive">本地拖拽导入</button>\n'
  printf '<button type="button" id="check-updates-btn" class="mode-toggle-btn btn-ghost" data-i18n="btnCheckUpdates" onclick="runCheckUpdates()" disabled title="需要本地服务：skillctl dashboard serve" data-i18n-title="tooltipNeedsLive">检查更新</button>\n'
  printf '</div>\n'
  printf '</div>\n'
  render_skills_table
  printf '</section>\n'

  printf '<div class="selection-bar" id="selection-bar">\n'
  printf '<span class="selection-count" id="selection-count">已选中 0 项</span>\n'
  printf '<button type="button" class="selection-confirm-btn" id="selection-confirm-btn" onclick="copySelectionCommand()">复制命令</button>\n'
  printf '</div>\n'
  printf '<div class="action-toast" id="action-toast"></div>\n'

  printf '<div class="gh-modal-overlay hidden" id="gh-modal-overlay">\n'
  printf '<div class="gh-modal">\n'
  printf '<div class="gh-modal-header"><h2>GitHub 仓库导入</h2><button type="button" class="gh-modal-close" onclick="closeGithubWizard()">×</button></div>\n'
  printf '<p class="gh-modal-subtitle">从中央仓库启动共享的 GitHub 仓库导入向导</p>\n'
  printf '<div class="gh-steps" id="gh-steps"></div>\n'
  printf '<div id="gh-body"></div>\n'
  printf '</div>\n</div>\n'

  printf '<div class="gh-modal-overlay hidden" id="up-modal-overlay">\n'
  printf '<div class="gh-modal">\n'
  printf '<div class="gh-modal-header"><h2>本地拖拽导入</h2><button type="button" class="gh-modal-close" onclick="closeUploadWizard()">×</button></div>\n'
  printf '<p class="gh-modal-subtitle">把本地 Skill 文件夹或打包好的 .zip 直接拖进来收编进中央仓库</p>\n'
  printf '<div class="gh-steps" id="up-steps"></div>\n'
  printf '<div id="up-body"></div>\n'
  printf '</div>\n</div>\n'

  printf '<section id="profiles-section">\n<h2 data-i18n="sectionProfiles">场景包</h2>\n'
  render_profiles_section
  printf '</section>\n'

  printf '<section id="adapters-section">\n'
  printf '<div class="section-header-row"><h2 data-i18n="sectionAdapters">软件接入</h2>'
  printf '<button type="button" id="add-tool-btn" class="mode-toggle-btn btn-primary" data-i18n="btnAddTool" onclick="openAddToolWizard()" disabled title="需要本地服务：skillctl dashboard serve" data-i18n-title="tooltipNeedsLive">+ 添加平台</button></div>\n'
  render_adapters_section
  printf '</section>\n'

  printf '<div class="gh-modal-overlay hidden" id="tool-modal-overlay">\n'
  printf '<div class="gh-modal">\n'
  printf '<div class="gh-modal-header"><h2>添加自定义平台</h2><button type="button" class="gh-modal-close" onclick="closeAddToolWizard()">×</button></div>\n'
  printf '<p class="gh-modal-subtitle">注册一个内置列表之外的平台，添加后需要再手动跑一次连接命令（首次连接需要 --allow-unverified）。</p>\n'
  printf '<div class="gh-field"><label>平台名称</label><input type="text" id="tool-name-input" placeholder="例如：QClaw" oninput="onToolNameInput()"></div>\n'
  printf '<div class="gh-field"><label>技能目录路径</label><input type="text" id="tool-path-input" placeholder="例如：~/.qclaw/skills/" oninput="this.dataset.autofilled=%s"><div class="gh-hint">根据平台名称自动生成，可自由修改</div></div>\n' "$(js_string_literal no)"
  printf '<div id="tool-add-result"></div>\n'
  printf '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="closeAddToolWizard()">取消</button>'
  printf '<button type="button" class="gh-btn gh-btn-primary" id="tool-add-btn" onclick="submitAddTool()">添加</button></div>\n'
  printf '</div>\n</div>\n'

  printf '</div>\n'
  printf '</div>\n'

  cat <<'HTML_TAIL'
<script>
// window.__DASHBOARD_LIVE__ 只在 `skillctl dashboard serve` 启动的本地服务
// 环境下由服务端注入（见 dashboard-server.py）；双击打开的静态文件里这个
// 全局变量不存在，LIVE 为 null，走原来的"复制命令到剪贴板"这条兼容路径。
var LIVE = window.__DASHBOARD_LIVE__ || null;
// 生成时间提示原本不管 LIVE 与否都写死同一句话，实际上 dashboard-server.py
// 的 do_GET 每次请求都会先 `dashboard build --apply` 重新生成再返回，本页
// 在服务模式下并不是"静态快照"，按钮也是直接生效——这里按 LIVE 状态纠正
// 一次文案，双击打开的静态文件里 LIVE 为空，保持原来"需要重新 build 才
// 刷新"的措辞不变。
if (LIVE) {
  var subtitleEl = document.getElementById('build-subtitle');
  if (subtitleEl) {
    // 不直接在这里写死中文塞进 textContent——这段代码跑在 I18N/t()/
    // applyLanguage() 定义之前（脚本靠前的位置，LIVE 检测本来就要尽早
    // 跑），这时候调用 t() 会因为 I18N 这个 var 还没执行到赋值那行而
    // 读到 undefined。只打上 data-i18n 标记，实际文字交给脚本末尾统一
    // 跑一次的 applyLanguage() 去填——那时候 I18N 已经就绪，语言切换时
    // 也会走同一条路径自动刷新，不用另外写一份逻辑。
    subtitleEl.dataset.i18n = 'liveSubtitle';
  }
  // GitHub 导入向导需要本地服务真正执行 clone + skillctl import-github——
  // 静态快照没法预览一个还没下载下来的仓库，所以这个按钮只在 LIVE 下开放，
  // 跟别的按钮"静态模式退化成复制命令"不是一回事，没有等价的静态兜底。
  var ghBtn = document.getElementById('github-import-btn');
  if (ghBtn) {
    ghBtn.disabled = false;
    ghBtn.title = '';
  }
  var upBtn = document.getElementById('upload-import-btn');
  if (upBtn) {
    upBtn.disabled = false;
    upBtn.title = '';
  }
  var cuBtn = document.getElementById('check-updates-btn');
  if (cuBtn) {
    cuBtn.disabled = false;
    cuBtn.title = '';
  }
  var atBtn = document.getElementById('add-tool-btn');
  if (atBtn) {
    atBtn.disabled = false;
    atBtn.title = '';
  }
  var bkBtn = document.getElementById('backup-sync-btn');
  if (bkBtn) {
    bkBtn.disabled = false;
    bkBtn.title = '';
  }
  // "软件接入"表格里每行的复制按钮，LIVE 模式下功能从"复制命令"变成"直接
  // 帮你连接"——data-i18n 改成 btnConnect 这个 key，实际文字由脚本末尾统一
  // 跑的 applyLanguage() 去填（同样是因为这里跑得比 I18N 字典赋值早，见
  // liveSubtitle 那段注释里的解释，不重复）。
  document.querySelectorAll('.tools-connect-btn').forEach(function (btn) {
    btn.dataset.i18n = 'btnConnect';
  });
}
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
// 三种点选模式共用同一套选中态和底部浮条，互斥——切一个会自动关掉另一个
// 并清空选中：
//   'activate'/'deactivate' 各自只认一种目标状态（仓库中/已激活），进入
//   模式时自动把上面的状态筛选框也切到对应状态、且只有匹配状态的行能被
//   选中（不匹配的行标 row-disabled，就算用户手动把筛选框改回"全部"也
//   选不中——双重保险，不是互相替代）。这样按钮上的动作永远是单一确定
//   的（"激活" / "移动到仓库中"），不需要再按每一行当前状态分别判断。
//   'delete' 不限制状态，选中的每一项固定生成"先 deactivate 再挪进废纸
//   篓"的命令序列（删除=移到废纸篓，可反悔，不是永久 rm）。
var selectionMode = null;
var selected = {};
var MODE_BUTTON_IDS = { delete: 'delete-mode-btn', activate: 'activate-mode-btn', deactivate: 'deactivate-mode-btn' };
// 文字本身现在从 I18N 字典按语言取（见下面 MODE_LABEL_KEYS/t()），这几个
// 只保留"mode -> key 名字"这层映射，不再直接存中文。MODE_TARGET_STATUS
// 例外：它比对的是表格行的 data-status，那个属性本身没有汉化（见文件顶部
// I18N 那段注释——表格内容不在翻译范围内），所以这里必须继续是中文字面量，
// 不能跟着换成 key。
var MODE_LABEL_KEYS = { delete: 'modeDelete', activate: 'modeActivate', deactivate: 'modeDeactivate' };
var MODE_TARGET_STATUS = { activate: '仓库中', deactivate: '已激活' }; // delete 没有限制，不在这里列
function modeLabel(mode) { return t(MODE_LABEL_KEYS[mode]); }
function confirmText(mode) {
  var prefix = LIVE ? 'confirmLive' : 'confirmStatic';
  return t(prefix + mode.charAt(0).toUpperCase() + mode.slice(1));
}
function toggleSelectionMode(mode) {
  var nextMode = (selectionMode === mode) ? null : mode;
  if (selectionMode) {
    var prevBtn = document.getElementById(MODE_BUTTON_IDS[selectionMode]);
    prevBtn.classList.remove('active');
    prevBtn.textContent = modeLabel(selectionMode);
    document.getElementById('skills-section').classList.remove('mode-' + selectionMode);
  }
  selected = {};
  selectionMode = nextMode;
  var targetStatus = selectionMode ? MODE_TARGET_STATUS[selectionMode] : null;
  var rows = document.querySelectorAll('#skills-table tbody tr');
  rows.forEach(function (row) {
    row.classList.remove('row-selected');
    if (!selectionMode) {
      row.classList.remove('row-selectable', 'row-disabled');
      return;
    }
    var eligible = !targetStatus || row.dataset.status === targetStatus;
    row.classList.toggle('row-selectable', eligible);
    row.classList.toggle('row-disabled', !eligible);
  });
  if (selectionMode) {
    var btn = document.getElementById(MODE_BUTTON_IDS[selectionMode]);
    btn.classList.add('active');
    btn.textContent = t('modeExitPrefix') + modeLabel(selectionMode);
    document.getElementById('skills-section').classList.add('mode-' + selectionMode);
    var confirmBtn = document.getElementById('selection-confirm-btn');
    confirmBtn.dataset.mode = selectionMode;
    confirmBtn.textContent = confirmText(selectionMode);
  }
  // 目标状态筛选：进入 activate/deactivate 模式时自动把状态下拉框切到
  // 对应状态，帮用户把不相关的行先隐藏掉；退出模式（含切到 delete）时
  // 恢复成"全部状态"。这只是体验上的引导，真正的选中限制看上面的
  // row-disabled，不依赖这个下拉框此刻的取值。
  var filterSelect = document.getElementById('status-filter');
  filterSelect.value = targetStatus || '';
  applyFilters();
  updateSelectionBar();
}
function onSkillRowClick(row) {
  if (!selectionMode) return;
  if (row.classList.contains('row-disabled')) return;
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
  document.getElementById('selection-count').textContent = t('selectionCount').replace('{n}', ids.length);
}
function commandForSelectedId(id) {
  // 跟"软件接入"表格里的复制命令保持一致，用绝对路径而不是裸 skillctl——
  // 裸命令要求 ~/.skill-library/bin 已经加进 PATH，一个全新终端窗口默认
  // 没有，粘贴直接报 "command not found"，这个坑已经在真实环境里踩过。
  var bin = '~/.skill-library/bin/skillctl ';
  if (selectionMode === 'delete') {
    // 以前这里手写"deactivate + osascript 挪废纸篓"两行，漏了清理
    // config/aliases.tsv 里那一行记录，删得越多这个文件积攒的死行越多。
    // skillctl delete 把停用/挪废纸篓/重建 catalog/清 aliases 这四步收进
    // 一个命令，这里跟本地服务模式（dashboard-server.py 的 /action delete
    // 分支）现在调用的是同一处实现，不会再各漏一遍。
    return bin + 'delete ' + id + ' --apply';
  }
  // activate/deactivate 模式下，能被选中的行本身已经被限制成只有目标状态
  // 那一种（见 toggleSelectionMode 的 row-disabled 逻辑），selectionMode
  // 的名字本身就是唯一要执行的动作，不用再看这一行当前状态。
  return bin + selectionMode + ' ' + id + ' --apply';
}
function actionForSelectedId(id) {
  return selectionMode; // 'delete' / 'activate' / 'deactivate'，跟服务端约定的 action 名字一致
}
// 只在 delete 模式下用：删除前看选中项是不是"打包批次"的一部分
// （data-batch，见 build-dashboard.sh 里 batch_map_file 那段注释——按仓库
// 目录修改时间的间隔聚类，不是简单按日期分，比如 Superpowers 那 14 个、
// khazix-skills 那 3 个都是靠这个信号发现是一整套的）。同批还有没选中
// 的，弹窗提醒、问要不要一起选上；不自动静默带走，用户在弹窗里选"取消"
// 就还是只处理原来选的那些。两条执行路径（本地服务直接执行 / 复制命令
// 到终端）共用这个检查，不是只有本地服务模式才提醒。
function offerBatchSiblings() {
  var ids = Object.keys(selected);
  var batches = {};
  ids.forEach(function (id) {
    var row = document.querySelector('#skills-table tbody tr[data-id="' + id + '"]');
    var batch = row ? row.dataset.batch : '';
    if (batch) batches[batch] = true;
  });
  var siblings = [];
  Object.keys(batches).forEach(function (batch) {
    document.querySelectorAll('#skills-table tbody tr[data-batch="' + batch + '"]').forEach(function (row) {
      var sid = row.dataset.id;
      if (sid && !selected[sid] && siblings.indexOf(sid) === -1) siblings.push(sid);
    });
  });
  if (siblings.length === 0) return;
  var msg = '你选中的 Skill 里，有几个当初是跟别的 Skill 一起打包导入的，很可能是同一整套。\n' +
    '同一批里还有 ' + siblings.length + ' 个没被选中：\n' + siblings.join('、') +
    '\n\n要一起选中删除吗？（点"取消"就只处理你刚才选的那些）';
  if (confirm(msg)) {
    siblings.forEach(function (sid) {
      selected[sid] = true;
      var r = document.querySelector('#skills-table tbody tr[data-id="' + sid + '"]');
      if (r) r.classList.add('row-selected');
    });
    updateSelectionBar();
  }
}
// 只在 dashboard-server.py 起的本地服务下才会被调用——LIVE 非空才会走
// 到这里。逐个顺序 POST /action（而不是并发），失败一个不影响其它已选
// 项继续跑完，最后统一汇报成功/失败明细，全部成功才自动刷新页面。
function liveExecuteSelection() {
  if (selectionMode === 'delete') offerBatchSiblings();
  var ids = Object.keys(selected);
  if (ids.length === 0) return;
  // 三种模式现在各自只对应一种确定动作（见 toggleSelectionMode 里的
  // row-disabled 限制），发起请求前用 confirm() 把具体会执行什么、选了
  // 哪些项列清楚，不用再让用户凭按钮上几个字猜。
  var confirmMsg;
  if (selectionMode === 'delete') {
    confirmMsg = '确认删除选中的 ' + ids.length + ' 个 skill？会让 Claude Code、Cursor 等所有已连接的工具都不再能用它，并把仓库里的文件挪进废纸篓。';
  } else if (selectionMode === 'activate') {
    confirmMsg = '确认激活选中的 ' + ids.length + ' 个 skill（仓库中 → 已激活）？\n' + ids.join('、');
  } else {
    confirmMsg = '确认把选中的 ' + ids.length + ' 个 skill 移动到仓库中（已激活 → 仓库中，即停用）？\n' + ids.join('、');
  }
  if (!confirm(confirmMsg)) return;
  var confirmBtn = document.getElementById('selection-confirm-btn');
  confirmBtn.disabled = true;
  confirmBtn.textContent = '执行中…';
  var results = [];
  function next(i) {
    if (i >= ids.length) { finish(); return; }
    var id = ids[i];
    fetch(LIVE.endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: LIVE.token, id: id, action: actionForSelectedId(id) })
    }).then(function (r) { return r.json(); }).then(function (data) {
      results.push({ id: id, ok: !!data.ok, error: data.error });
      next(i + 1);
    }).catch(function (e) {
      results.push({ id: id, ok: false, error: String(e) });
      next(i + 1);
    });
  }
  function finish() {
    var failed = results.filter(function (r) { return !r.ok; });
    if (failed.length === 0) {
      showActionToast('已完成 ' + results.length + ' 项，即将刷新页面…');
      setTimeout(function () { location.reload(); }, 900);
      return;
    }
    confirmBtn.disabled = false;
    confirmBtn.textContent = confirmText(selectionMode);
    showActionToast('完成 ' + (results.length - failed.length) + ' 项，失败 ' + failed.length + ' 项：' +
      failed.map(function (f) { return f.id + '(' + (f.error || '') + ')'; }).join('、'));
  }
  next(0);
}
function copySelectionCommand() {
  if (LIVE) { liveExecuteSelection(); return; }
  if (selectionMode === 'delete') offerBatchSiblings();
  var ids = Object.keys(selected);
  if (ids.length === 0) return;
  var text = ids.map(commandForSelectedId).join('\n');
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text);
  }
  var message = selectionMode === 'delete'
    ? '已复制，请粘贴到终端执行。会让 Claude Code、Cursor 等所有已连接的工具都不再能用它，并把仓库里的文件挪进废纸篓。'
    : '已复制，请粘贴到终端执行。';
  showActionToast(message);
}
// 备份同步：POST /backup，服务端跑 skillctl backup sync --apply。失败原因
// 一律用 alert() 展示，不用 3 秒自动消失的 toast——这是实际改数据、连
// 网络的操作，出错原因（同一 Skill 冲突、gh/网络问题等）值得让用户读完
// 再关，之前只有"冲突"两个字命中才走 alert、其它失败走 toast，容易在
// toast 消失前没看清就以为点了没反应。成功则跟其它一键操作一样刷新页
// 面，让四张统计卡片和这张备份卡片都拿到最新状态。
function runBackupSync() {
  if (!LIVE) return;
  var btn = document.getElementById('backup-sync-btn');
  btn.disabled = true;
  var originalLabel = btn.textContent;
  btn.textContent = '同步中…';
  fetch('/backup', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: LIVE.token, action: 'sync' })
  }).then(function (r) { return r.json(); }).then(function (data) {
    if (data.ok) {
      showActionToast('同步完成，已推送到远端，即将刷新页面…');
      setTimeout(function () { location.reload(); }, 900);
      return;
    }
    btn.disabled = false;
    btn.textContent = originalLabel;
    alert('同步到云端失败：\n\n' + (data.error || '未知错误'));
  }).catch(function (e) {
    btn.disabled = false;
    btn.textContent = originalLabel;
    alert('同步到云端失败：\n\n' + String(e));
  });
}
// "软件接入"表格里每行那颗按钮：静态模式下还是原来的"复制命令到剪贴板"
// （copyCommand 本来就不需要本地服务，兼容行为不变）；LIVE 模式下直接帮你
// 跑 skillctl tools connect <id> --apply，不用再粘贴到终端——这是之前面板
// 唯一一处"本地服务都起了、还是只给复制命令"的遗留，跟 activate/
// deactivate/delete/backup sync 这些已经能直接执行的动作补齐成同一个体验。
function runToolsConnect(btn, id, cmdText) {
  if (!LIVE) { copyCommand(btn, cmdText); return; }
  var originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = t('connecting');
  fetch('/tools-action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: LIVE.token, id: id, action: 'connect' })
  }).then(function (r) { return r.json(); }).then(function (data) {
    if (data.ok) {
      showActionToast('已连接，即将刷新页面…');
      setTimeout(function () { location.reload(); }, 900);
      return;
    }
    btn.disabled = false;
    btn.textContent = originalLabel;
    alert('连接失败：\n\n' + (data.error || '未知错误'));
  }).catch(function (e) {
    btn.disabled = false;
    btn.textContent = originalLabel;
    alert('连接失败：\n\n' + String(e));
  });
}
function showActionToast(message) {
  var toast = document.getElementById('action-toast');
  toast.textContent = message;
  toast.classList.add('visible');
  clearTimeout(showActionToast._t);
  showActionToast._t = setTimeout(function () { toast.classList.remove('visible'); }, 3200);
}

// 日间/夜间/跟随系统。选择存 localStorage，跨次打开面板记得住；"跟随系统"
// 就是不设 data-theme，交给 CSS 里的 prefers-color-scheme 那条规则决定——
// 跟 body 顶部那段提前应用的脚本用的是同一个 key，两边保持一致。
function setThemeChoice(choice) {
  if (choice === 'light' || choice === 'dark') {
    document.documentElement.dataset.theme = choice;
  } else {
    delete document.documentElement.dataset.theme;
  }
  try { localStorage.setItem('skill-dashboard-theme', choice); } catch (e) {}
  updateThemeSwitchUI();
}
function updateThemeSwitchUI() {
  var current = 'system';
  try { current = localStorage.getItem('skill-dashboard-theme') || 'system'; } catch (e) {}
  document.querySelectorAll('.theme-switch-btn').forEach(function (btn) {
    btn.classList.toggle('active', btn.dataset.themeChoice === current);
  });
}
updateThemeSwitchUI();

// 中英切换——范围明确限定在"界面框架"：侧边栏、顶部、统计卡片、Skill 列表
// 上方的搜索/筛选/操作按钮、表头、选中操作条。不包括：表格里每一行的实际
// 内容（Skill 名称、简介、状态徽标，场景包成员、工具接入方式/命令这些是
// 数据不是文案）、三个向导弹窗（GitHub 导入/本地拖拽导入/添加平台）内部
// 文字、以及 toast/alert/confirm 这类运行时提示——这些保持中文，是跟用户
// 明确对齐过的范围，不是漏翻，以后要扩大范围再加。
var I18N = {
  brandTitle: { zh: 'Skill 仓库', en: 'Skill Library' },
  brandSubtitle: { zh: '本地工作台', en: 'Local Workbench' },
  navOverview: { zh: '总览', en: 'Overview' },
  navSkills: { zh: 'Skill 列表', en: 'Skills' },
  navProfiles: { zh: '场景包', en: 'Profiles' },
  navAdapters: { zh: '软件接入', en: 'Tools' },
  h1Title: { zh: 'Skill 中央仓库', en: 'Skill Library' },
  copyBtn: { zh: '复制', en: 'Copy' },
  genAtPre: { zh: '生成时间：', en: 'Generated at: ' },
  genAtPost: { zh: ' ・ 本页为静态快照，需重新运行 ', en: ' · Static snapshot — rerun ' },
  genAtPost2: { zh: ' 才会刷新', en: ' to refresh' },
  liveSubtitle: { zh: '本地服务已连接 · 每次刷新页面自动重新生成，激活/停用/删除按钮点击即生效', en: 'Local server connected · page regenerates on every reload; activate/deactivate/delete buttons apply instantly' },
  skillFolderPre: { zh: 'Skill 文件夹：', en: 'Skill folder: ' },
  skillFolderPost: { zh: '（粘贴到 Finder"前往文件夹"可直接跳转，快捷键 Cmd+Shift+G）', en: ' (paste into Finder’s "Go to Folder", ⌘⇧G)' },
  themeLight: { zh: '日间模式', en: 'Light' },
  themeDark: { zh: '夜间模式', en: 'Dark' },
  themeSystem: { zh: '跟随系统', en: 'System' },
  statTotal: { zh: '全部 Skill', en: 'Total Skills' },
  statActive: { zh: '已激活', en: 'Active' },
  statWarehouse: { zh: '仓库中', en: 'In library' },
  statBackup: { zh: 'GitHub 备份', en: 'GitHub Backup' },
  backupOffHintPre: { zh: '终端运行 ', en: 'Run ' },
  backupOffHintPost: { zh: ' 开启', en: ' in a terminal to set up' },
  backupHint: { zh: '未提交 {dirty} 项・落后远端 {behind} 个提交', en: '{dirty} uncommitted · {behind} behind remote' },
  sectionSkills: { zh: 'Skill 列表', en: 'Skills' },
  sectionProfiles: { zh: '场景包', en: 'Profiles' },
  sectionAdapters: { zh: '软件接入', en: 'Tools' },
  searchPlaceholder: { zh: '按中文名称、别名或英文 ID 搜索…', en: 'Search by name, alias, or ID…' },
  filterAll: { zh: '全部状态', en: 'All statuses' },
  modeActivate: { zh: '常驻模式', en: 'Activate Mode' },
  modeDeactivate: { zh: '移入仓库模式', en: 'Deactivate Mode' },
  modeDelete: { zh: '删除模式', en: 'Delete Mode' },
  modeExitPrefix: { zh: '退出', en: 'Exit ' },
  confirmStaticActivate: { zh: '复制激活命令', en: 'Copy activate command' },
  confirmStaticDeactivate: { zh: '复制移入仓库命令', en: 'Copy deactivate command' },
  confirmStaticDelete: { zh: '复制删除命令', en: 'Copy delete command' },
  confirmLiveActivate: { zh: '激活', en: 'Activate' },
  confirmLiveDeactivate: { zh: '移动到仓库中', en: 'Move to library' },
  confirmLiveDelete: { zh: '删除到废纸篓', en: 'Delete to Trash' },
  selectionCount: { zh: '已选中 {n} 项', en: '{n} selected' },
  btnGithubImport: { zh: '从 GitHub 导入', en: 'Import from GitHub' },
  btnUploadImport: { zh: '本地拖拽导入', en: 'Drag & Drop Import' },
  btnCheckUpdates: { zh: '检查更新', en: 'Check Updates' },
  btnBackupSync: { zh: '同步到云端', en: 'Sync to Cloud' },
  btnAddTool: { zh: '+ 添加平台', en: '+ Add Platform' },
  tooltipNeedsLive: { zh: '需要本地服务：skillctl dashboard serve', en: 'Requires local server: skillctl dashboard serve' },
  thStatus: { zh: '状态', en: 'Status' },
  thName: { zh: '中文名称', en: 'Name' },
  thId: { zh: '英文 ID', en: 'ID' },
  thCategory: { zh: '分类', en: 'Category' },
  thProfiles: { zh: '所属场景包', en: 'Profiles' },
  thDescription: { zh: '简介', en: 'Description' },
  thProfileName: { zh: '场景包', en: 'Profile' },
  thProfileCount: { zh: '数量', en: 'Count' },
  thProfileMembers: { zh: '成员', en: 'Members' },
  thTool: { zh: '软件', en: 'Tool' },
  thToolMode: { zh: '接入方式', en: 'Mode' },
  thToolCommand: { zh: '安全命令', en: 'Command' },
  toolDetected: { zh: '已检测', en: 'Detected' },
  toolResidual: { zh: '可能是残留目录', en: 'Possibly a leftover directory' },
  toolNotDetected: { zh: '未检测到', en: 'Not detected' },
  modeNative: { zh: '原生', en: 'Native' },
  modeLink: { zh: '软链', en: 'Symlink' },
  toolNativeHint: { zh: '（原生模式，自动共享全局 Skill 目录，无需命令）', en: '(native mode — shares the global Skill directory automatically, no command needed)' },
  btnConnect: { zh: '连接', en: 'Connect' },
  connecting: { zh: '连接中…', en: 'Connecting…' }
};
function currentLang() {
  try { return localStorage.getItem('skill-dashboard-lang') === 'en' ? 'en' : 'zh'; } catch (e) { return 'zh'; }
}
// 给 JS 里那些原来写死中文字符串的地方（MODE_LABELS 等）用，不依赖 DOM。
function t(key) {
  var entry = I18N[key];
  return entry ? entry[currentLang()] : key;
}
function applyLanguage() {
  var lang = currentLang();
  document.querySelectorAll('[data-i18n]').forEach(function (el) {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-title]').forEach(function (el) {
    el.title = t(el.dataset.i18nTitle);
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  });
  // 带插值的模板（目前只有备份卡片那行"未提交 N 项・落后远端 N 个提交"），
  // 数字本身来自元素自己的 data-dirty/data-behind，不需要重新请求数据。
  document.querySelectorAll('[data-i18n-template]').forEach(function (el) {
    var tpl = t(el.dataset.i18nTemplate);
    el.textContent = tpl
      .replace('{dirty}', el.dataset.dirty || '0')
      .replace('{behind}', el.dataset.behind || '0');
  });
  updateSelectionBar();
  // 选中模式激活时，模式按钮和确认按钮当前显示的是运行时拼出来的文字
  // （"退出X模式"、"复制XX命令"之类），不在静态 [data-i18n] 覆盖范围内，
  // 语言切换时要单独刷新，不然会停在切换前那种语言。
  if (selectionMode) {
    document.getElementById(MODE_BUTTON_IDS[selectionMode]).textContent = t('modeExitPrefix') + modeLabel(selectionMode);
    var confirmBtn = document.getElementById('selection-confirm-btn');
    confirmBtn.textContent = confirmText(selectionMode);
  }
}
function setLangChoice(choice) {
  try { localStorage.setItem('skill-dashboard-lang', choice); } catch (e) {}
  if (choice === 'en') {
    document.documentElement.dataset.lang = 'en';
  } else {
    delete document.documentElement.dataset.lang;
  }
  applyLanguage();
  updateLangSwitchUI();
}
function updateLangSwitchUI() {
  var current = currentLang();
  document.querySelectorAll('.lang-switch-btn').forEach(function (btn) {
    btn.classList.toggle('active', btn.dataset.langChoice === current);
  });
}
applyLanguage();
updateLangSwitchUI();

// ---- GitHub 导入向导：1 仓库地址 → 2 预览 → 3 确认 → 4 结果 ----
// 只在 LIVE 下可用（按钮本身默认 disabled，只有 LIVE 分支才会启用），因为
// 预览需要服务端真的执行一次 clone，静态快照没有等价的兜底可退化。每一步
// 都对应服务端一次独立的 skillctl import-github 调用：预览不带 --apply，
// 确认才带——跟 CLI 本身"默认只预演，加 --apply 才真正执行"的原则一致。
var ghState = null;
var GH_STEP_LABELS = [
  { n: 1, label: '仓库地址' },
  { n: 2, label: '预览' },
  { n: 3, label: '确认' },
  { n: 4, label: '结果' }
];

function openGithubWizard() {
  if (!LIVE) return;
  ghState = {
    step: 1, url: '', path: '', ref: '',
    previewOutput: '', previewOk: false,
    activate: false, replace: false,
    resultOutput: '', resultOk: false,
    multiHint: null, batchSelected: {}, batchActivate: false, batchReplace: false,
    batchResults: null, batchRunning: false
  };
  document.getElementById('gh-modal-overlay').classList.remove('hidden');
  renderGithubWizard();
}
function closeGithubWizard() {
  document.getElementById('gh-modal-overlay').classList.add('hidden');
  ghState = null;
}
function ghEscape(s) {
  var d = document.createElement('div');
  d.textContent = s == null ? '' : String(s);
  return d.innerHTML;
}
function renderGithubSteps() {
  document.getElementById('gh-steps').innerHTML = GH_STEP_LABELS.map(function (s) {
    var cls = 'gh-step';
    if (s.n === ghState.step) cls += ' active';
    else if (s.n < ghState.step) cls += ' done';
    return '<span class="' + cls + '">' + s.n + ' ' + s.label + '</span>';
  }).join('');
}
function renderGithubWizard() {
  renderGithubSteps();
  var body = document.getElementById('gh-body');
  if (ghState.step === 1) {
    body.innerHTML =
      '<div class="gh-field"><label>GitHub 仓库 URL</label>' +
      '<input type="text" id="gh-url" placeholder="https://github.com/owner/repo" value="' + ghEscape(ghState.url) + '"></div>' +
      '<div class="gh-field"><label>子路径（多 Skill 仓库才需要，比如 skills/brainstorming）</label>' +
      '<input type="text" id="gh-path" placeholder="可选" value="' + ghEscape(ghState.path) + '"></div>' +
      '<div class="gh-field"><label>分支 / tag</label>' +
      '<input type="text" id="gh-ref" placeholder="可选，默认仓库默认分支" value="' + ghEscape(ghState.ref) + '">' +
      '<div class="gh-hint">粘贴浏览器地址栏里 .../tree/&lt;ref&gt;/&lt;子路径&gt; 这种链接会自动识别，不用手填后两项</div></div>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="closeGithubWizard()">取消</button>' +
      '<button type="button" class="gh-btn gh-btn-primary" id="gh-preview-btn" onclick="ghDoPreview()">预览导入</button></div>';
  } else if (ghState.step === 2) {
    var multiHint = ghState.multiHint;
    var conflictHint = (!ghState.previewOk && !multiHint && ghState.previewOutput.indexOf('如需替换请使用') !== -1);
    if (multiHint && ghState.batchResults) {
      // 批量导入进行中/已完成：逐项显示状态，不是笼统一句"成功"或"失败"。
      var rows = ghState.batchResults.map(function (item) {
        var pill;
        if (item.status === 'pending') pill = '<span class="batch-pill pending">等待中</span>';
        else if (item.status === 'running') pill = '<span class="batch-pill running">导入中…</span>';
        else pill = item.ok ? '<span class="batch-pill ok">已导入</span>' : '<span class="batch-pill fail">失败</span>';
        var warn = item.scriptCount > 0 ? '<span class="batch-script-warn">含 ' + item.scriptCount + ' 个可执行脚本</span>' : '';
        return '<div class="batch-row"><code class="technical-id">' + ghEscape(item.path) + '</code>' + pill + warn + '</div>';
      }).join('');
      var doneCount = ghState.batchResults.filter(function (r) { return r.status === 'done'; }).length;
      var failed = ghState.batchResults.filter(function (r) { return r.status === 'done' && !r.ok; });
      body.innerHTML =
        '<div class="batch-list">' + rows + '</div>' +
        (ghState.batchRunning
          ? '<div class="gh-hint" style="margin:10px 2px;">正在导入第 ' + doneCount + ' / ' + ghState.batchResults.length + ' 个…</div>'
          : '<div class="gh-hint" style="margin:10px 2px;">完成：成功 ' + (ghState.batchResults.length - failed.length) + ' / ' + ghState.batchResults.length + '</div>' +
            (failed.length ? '<div class="gh-box fail" style="margin-top:8px;">' + failed.map(function (r) { return ghEscape(r.path) + '：\n' + ghEscape(r.output); }).join('\n\n') + '</div>' : '')) +
        '<div class="gh-actions">' +
        (ghState.batchRunning ? ''
          : '<button type="button" class="gh-btn gh-btn-secondary" onclick="ghState.batchResults = null; renderGithubWizard();">重新选择</button>' +
            '<button type="button" class="gh-btn gh-btn-primary" onclick="closeGithubWizard();">完成</button>') +
        '</div>';
    } else if (multiHint) {
      // 这不是失败，是"仓库里有好几个 Skill，挑要的"——用中性的提示框而
      // 不是红色失败框，候选路径做成勾选框，支持一次选多个批量导入，不
      // 用一个个手抄 --path 参数回第一步再粘贴。
      var allChecked = multiHint.length > 0 && multiHint.every(function (p) { return !!ghState.batchSelected[p]; });
      var selCount = multiHint.filter(function (p) { return !!ghState.batchSelected[p]; }).length;
      body.innerHTML =
        '<div class="gh-box info">' + ghEscape(ghState.previewOutput) + '</div>' +
        '<div class="gh-hint" style="margin:10px 2px 6px;">勾选要导入的 Skill（可多选）：</div>' +
        '<label class="gh-checkbox-row"><input type="checkbox" id="gh-batch-all"' + (allChecked ? ' checked' : '') + ' onchange="ghToggleBatchAll(this.checked)"> 全选（共 ' + multiHint.length + ' 个）</label>' +
        '<div class="gh-path-picks">' +
        multiHint.map(function (p) {
          var checked = !!ghState.batchSelected[p];
          return '<label class="gh-path-pick-cb' + (checked ? ' checked' : '') + '"><input type="checkbox" data-path="' + ghEscape(p) + '"' + (checked ? ' checked' : '') + ' onchange="ghToggleBatchOne(this.dataset.path, this.checked)"> ' + ghEscape(p) + '</label>';
        }).join('') +
        '</div>' +
        '<label class="gh-checkbox-row"><input type="checkbox" id="gh-batch-activate"' + (ghState.batchActivate ? ' checked' : '') + '> 导入后立即激活</label>' +
        '<label class="gh-checkbox-row"><input type="checkbox" id="gh-batch-replace"' + (ghState.batchReplace ? ' checked' : '') + '> 仓库里已有同名 Skill 时替换（旧版本自动移入废纸篓）</label>' +
        '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="ghState.step = 1; renderGithubWizard();">上一步</button>' +
        '<button type="button" class="gh-btn gh-btn-primary"' + (selCount ? '' : ' disabled') + ' onclick="ghRunBatchImport()">导入选中的 ' + selCount + ' 个</button></div>';
    } else if (conflictHint) {
      // 同样不是失败，是"仓库里已经有同名 Skill、内容不一样，你要不要替
      // 换"——这个决定本该在第 3 步的"替换"勾选框里做，但预览失败时之前
      // 根本走不到第 3 步，变成死路：重试只会拿一模一样的参数再失败一
      // 次。这里直接给一个跳到第 3 步的按钮，把"替换"勾好，用户到那边
      // 还能反悔取消勾选。
      body.innerHTML =
        '<div class="gh-box info">' + ghEscape(ghState.previewOutput) + '</div>' +
        '<div class="gh-hint" style="margin:10px 2px 6px;">仓库里已经有一份同名 Skill，内容跟 GitHub 上这份不一样，需要你确认是否替换。</div>' +
        '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="ghState.step = 1; renderGithubWizard();">上一步</button>' +
        '<button type="button" class="gh-btn gh-btn-primary" onclick="ghState.replace = true; ghState.step = 3; renderGithubWizard();">继续（可在下一步取消替换）</button></div>';
    } else {
      body.innerHTML =
        '<div class="gh-box' + (ghState.previewOk ? ' ok' : ' fail') + '">' + ghEscape(ghState.previewOutput) + '</div>' +
        '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="ghState.step = 1; renderGithubWizard();">上一步</button>' +
        (ghState.previewOk
          ? '<button type="button" class="gh-btn gh-btn-primary" onclick="ghState.step = 3; renderGithubWizard();">下一步</button>'
          // 这里以前是 onclick="ghDoPreview()"——那个函数从 DOM 读
          // #gh-url/#gh-path/#gh-ref，但第 2 步的表单早就被这段 innerHTML
          // 换掉了，元素根本不存在，点下去就是 Cannot read properties of
          // null，静默炸掉什么反应都没有。重试本来就该拿 ghState 里已经
          // 存好的参数重新发一次请求，改成 ghRunPreview() 才是对的。
          : '<button type="button" class="gh-btn gh-btn-primary" id="gh-preview-btn" onclick="ghRunPreview()">重试</button>') +
        '</div>';
    }
  } else if (ghState.step === 3) {
    body.innerHTML =
      '<p class="gh-modal-subtitle" style="margin-bottom:12px;">确认要导入：' + ghEscape(ghState.url) +
      (ghState.path ? '（子路径 ' + ghEscape(ghState.path) + '）' : '') +
      (ghState.ref ? '，ref ' + ghEscape(ghState.ref) : '') + '</p>' +
      '<label class="gh-checkbox-row"><input type="checkbox" id="gh-activate"' + (ghState.activate ? ' checked' : '') + '> 导入后立即激活</label>' +
      '<label class="gh-checkbox-row"><input type="checkbox" id="gh-replace"' + (ghState.replace ? ' checked' : '') + '> 仓库里已有同名 Skill 时替换（旧版本自动移入废纸篓，不是永久删除）</label>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="ghState.step = 2; renderGithubWizard();">上一步</button>' +
      '<button type="button" class="gh-btn gh-btn-primary" id="gh-confirm-btn" onclick="ghDoConfirm()">确认导入</button></div>';
  } else if (ghState.step === 4) {
    body.innerHTML =
      '<div class="gh-box' + (ghState.resultOk ? ' ok' : ' fail') + '">' + ghEscape(ghState.resultOutput) + '</div>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="closeGithubWizard()">关闭</button>' +
      (ghState.resultOk ? '' : '<button type="button" class="gh-btn gh-btn-primary" onclick="ghState.step = 3; renderGithubWizard();">返回重试</button>') +
      '</div>';
  }
}
// 浏览器地址栏那种 .../tree/<ref>/<子路径> 形式，自动拆成 url + ref + path，
// 跟 skillctl import-github 自己认的两种链接形式对应，省得用户手填后两项；
// 真正的校验仍然只在服务端 skillctl 那一层，这里解析错了大不了预览失败。
function ghParseTreeUrl(raw) {
  var m = /^https:\/\/github\.com\/([^\/]+)\/([^\/]+)\/tree\/([^\/]+)\/(.+)$/.exec(raw.trim());
  if (!m) return null;
  return { url: 'https://github.com/' + m[1] + '/' + m[2], ref: m[3], path: m[4] };
}
function ghSetBusy(busy, btnId, busyLabel, idleLabel) {
  var btn = document.getElementById(btnId);
  if (!btn) return;
  btn.disabled = busy;
  btn.textContent = busy ? busyLabel : idleLabel;
}
// 复制粘贴来的链接常带两类问题字符：零宽空格/NBSP 这类纯噪音，直接删掉
// 没问题；但排版软件常把连字符自动替换成"长得一样但不是 ASCII"的不断行
// 连字符 U+2011 之类——这种如果直接删掉整个非 ASCII 字符，"vercel-labs"
// 会变成完全不同的 "vercellabs"，克隆一个不存在的仓库还看不出哪里错。
// 所以先把这类形似 ASCII 的标点换回真正的 ASCII，再删剩下的噪音。
function ghCleanAscii(s) {
  s = (s || '')
    .replace(/[‐‑‒–—−]/g, '-')
    .replace(/／/g, '/').replace(/：/g, ':')
    .replace(/．/g, '.').replace(/－/g, '-').replace(/＿/g, '_');
  return s.replace(/[^\x00-\x7F]/g, '').trim();
}
// 仓库根目录没有 SKILL.md、但发现了 skills/ 子目录时，skillctl 会把每个
// 候选子目录都列成一行 "    --path skills/xxx" 提示怎么重试——这不是失
// 败，是"需要你从这几个里选一个"，从这段固定格式的输出里把候选路径抠
// 出来，好让面板直接渲染成可点的选项，而不是让人手抄命令行参数。
function ghParseMultiSkillHint(output) {
  if (!output || output.indexOf('像是多 Skill 仓库') === -1) return null;
  var re = /^\s*--path\s+(\S+)\s*$/gm;
  var paths = [];
  var m;
  while ((m = re.exec(output))) paths.push(m[1]);
  return paths.length ? paths : null;
}
function ghRunPreview() {
  ghSetBusy(true, 'gh-preview-btn', '克隆预览中…', '预览导入');
  fetch('/github-import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: LIVE.token, step: 'preview', url: ghState.url, path: ghState.path, ref: ghState.ref })
  }).then(function (r) { return r.json(); }).then(function (data) {
    ghState.previewOutput = data.output || data.error || '（无输出）';
    ghState.previewOk = !!data.ok;
    // multiHint 只在这里（拿到一次新的预览结果时）重新计算并重置勾选状
    // 态——renderGithubWizard 每次勾选框变化都会重新渲染整个面板，如果
    // 放在渲染函数里重新算，会把用户刚勾好的选项在下一次渲染时清空。
    ghState.multiHint = ghState.previewOk ? null : ghParseMultiSkillHint(ghState.previewOutput);
    if (ghState.multiHint) {
      ghState.batchSelected = {};
      ghState.batchResults = null;
      ghState.batchRunning = false;
    }
    ghState.step = 2;
    renderGithubWizard();
  }).catch(function (e) {
    ghState.previewOutput = String(e);
    ghState.previewOk = false;
    ghState.multiHint = null;
    ghState.step = 2;
    renderGithubWizard();
  });
}
function ghToggleBatchAll(checked) {
  ghState.multiHint.forEach(function (p) { ghState.batchSelected[p] = checked; });
  renderGithubWizard();
}
function ghToggleBatchOne(p, checked) {
  ghState.batchSelected[p] = checked;
  renderGithubWizard();
}
// 逐个顺序导入而不是一起并发发出去：同一个仓库的克隆临时目录、catalog.tsv
// 重建都在服务端顺序执行会更安全，而且顺序跑还能让每一项的"导入中…"状
// 态在面板上如实反映真实进度，不是一发全部变灰再一起跳结果。
function ghRunBatchStep(idx) {
  if (idx >= ghState.batchResults.length) {
    ghState.batchRunning = false;
    var okCount = ghState.batchResults.filter(function (r) { return r.ok; }).length;
    showActionToast('批量导入完成：成功 ' + okCount + ' / ' + ghState.batchResults.length);
    renderGithubWizard();
    return;
  }
  ghState.batchResults[idx].status = 'running';
  renderGithubWizard();
  fetch('/github-import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      token: LIVE.token, step: 'confirm', url: ghState.url, path: ghState.batchResults[idx].path, ref: ghState.ref,
      activate: ghState.batchActivate, replace: ghState.batchReplace
    })
  }).then(function (r) { return r.json(); }).then(function (data) {
    ghState.batchResults[idx].ok = !!data.ok;
    ghState.batchResults[idx].output = data.output || data.error || '';
    var m = /带可执行脚本（(\d+) 个）/.exec(ghState.batchResults[idx].output);
    ghState.batchResults[idx].scriptCount = m ? parseInt(m[1], 10) : 0;
    ghState.batchResults[idx].status = 'done';
    renderGithubWizard();
    ghRunBatchStep(idx + 1);
  }).catch(function (e) {
    ghState.batchResults[idx].ok = false;
    ghState.batchResults[idx].output = String(e);
    ghState.batchResults[idx].status = 'done';
    renderGithubWizard();
    ghRunBatchStep(idx + 1);
  });
}
function ghRunBatchImport() {
  var paths = ghState.multiHint.filter(function (p) { return !!ghState.batchSelected[p]; });
  if (!paths.length) return;
  ghState.batchActivate = !!document.getElementById('gh-batch-activate').checked;
  ghState.batchReplace = !!document.getElementById('gh-batch-replace').checked;
  ghState.batchResults = paths.map(function (p) { return { path: p, status: 'pending', output: '', ok: null, scriptCount: 0 }; });
  ghState.batchRunning = true;
  renderGithubWizard();
  ghRunBatchStep(0);
}
function ghDoPreview() {
  var rawUrl = ghCleanAscii(document.getElementById('gh-url').value);
  var path = ghCleanAscii(document.getElementById('gh-path').value);
  var ref = ghCleanAscii(document.getElementById('gh-ref').value);
  if (!rawUrl) return;
  var tree = ghParseTreeUrl(rawUrl);
  if (tree) {
    rawUrl = tree.url;
    if (!path) path = tree.path;
    if (!ref) ref = tree.ref;
  }
  ghState.url = rawUrl;
  ghState.path = path;
  ghState.ref = ref;
  ghRunPreview();
}
function ghDoConfirm() {
  ghState.activate = !!document.getElementById('gh-activate').checked;
  ghState.replace = !!document.getElementById('gh-replace').checked;
  ghSetBusy(true, 'gh-confirm-btn', '导入中…', '确认导入');
  fetch('/github-import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      token: LIVE.token, step: 'confirm', url: ghState.url, path: ghState.path, ref: ghState.ref,
      activate: ghState.activate, replace: ghState.replace
    })
  }).then(function (r) { return r.json(); }).then(function (data) {
    ghState.resultOutput = data.output || data.error || '（无输出）';
    ghState.resultOk = !!data.ok;
    ghState.step = 4;
    renderGithubWizard();
    if (ghState.resultOk) {
      showActionToast('导入成功：' + ghState.url + ' 已进入仓库');
    }
  }).catch(function (e) {
    ghState.resultOutput = String(e);
    ghState.resultOk = false;
    ghState.step = 4;
    renderGithubWizard();
  });
}

// ---- 本地拖拽导入：1 拖入 Skill → 2 预览 → 3 确认 → 4 结果 ----
// 跟 GitHub 导入向导同一套设计、同一批 CSS 类（gh-modal/gh-steps/gh-box/
// gh-btn），只在 LIVE 下可用。拖进来的文件夹/zip 在浏览器里读成
// {path, content_b64} 或整包 base64，POST 给 /upload-import——服务端落到
// 临时目录、校验完再交给 skillctl import 本身那套逻辑，这边不重复判断
// 导入是否安全，只负责把内容安全地读出来送过去。
var upState = null;
var UP_STEP_LABELS = [
  { n: 1, label: '拖入 Skill' },
  { n: 2, label: '预览' },
  { n: 3, label: '确认' },
  { n: 4, label: '结果' }
];
var UP_MAX_FILES = 500;

function openUploadWizard() {
  if (!LIVE) return;
  upState = {
    step: 1, kind: '', files: null, zipB64: '', pickedName: '',
    previewOutput: '', previewOk: false,
    activate: false, replace: false,
    resultOutput: '', resultOk: false
  };
  document.getElementById('up-modal-overlay').classList.remove('hidden');
  renderUploadWizard();
}
function closeUploadWizard() {
  document.getElementById('up-modal-overlay').classList.add('hidden');
  upState = null;
}
function renderUploadSteps() {
  document.getElementById('up-steps').innerHTML = UP_STEP_LABELS.map(function (s) {
    var cls = 'gh-step';
    if (s.n === upState.step) cls += ' active';
    else if (s.n < upState.step) cls += ' done';
    return '<span class="' + cls + '">' + s.n + ' ' + s.label + '</span>';
  }).join('');
}
function renderUploadWizard() {
  renderUploadSteps();
  var body = document.getElementById('up-body');
  if (upState.step === 1) {
    body.innerHTML =
      '<div class="up-dropzone" id="up-dropzone">拖一个 Skill 文件夹或打包好的 .zip 到这里<div class="up-dropzone-hint">或者点这里选择文件夹 / zip 文件</div></div>' +
      '<input type="file" id="up-folder-input" webkitdirectory style="display:none">' +
      '<input type="file" id="up-zip-input" accept=".zip" style="display:none">' +
      (upState.pickedName ? '<p class="up-picked-name">已选择：' + ghEscape(upState.pickedName) + '</p>' : '') +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="closeUploadWizard()">取消</button></div>';
    var zone = document.getElementById('up-dropzone');
    zone.addEventListener('dragover', upHandleDragOver);
    zone.addEventListener('dragleave', upHandleDragLeave);
    zone.addEventListener('drop', upHandleDrop);
    zone.addEventListener('click', function () { document.getElementById('up-folder-input').click(); });
    document.getElementById('up-folder-input').addEventListener('change', function (e) {
      upHandleFolderFileList(e.target.files);
    });
    document.getElementById('up-zip-input').addEventListener('change', function (e) {
      if (e.target.files.length) upHandleZipFile(e.target.files[0]);
    });
  } else if (upState.step === 2) {
    body.innerHTML =
      '<div class="gh-box' + (upState.previewOk ? ' ok' : ' fail') + '">' + ghEscape(upState.previewOutput) + '</div>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="upState.step = 1; renderUploadWizard();">上一步</button>' +
      (upState.previewOk
        ? '<button type="button" class="gh-btn gh-btn-primary" onclick="upState.step = 3; renderUploadWizard();">下一步</button>'
        : '<button type="button" class="gh-btn gh-btn-primary" onclick="upDoPreview()">重试</button>') +
      '</div>';
  } else if (upState.step === 3) {
    body.innerHTML =
      '<p class="gh-modal-subtitle" style="margin-bottom:12px;">确认导入：' + ghEscape(upState.pickedName) + '</p>' +
      '<label class="gh-checkbox-row"><input type="checkbox" id="up-activate"' + (upState.activate ? ' checked' : '') + '> 导入后立即激活</label>' +
      '<label class="gh-checkbox-row"><input type="checkbox" id="up-replace"' + (upState.replace ? ' checked' : '') + '> 仓库里已有同名 Skill 时替换（旧版本自动移入废纸篓，不是永久删除）</label>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="upState.step = 2; renderUploadWizard();">上一步</button>' +
      '<button type="button" class="gh-btn gh-btn-primary" id="up-confirm-btn" onclick="upDoConfirm()">确认导入</button></div>';
  } else if (upState.step === 4) {
    body.innerHTML =
      '<div class="gh-box' + (upState.resultOk ? ' ok' : ' fail') + '">' + ghEscape(upState.resultOutput) + '</div>' +
      '<div class="gh-actions"><button type="button" class="gh-btn gh-btn-secondary" onclick="closeUploadWizard()">关闭</button>' +
      (upState.resultOk ? '' : '<button type="button" class="gh-btn gh-btn-primary" onclick="upState.step = 3; renderUploadWizard();">返回重试</button>') +
      '</div>';
  }
}
function upHandleDragOver(e) {
  e.preventDefault();
  e.currentTarget.classList.add('dragover');
}
function upHandleDragLeave(e) {
  e.currentTarget.classList.remove('dragover');
}
function upHandleDrop(e) {
  e.preventDefault();
  e.currentTarget.classList.remove('dragover');
  var items = e.dataTransfer.items;
  if (!items || !items.length) return;
  // 只处理拖进来的第一个条目——一次拖一个 Skill 文件夹或一个 zip，拖多个
  // 只认第一个，避免"该合并成一个 Skill 还是分开导入"这种歧义。
  var entry = items[0].webkitGetAsEntry ? items[0].webkitGetAsEntry() : null;
  if (entry && entry.isDirectory) {
    upReadDirectoryEntry(entry, '').then(function (files) {
      upState.kind = 'folder';
      upState.files = files;
      upState.pickedName = entry.name + '/（' + files.length + ' 个文件）';
      upState.step = 2;
      renderUploadWizard();
      upDoPreview();
    }).catch(function (err) {
      alert('读取文件夹失败：' + err);
    });
    return;
  }
  var file = items[0].getAsFile ? items[0].getAsFile() : null;
  if (file) {
    if (file.name && file.name.toLowerCase().endsWith('.zip')) {
      upHandleZipFile(file);
    } else {
      alert('只支持拖一个 Skill 文件夹，或者一个打包好的 .zip 文件');
    }
  }
}
function upHandleFolderFileList(fileList) {
  if (!fileList || !fileList.length) return;
  if (fileList.length > UP_MAX_FILES) {
    alert('文件数量过多（' + fileList.length + ' 个），像是选错了目录');
    return;
  }
  Promise.all(Array.prototype.map.call(fileList, function (f) {
    return upReadFileAsArrayBuffer(f).then(function (buf) {
      return { path: f.webkitRelativePath || f.name, content_b64: upArrayBufferToBase64(buf) };
    });
  })).then(function (files) {
    upState.kind = 'folder';
    upState.files = files;
    var rootName = (fileList[0].webkitRelativePath || fileList[0].name).split('/')[0];
    upState.pickedName = rootName + '/（' + files.length + ' 个文件）';
    upState.step = 2;
    renderUploadWizard();
    upDoPreview();
  }).catch(function (err) {
    alert('读取文件夹失败：' + err);
  });
}
function upHandleZipFile(file) {
  upReadFileAsArrayBuffer(file).then(function (buf) {
    upState.kind = 'zip';
    upState.zipB64 = upArrayBufferToBase64(buf);
    upState.pickedName = file.name;
    upState.step = 2;
    renderUploadWizard();
    upDoPreview();
  }).catch(function (err) {
    alert('读取 zip 失败：' + err);
  });
}
function upReadFileAsArrayBuffer(file) {
  return new Promise(function (resolve, reject) {
    var reader = new FileReader();
    reader.onload = function () { resolve(reader.result); };
    reader.onerror = function () { reject(reader.error); };
    reader.readAsArrayBuffer(file);
  });
}
// btoa 只吃"二进制字符串"（每个字符码位 <= 255），不能直接喂 Uint8Array——
// 按 32KB 分块用 String.fromCharCode.apply 拼，避免大文件时参数个数超过
// 引擎对 apply 单次调用的实参数量限制。
function upArrayBufferToBase64(buffer) {
  var bytes = new Uint8Array(buffer);
  var binary = '';
  var chunk = 0x8000;
  for (var i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
// 递归读一个拖进来的文件夹（HTML5 Directory Entries API）：目录用
// createReader().readEntries() 分批读——浏览器对单次调用返回的条目数有
// 上限，读到空数组才算真的读完，这里循环到空为止；文件用 FileReader 转
// 成 base64。
function upReadDirectoryEntry(dirEntry, basePath) {
  var prefix = basePath + dirEntry.name + '/';
  return new Promise(function (resolve, reject) {
    var reader = dirEntry.createReader();
    var collected = [];
    function readBatch() {
      reader.readEntries(function (entries) {
        if (!entries.length) {
          Promise.all(collected.map(function (e) {
            return e.isDirectory ? upReadDirectoryEntry(e, prefix) : upReadFileEntry(e, prefix);
          })).then(function (results) {
            resolve(results.reduce(function (a, b) { return a.concat(b); }, []));
          }).catch(reject);
          return;
        }
        collected = collected.concat(entries);
        if (collected.length > UP_MAX_FILES) { reject('文件数量过多，像是拖错了目录'); return; }
        readBatch();
      }, reject);
    }
    readBatch();
  });
}
function upReadFileEntry(fileEntry, prefix) {
  return new Promise(function (resolve, reject) {
    fileEntry.file(function (file) {
      upReadFileAsArrayBuffer(file).then(function (buf) {
        resolve([{ path: prefix + fileEntry.name, content_b64: upArrayBufferToBase64(buf) }]);
      }).catch(reject);
    }, reject);
  });
}
function upDoPreview() {
  var body = { token: LIVE.token, step: 'preview', kind: upState.kind };
  if (upState.kind === 'folder') { body.files = upState.files; } else { body.zip_b64 = upState.zipB64; }
  fetch('/upload-import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function (r) { return r.json(); }).then(function (data) {
    upState.previewOutput = data.output || data.error || '（无输出）';
    upState.previewOk = !!data.ok;
    renderUploadWizard();
  }).catch(function (e) {
    upState.previewOutput = String(e);
    upState.previewOk = false;
    renderUploadWizard();
  });
}
function upDoConfirm() {
  upState.activate = !!document.getElementById('up-activate').checked;
  upState.replace = !!document.getElementById('up-replace').checked;
  var confirmBtn = document.getElementById('up-confirm-btn');
  confirmBtn.disabled = true;
  confirmBtn.textContent = '导入中…';
  var body = {
    token: LIVE.token, step: 'confirm', kind: upState.kind,
    activate: upState.activate, replace: upState.replace
  };
  if (upState.kind === 'folder') { body.files = upState.files; } else { body.zip_b64 = upState.zipB64; }
  fetch('/upload-import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function (r) { return r.json(); }).then(function (data) {
    upState.resultOutput = data.output || data.error || '（无输出）';
    upState.resultOk = !!data.ok;
    upState.step = 4;
    renderUploadWizard();
    if (upState.resultOk) {
      showActionToast('导入成功：' + upState.pickedName + ' 已进入仓库');
    }
  }).catch(function (e) {
    upState.resultOutput = String(e);
    upState.resultOk = false;
    upState.step = 4;
    renderUploadWizard();
  });
}

// 检查更新：一次请求跑 skillctl check-updates（不给 id，检查全部登记过
// 来源的），拿到 [{id, message}] 之后按 message 前缀分类，直接在对应行
// 的状态格子后面插一个小徽章——"已是最新"和"未登记来源"不加徽章（前者
// 没什么好看的，后者本来就不归这个功能管），只有"有更新"“本地已改动”
// "检查失败"这三种真正值得注意的状态才标出来，保持表格干净。
function runCheckUpdates() {
  if (!LIVE) return;
  document.querySelectorAll('#skills-table .update-badge').forEach(function (el) { el.remove(); });
  var btn = document.getElementById('check-updates-btn');
  btn.disabled = true;
  var originalLabel = btn.textContent;
  btn.textContent = '检查中…';
  fetch('/check-updates', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: LIVE.token })
  }).then(function (r) { return r.json(); }).then(function (data) {
    btn.disabled = false;
    btn.textContent = originalLabel;
    if (!data.ok) {
      showActionToast('检查更新失败：' + (data.error || '未知错误'));
      return;
    }
    var counts = { available: 0, modified: 0, error: 0 };
    var firstErrorMsg = '';
    data.results.forEach(function (item) {
      var msg = item.message || '';
      var cls = null, label = null;
      if (msg.indexOf('有更新') === 0) {
        cls = 'available'; label = '🔄 有更新'; counts.available++;
      } else if (msg.indexOf('本地内容已改动') === 0) {
        cls = 'modified'; label = '✏️ 本地已改动'; counts.modified++;
      } else if (msg.indexOf('已是最新') === 0 || msg.indexOf('未登记来源') === 0) {
        return; // 干净，不需要标
      } else {
        cls = 'error'; label = '⚠️ 检查失败'; counts.error++;
        if (!firstErrorMsg) firstErrorMsg = msg;
        console.warn('check-updates 失败：' + item.id + ' — ' + msg);
      }
      var row = document.querySelector('#skills-table tr[data-id="' + item.id + '"]');
      if (!row) return;
      var statusCell = row.querySelector('td');
      if (!statusCell) return;
      var badge = document.createElement('span');
      badge.className = 'update-badge ' + cls;
      badge.textContent = label;
      badge.title = msg;
      statusCell.appendChild(badge);
    });
    var summary = counts.available + ' 个有更新';
    if (counts.modified) summary += '，' + counts.modified + ' 个本地已改动（跳过对比）';
    if (counts.error) summary += '，' + counts.error + ' 个检查失败';
    if (counts.available === 0 && counts.modified === 0 && counts.error === 0) {
      summary = data.results.length ? '登记过的都已是最新' : '还没有 Skill 登记来源（用 skillctl track-source 补登记）';
    }
    // 原生 title 提示不够可靠（延迟、容易划过去），失败原因直接摊在
    // toast 里——反正同一批失败大概率是同一个原因（比如都连不上网），
    // 露一条示例就够看出问题在哪，不用非得精确悬停到某个徽章上。
    var detail = firstErrorMsg ? '（如：' + firstErrorMsg + '）' : '，鼠标悬停徽章看详情';
    showActionToast(summary + detail);
  }).catch(function (e) {
    btn.disabled = false;
    btn.textContent = originalLabel;
    showActionToast('检查更新失败：' + String(e));
  });
}

// ---- 自定义平台：注册一个内置列表之外的 AI 工具 ----
// 只在 LIVE 下可用（跟其它需要服务端真正执行动作的按钮一样）。名称转
// 路径建议这步只是纯前端体验，真正的 id 合法性/冲突检查在服务端
// skillctl tools add 里做——前端猜错了也没关系，提交时后端会重新校验。
function openAddToolWizard() {
  if (!LIVE) return;
  var nameInput = document.getElementById('tool-name-input');
  var pathInput = document.getElementById('tool-path-input');
  nameInput.value = '';
  pathInput.value = '';
  pathInput.dataset.autofilled = 'yes';
  document.getElementById('tool-add-result').innerHTML = '';
  document.getElementById('tool-modal-overlay').classList.remove('hidden');
}
function closeAddToolWizard() {
  document.getElementById('tool-modal-overlay').classList.add('hidden');
}
function toolNameToSlug(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}
// 平台名称输入时，只要路径框还处于"自动生成"状态（用户没手动改过）就
// 跟着刷新建议路径；用户一旦自己编辑过路径框（见上面那个 input 的
// oninput），这里就不再覆盖，对应"根据平台名称自动生成，可自由修改"
// 这句提示的语义。
function onToolNameInput() {
  var pathInput = document.getElementById('tool-path-input');
  if (pathInput.dataset.autofilled !== 'yes') return;
  var slug = toolNameToSlug(document.getElementById('tool-name-input').value || '');
  pathInput.value = slug ? '~/.' + slug + '/skills/' : '';
}
function submitAddTool() {
  var name = document.getElementById('tool-name-input').value.trim();
  var path = document.getElementById('tool-path-input').value.trim();
  var resultEl = document.getElementById('tool-add-result');
  if (!name || !path) {
    resultEl.innerHTML = '<div class="gh-box fail">平台名称和技能目录路径都不能为空</div>';
    return;
  }
  var btn = document.getElementById('tool-add-btn');
  btn.disabled = true;
  btn.textContent = '添加中…';
  fetch('/add-custom-tool', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token: LIVE.token, name: name, path: path })
  }).then(function (r) { return r.json(); }).then(function (data) {
    btn.disabled = false;
    btn.textContent = '添加';
    if (data.ok) {
      showActionToast('已注册：' + name + '，记得跑一下连接命令');
      closeAddToolWizard();
      location.reload();
    } else {
      resultEl.innerHTML = '<div class="gh-box fail">' + ghEscape(data.error || data.output || '添加失败') + '</div>';
    }
  }).catch(function (e) {
    btn.disabled = false;
    btn.textContent = '添加';
    resultEl.innerHTML = '<div class="gh-box fail">' + ghEscape(String(e)) + '</div>';
  });
}

(function () {
  var links = Array.prototype.slice.call(document.querySelectorAll('.side-link'));
  if (!links.length || typeof IntersectionObserver === 'undefined') return;
  var byTarget = {};
  links.forEach(function (a) { byTarget[a.dataset.target] = a; });
  var setActive = function (id) {
    links.forEach(function (a) { a.classList.toggle('active', a.dataset.target === id); });
  };
  // IntersectionObserver 的回调每次只带"这次状态变了"的那几个 entry，不
  // 是"当前所有观察目标的完整快照"——之前直接拿这一批 entries 里挑一个
  // "最靠上"的当结论，点导航跳转到"软件接入"（Skill 列表那么长的表格后
  // 面）时，滚动这一路会连续触发好几批回调（"场景包"先进入判定带、后
  // 来才轮到"软件接入"进入），每一批各自独立判断"这批里谁最靠上"，最后
  // 落定的往往是滚动路径上先出现的那个（场景包），不是真正停下来时实
  // 际所在的位置（软件接入）——这才是用户看到的"卡在别的项"。改成维护
  // 一份跨回调持续更新的"当前是否相交"状态表，每次回调只更新变化的那
  // 几项，但判断"该高亮谁"永远基于这份完整状态表现算的实时位置，不受
  // 单批回调顺序影响。
  // "总览"对应的 #top 是页面最开头一个零高度的占位点，本身不参与相交判
  // 定——它固定钉在绝对位置 0，跟下面 -10%~-70% 这个"视口中段"判定带永
  // 远不可能重叠（除非 scrollY 能是负数），硬塞进观察列表只会导致它永
  // 远判定不出来，白白挤占"没有任何真实 section 命中"这个默认状态该显
  // 示的结果。做法改成：只观察三个有真实高度的 section，"总览"作为兜
  // 底——三个都没命中（滚动条还停在最上面的 hero 区域）时才落回它。
  var sectionIds = ['skills-section', 'profiles-section', 'adapters-section'];
  var intersecting = {};
  var elements = {};
  var recomputeActive = function () {
    var bestId = null, bestTop = Infinity;
    sectionIds.forEach(function (id) {
      if (!intersecting[id]) return;
      var top = elements[id].getBoundingClientRect().top;
      if (top < bestTop) { bestTop = top; bestId = id; }
    });
    // "软件接入"是最后一个 section，本身不高、后面也没内容可滚——滚到底
    // 之后它的标题往往还是到不了视口顶部那条 15% 判定线，导致点了它也
    // 确实滚到最底，侧边栏却一直不高亮。但这条兜底只能在"判定带里真的
    // 什么都没命中"（bestId 为空）时才启用——上一版写成"只要滚到页面
    // 底部就无条件抢成最后一个 section"，"场景包"和"软件接入"这两个 section
    // 挨得很近、加起来都没一屏高，只要滚到"场景包"就已经满足"接近页面
    // 底部"，于是"场景包"明明还在判定带里正确命中，也会被这条兜底覆盖
    // 掉，永远显示成"软件接入"。改成只在真的没有任何命中时才用。
    if (!bestId) {
      var atBottom = (window.innerHeight + window.scrollY) >= (document.documentElement.scrollHeight - 2);
      if (atBottom) bestId = sectionIds[sectionIds.length - 1];
    }
    setActive(bestId || 'top');
  };
  // "场景包"和"软件接入"这两个 section 挨在一起、加起来都不到一屏高——
  // 页面能滚动的距离压根不够把这两个"谁在视口顶部判定带里"区分开：不
  // 管点的是哪一个，最后能到达的滚动位置几乎是同一个（相差不到 100px），
  // 纯靠滚动位置反推"现在在看哪个 section"在这种挤在页面最底部的场景
  // 下没有唯一解。这种时候滚动位置本身已经不可靠，只能相信"用户刚点的
  // 是哪个"——点击后先立刻把那个设成高亮，并在接下来这段时间内不让滚动
  // 观察器的判断覆盖掉它，等滚动动画大概率已经落定再恢复正常跟踪。
  var suppressUntil = 0;
  document.getElementById('side-nav-links').addEventListener('click', function (evt) {
    var link = evt.target.closest('.side-link');
    if (!link) return;
    setActive(link.dataset.target);
    // 900ms 试过不够——CSS 的 scroll-behavior: smooth 滚一趟一万多像素的
    // 页面，动画本身就要一两秒，锁定窗口比动画还短的话，动画还没停，滚动
    // 追踪已经恢复，最后一次 scroll 事件算出来的（还是那个有歧义的临界
    // 位置）会把刚设好的高亮又覆盖回去。2.2 秒足够盖过这页最长的一趟滚动
    // 动画。
    suppressUntil = Date.now() + 2200;
  });
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) { intersecting[e.target.id] = e.isIntersecting; });
    if (Date.now() < suppressUntil) return;
    recomputeActive();
  // 判定带只留视口最上面 15%——不是"视口中段"。这页开头的 hero+统计卡
  // 加起来就没多高，Skill 列表这种大 section 的标题一进页面没滚动就已
  // 经在视口中段了，用"-10% 0px -70% 0px"这种中段判定带的话，一加载
  // 页面在还没滚动的情况下"Skill 列表"就被判成当前项，"总览"反而选不
  // 中。改成只认"这个 section 的标题是不是已经滚到贴近视口顶部"，跟大
  // 多数 scrollspy 导航的判定方式一致，也让"总览"在真正没滚动时保持
  // 选中。
  }, { rootMargin: '0px 0px -85% 0px' });
  sectionIds.forEach(function (id) {
    var el = document.getElementById(id);
    if (el) { elements[id] = el; intersecting[id] = false; observer.observe(el); }
  });
  // "滚到底" 那条判定只在 recomputeActive 里生效，但 IntersectionObserver
  // 只在某个 section 的相交状态发生"跨越"时才回调一次——滚到最底部之后如
  // 果没有新的跨越事件（常见于最后一个 section 提前就已经交叉过判定带），
  // recomputeActive 不会再被触发，"滚到底"这条判断也就没机会跑到。补一
  // 个节流过的 scroll 监听兜底，保证滚动停下来之后这条判断一定会跑一次。
  var scrollTick = false;
  window.addEventListener('scroll', function () {
    if (scrollTick) return;
    scrollTick = true;
    requestAnimationFrame(function () {
      scrollTick = false;
      if (Date.now() < suppressUntil) return;
      recomputeActive();
    });
  }, { passive: true });
  setActive('top');
})();
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
