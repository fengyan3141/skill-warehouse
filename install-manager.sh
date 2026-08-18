#!/bin/bash
# Install/upgrade the recoverable runtime manager into
# $SKILL_LIBRARY_ROOT/{bin,lib,config}. Never touches skills/, archive/,
# state/, catalog.tsv, shell startup files, or PATH. Default mode is a
# read-only preview.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PACKAGE_SOURCE="${SKILL_PACKAGE_ROOT:-$SCRIPT_DIR}"
SKILL_LIBRARY_ROOT="${SKILL_LIBRARY_ROOT:-$HOME/.skill-library}"
APPLY=0

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

BIN_FILES=(skillctl build-catalog.sh build-dashboard.sh dashboard-server.py evaluate-router.sh sync-skills.sh)
LIB_FILES=(skill-lib.sh)

if [ "$APPLY" -ne 1 ]; then
  printf '预演模式，不会安装或替换管理组件；确认后运行: %s --apply\n' "$0"
  exit 0
fi

mkdir -p "$SKILL_LIBRARY_ROOT" || {
  printf '仓库根目录创建失败: %s\n' "$SKILL_LIBRARY_ROOT" >&2
  exit 1
}

staging="$(mktemp -d "$SKILL_LIBRARY_ROOT/.install-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT HUP INT TERM

mkdir -p "$staging/bin" "$staging/lib" "$staging/config"

for f in "${BIN_FILES[@]}"; do
  [ -f "$PACKAGE_SOURCE/$f" ] || { printf '缺少打包文件: %s\n' "$f" >&2; exit 1; }
  cp "$PACKAGE_SOURCE/$f" "$staging/bin/$f"
  chmod +x "$staging/bin/$f"
done

for f in "${LIB_FILES[@]}"; do
  [ -f "$PACKAGE_SOURCE/lib/$f" ] || { printf '缺少打包文件: lib/%s\n' "$f" >&2; exit 1; }
  cp "$PACKAGE_SOURCE/lib/$f" "$staging/lib/$f"
done

[ -d "$PACKAGE_SOURCE/config" ] || { printf '缺少打包配置目录: config\n' >&2; exit 1; }
/usr/bin/ditto "$PACKAGE_SOURCE/config" "$staging/config"

# --- Staged validation: bash -n on every shell entrypoint, a Python syntax
#     check on dashboard-server.py, six-column aliases, eight-column
#     adapters, and every profile ID present in the inventory. Nothing
#     below is installed until all of this passes.
for entry in "$staging/bin"/* "$staging/lib"/*; do
  [ -f "$entry" ] || continue
  case "$entry" in
    *.sh|*/skillctl)
      bash -n "$entry" || { printf '语法校验失败: %s\n' "$entry" >&2; exit 1; }
      ;;
    *.py)
      command -v python3 >/dev/null 2>&1 && {
        python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$entry" \
          || { printf '语法校验失败: %s\n' "$entry" >&2; exit 1; }
      }
      ;;
  esac
done

[ -f "$staging/config/aliases.tsv" ] || { printf '缺少 config/aliases.tsv\n' >&2; exit 1; }
bad_aliases="$(awk -F '\t' '$0 !~ /^#/ && NF && NF != 6 { c++ } END { print c+0 }' "$staging/config/aliases.tsv")"
[ "$bad_aliases" = "0" ] || { printf 'aliases.tsv 未通过六列校验\n' >&2; exit 1; }

[ -f "$staging/config/adapters/tools.tsv" ] || { printf '缺少 config/adapters/tools.tsv\n' >&2; exit 1; }
bad_adapters="$(awk -F '\t' '$0 !~ /^#/ && NF && NF != 8 { c++ } END { print c+0 }' "$staging/config/adapters/tools.tsv")"
[ "$bad_adapters" = "0" ] || { printf 'tools.tsv 未通过八列校验\n' >&2; exit 1; }

inventory_file=""
for candidate in "$staging/config"/inventory-*.txt; do
  [ -f "$candidate" ] || continue
  inventory_file="$candidate"
  break
done
[ -n "$inventory_file" ] || { printf '缺少 config/inventory-*.txt\n' >&2; exit 1; }

inventory_sorted="$(mktemp "$staging/.inventory-sorted.XXXXXX")"
sed '/^#/d; /^[[:space:]]*$/d' "$inventory_file" | LC_ALL=C sort -u > "$inventory_sorted"

