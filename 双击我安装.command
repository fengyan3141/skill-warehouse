#!/bin/bash
# 双击运行——不用打开终端、不用敲命令。等同于 README「Quickstart」第 1-3
# 步的图形界面版：安装 skillctl、导入随包的两个示例 Skill、激活 core 场景
# 包，最后起本地服务打开面板，往后每一步都在浏览器里点。
#
# 首次双击如果 macOS 提示"无法打开，因为来自身份不明的开发者"：在这个文件
# 上右键（或按住 Control 点按）→ 打开，再确认一次"打开"就行，只有第一次
# 需要这样——这是系统对所有从网上下载的脚本的统一提示，不是这个脚本有问题。
set -uo pipefail

cd "$(dirname "$0")" || exit 1

printf '\n== 第 1 步：安装 skillctl ==\n\n'
if ! ./install-manager.sh --apply; then
  printf '\n安装失败，上面是具体报错。按任意键关闭这个窗口...\n'
  read -n 1 -s -r
  exit 1
fi

SKILLCTL="$HOME/.skill-library/bin/skillctl"

printf '\n== 第 2 步：导入随包的两个示例 Skill ==\n\n'
"$SKILLCTL" import "$(pwd)/examples/commit-message-writer" --apply || true
"$SKILLCTL" import "$(pwd)/examples/code-review-checklist" --apply || true

printf '\n== 第 3 步：激活 core 场景包 ==\n\n'
"$SKILLCTL" profile use core --apply || true

printf '\n== 完成，正在打开本地面板（浏览器会自动弹出）==\n'
printf '这个窗口开着的时候，面板里的按钮才能直接生效；关掉这个窗口（或按 Ctrl+C）会\n'
printf '停掉本地服务，面板还能看，但按钮不再生效——想再用就重新双击这个文件。\n\n'

exec "$SKILLCTL" dashboard serve