missing=""
[ -d "$staging/config/profiles" ] || { printf '缺少 config/profiles\n' >&2; exit 1; }
for pfile in "$staging/config/profiles"/*; do
  [ -f "$pfile" ] || continue
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    grep -F -x "$pid" "$inventory_sorted" >/dev/null 2>&1 || missing="$missing $pid(来自 $(basename "$pfile"))"
  done < <(sed '/^#/d; /^[[:space:]]*$/d' "$pfile")
done
rm -f "$inventory_sorted"
[ -z "$missing" ] || { printf '场景包引用了不在库存中的 ID：%s\n' "$missing" >&2; exit 1; }

# --- Validation passed: back up any currently installed managed files
#     before replacing them.
for d in bin lib config; do
  if [ -e "$SKILL_LIBRARY_ROOT/$d" ] && [ -L "$SKILL_LIBRARY_ROOT/$d" ]; then
    printf '拒绝替换：%s 是软链，无法安全判断归属\n' "$SKILL_LIBRARY_ROOT/$d" >&2
    exit 1
  fi
done
if [ -e "$SKILL_LIBRARY_ROOT/config/aliases.tsv" ] && [ -L "$SKILL_LIBRARY_ROOT/config/aliases.tsv" ]; then
  printf '拒绝替换：%s 是软链，无法安全判断归属\n' "$SKILL_LIBRARY_ROOT/config/aliases.tsv" >&2
  exit 1
fi
if [ -e "$SKILL_LIBRARY_ROOT/config/profiles" ] && [ -L "$SKILL_LIBRARY_ROOT/config/profiles" ]; then
  printf '拒绝替换：%s 是软链，无法安全判断归属\n' "$SKILL_LIBRARY_ROOT/config/profiles" >&2
  exit 1
fi

installed_before=0
for d in bin lib config; do
  [ -d "$SKILL_LIBRARY_ROOT/$d" ] && installed_before=1
done

if [ "$installed_before" -eq 1 ]; then
  backup_dir="$SKILL_LIBRARY_ROOT/manager-backups/$(date -u '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  for d in bin lib config; do
    if [ -d "$SKILL_LIBRARY_ROOT/$d" ]; then
      /usr/bin/ditto "$SKILL_LIBRARY_ROOT/$d" "$backup_dir/$d"
    fi
  done
  printf '已备份现有管理组件到: %s\n' "$backup_dir"
fi

for d in bin lib; do
  rm -rf "${SKILL_LIBRARY_ROOT:?}/$d"
  mv "$staging/$d" "$SKILL_LIBRARY_ROOT/$d"
done

# config/ 不整体替换：aliases.tsv 和 profiles/ 下的文件是用户自己的中文
# 别名和场景包定义，已经存在就绝不覆盖——只在真实环境里还没有这份文件时
# 才从包里种一份默认值当起点，不然每次跟着代码升级同步都会把用户的定制
# 清空（这个坑已经在真实环境里踩过两次）。除此之外的内容——adapters/、
# route-evals.tsv、inventory-*.txt 等随包持续改进的参考/集成配置——照常
# 整体跟包同步替换。
mkdir -p "$SKILL_LIBRARY_ROOT/config" "$SKILL_LIBRARY_ROOT/config/profiles"
for entry in "$staging/config"/*; do
  name="$(basename "$entry")"
  case "$name" in
    aliases.tsv|profiles) continue ;;
  esac
  rm -rf "${SKILL_LIBRARY_ROOT:?}/config/$name"
  mv "$entry" "$SKILL_LIBRARY_ROOT/config/$name"
done

if [ -f "$SKILL_LIBRARY_ROOT/config/aliases.tsv" ]; then
  printf '保留已有的 config/aliases.tsv（未跟包同步，避免清空你的中文别名）\n'
else
  mv "$staging/config/aliases.tsv" "$SKILL_LIBRARY_ROOT/config/aliases.tsv"
fi

for pfile in "$staging/config/profiles"/*; do
  [ -f "$pfile" ] || continue
  pname="$(basename "$pfile")"
  if [ -f "$SKILL_LIBRARY_ROOT/config/profiles/$pname" ]; then
    printf '保留已有的 config/profiles/%s（未跟包同步，避免清空你的场景包定义）\n' "$pname"
  else
    mv "$pfile" "$SKILL_LIBRARY_ROOT/config/profiles/$pname"
  fi
done

trap - EXIT HUP INT TERM
rm -rf "$staging"

printf '管理组件已安装到: %s\n' "$SKILL_LIBRARY_ROOT"
printf '稳定入口: %s/bin/skillctl\n' "$SKILL_LIBRARY_ROOT"
