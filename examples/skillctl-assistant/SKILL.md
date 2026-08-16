---
name: skillctl-assistant
description: 代用户安全地操作 skillctl——这套跨 Codex/Claude Code/Cursor/Trae 等多工具共用的 Skill 仓库管理系统。当用户提到"帮我装个 skill"、"把这个 skill 收进仓库"、"切到 xxx 场景包"、"把这个工具接进来"、"清理一下失效的软链"、"这个 skill 不要了"、"看看仓库里都有什么"等操作请求，且用户环境已经安装了 skillctl（`~/.skill-library/bin/skillctl` 存在）时使用。核心约束：任何会改动状态的命令必须先不带 `--apply` 跑一遍、把结果原样给用户看，用户明确确认后才能加 `--apply`；`archive`、`tools disconnect`、`import --replace`、`eject` 这类不可逆或影响面大的操作，AI 只能建议，不能替用户拍板。不负责编写 Skill 内容本身（那是别的事），只负责仓库的增删改查、场景包切换、工具连接这些管理操作。
---

# skillctl 操作助手

## 概述

`skillctl` 管理一个多工具共用的 Skill 仓库：所有 Skill 只在 `~/.skill-library/skills/` 存一份，`~/.agents/skills/` 是"当前露出哪些"的受管软链层，Codex/Cursor/Gemini CLI 直接共享这一层，Claude Code/Trae/CodeBuddy/Qoder/Kiro 等工具通过 `tools connect` 建立自己的软链副本。稳定命令入口固定是：

```
~/.skill-library/bin/skillctl
```

不要假设、拼接或猜测别的路径；这个入口不存在就说明用户还没装好管理组件，不要试图绕过去直接操作 `~/.skill-library/skills/` 或 `~/.agents/skills/` 底下的文件。

---

## 安全规则（不可协商，任何时候都要遵守）

1. **先 dry-run，后 `--apply`**：`activate`/`deactivate`/`profile use`/`project use`/`import`/`archive`/`restore`/`tools connect`/`tools disconnect`/`dashboard build` 这些会改动状态的命令，第一次调用一律不带 `--apply`，把预演输出**原样**贴给用户看（不要摘要、不要替用户判断"看起来没问题"）。只有用户看过之后明确说"可以""确认""apply""执行吧"这类话，才能带 `--apply` 重新跑一遍同样的命令。
2. **`archive`、`tools disconnect`、`import --replace`、`eject` 由用户拍板，AI 只建议**：这几个命令要么让 Skill 从工具里彻底消失（disconnect），要么把旧版本挪进归档（archive、replace 会先归档旧版），要么让整个仓库软链体系永久失效（eject——物化之后就不再是"当前激活哪些"实时同步了，各工具目录变成互相独立的静态副本）。即使 dry-run 显示的结果看起来完全合理，AI 也不能自己决定要不要加 `--apply`——只能说"建议这样做，要不要执行？"，等用户亲口确认。**永远不要**因为用户说了一句宽泛的"帮我整理一下"，就自作主张去 archive、disconnect 或 eject 具体的东西。
3. **遇到"冲突"提示，原样转达两条出路，不替用户选**：`真实目录冲突`/`外部软链冲突` 会打印两条路——"想收编进仓库用 `import ... --apply`"或"想保留原样不用管"。把这两条路都讲给用户听，不要替用户默认选其中一条。
4. **不知道 id 就先 `list`/`search`/`status`，不要凭猜测拼 id**：Skill 的英文 id 和它的中文名不是简单的拼音/翻译关系（比如"飞书文档"对应的 id 是 `lark-doc`），操作前用 `search 关键词` 或 `list` 确认真实 id，不要自己编。
5. **没有"彻底删除"命令**：仓库里没有永久删除功能，只有 `archive`（软删除，留在 `archive/` 目录里，可以 `restore`）。用户要"删掉"某个 Skill，默认理解成 `archive`；如果用户执意要物理删除 `archive/` 目录下的内容，那是纯文件系统操作，不在 `skillctl` 的命令范围内，且这类操作本身就属于规则 2 的"AI 只建议不拍板"。
6. **改配置文件（`config/adapters/tools.tsv` 等）不是"写代码"，也要走确认流程**：见下面"接入新工具"一节，改完配置文件后同样要先 `tools detect`/`tools connect`（不带 `--apply`）给用户看效果，确认后才真正连接。

---

## 命令全集与参数

以下按用途分组；`ID` 统一指 Skill 的英文 id（不是中文名）。

### 只读查询（不需要走"先 dry-run"这条规则，本身就是只读的）

| 命令 | 作用 |
|---|---|
| `skillctl list` | 列出仓库里全部 Skill |
| `skillctl search 关键词` | 按关键词搜索 Skill（中文名/别名/描述都会匹配） |
| `skillctl route "一句话描述"` | 给一句自然语言，返回最多 3 个候选 Skill；只读、不落盘 |
| `skillctl status` | 查看每个 Skill 的状态：仓库中 / 已激活 / 已归档 / 缺失 / 冲突，分全局和当前项目两个维度 |
| `skillctl route-status` | 查看路由自动选择功能是否达标启用 |
| `skillctl tools detect` | 检测九个已知软件适配器（Codex/Cursor/Gemini CLI/Claude Code/Kiro/Trae/TraeCode CN/CodeBuddy/Qoder）的安装状态 |
| `skillctl dashboard open` | 打开本地只读面板（需要先 `dashboard build` 过一次） |
| `skillctl doctor` | 健康检查：逐项给出 ✅/⚠️/❌ 加一行修复建议，覆盖断链、工具检测漏检、`verification` 拦截、`manual.list` 与磁盘一致性、Skill 内容完整性、catalog 重复 id、catalog 与磁盘一致性。全程只读，不改动任何文件；发现 ❌ 时退出码非零 |
| `skillctl lint` | 内容质量检查：frontmatter 完整性（含 name 字段是否与目录名一致，这条 doctor 不查）、description 长度是否合理、当前激活集合内 Skill 之间触发词是否重叠。全程只读；发现 ❌（如缺 SKILL.md/name/description）时退出码非零，长度/重叠只是 ⚠️ 不影响退出码 |

### 会改动状态（必须先 dry-run，见"安全规则"第 1 条）

| 命令 | 作用 | 关键参数 |
|---|---|---|
| `skillctl activate ID [--apply]` | 单独激活一个 Skill（建软链到 `~/.agents/skills`），会记入 `state/manual.list`，之后切场景包不会把它清掉 | — |
| `skillctl deactivate ID [--apply]` | 停用一个 Skill（移除软链），同时从 manual.list 里移除 | — |
| `skillctl profile use 场景包名 [--apply]` | 切换到某个场景包。语义：`core` 永远保留；会把不在"core∪目标场景包∪manual.list"里的现有成员停用（**dry-run 会显式列出将停用的清单**，仔细看这个清单再决定要不要 `--apply`）；单独 `activate` 过的 Skill 不受影响 | 场景包名以 `config/profiles/` 下实际存在的文件名为准（不同仓库不一样，随包默认只有 `core`），不知道就先 `ls config/profiles/` 或问用户确认 |
| `skillctl project use 场景包名 绝对项目路径 [--apply]` | 同 `profile use`，但作用于某个项目自己的 `.agents/skills`（项目路径必须是绝对路径且已存在） | — |
| `skillctl import 绝对目录 [--display-name 名称] [--alias 别名] [--activate] [--replace] [--apply]` | 把仓库外的一个 Skill 目录导入仓库。`--display-name` 可选，不给就默认等于 id；同名内容不同时默认停止，只有 `--replace` 才会替换（先归档旧版）；`--activate` 表示导入后顺便激活 | 见"安全规则"第 2 条：`--replace` 属于需要用户拍板的操作 |
| `skillctl archive ID [--apply]` | 归档一个 Skill（软删除，移出仓库进 `archive/`，同时清理受管软链） | 见"安全规则"第 2 条 |
| `skillctl restore ID [--archive-id 归档ID] [--reactivate] [--apply]` | 从归档恢复；默认恢复最近一个版本、不重新激活；`--reactivate` 才会尝试恢复受管软链（有冲突会安全跳过） | — |
| `skillctl tools connect ID [--allow-unverified] [--prune] [--apply]` | 把当前激活集合同步到某个工具自己的 Skill 目录（软链模式的工具才需要，原生模式工具会提示"无需连接"）。`--prune` 顺带清理该工具目录下已经失效的托管软链 | 见下方"verification/app_name 的实际检测逻辑"再决定要不要加 `--allow-unverified` |
| `skillctl tools disconnect ID [--apply]` | 断开某个工具（移除该工具目录下的受管软链） | 见"安全规则"第 2 条 |
| `skillctl dashboard build [--apply]` | 重新生成本地只读面板（静态快照）。`activate`/`deactivate`/`profile use`/`tools connect`/`tools disconnect`/`eject`、以及带 `--activate`/`--reactivate` 的 `import`/`restore`，这些 `--apply` 命令成功后会自动收尾重建一次，一般不需要手动跑；只有单纯想强制刷新（比如上一次自动重建失败过）才需要手动执行 | 相对低风险，仍按规则先 dry-run 一次确认命令没打错 |
| `skillctl eject [--apply]` | 退出机制：把所有已连接工具目录（含 `~/.agents/skills` 本身）里受管的软链，逐个替换成当前指向内容的真实拷贝；`--apply` 前会先把将改动的目录备份到 `~/.skill-library/eject-backups/<时间戳>/`，备份失败直接中止、不碰任何文件 | 归属"用户拍板"级别的操作（跟"安全规则"第 2 条同等对待）：这基本等于永久脱离 skillctl 管理，即使 dry-run 看起来没问题也要让用户明确确认再 `--apply`；不改动不归属仓库的外部软链或已存在的真实目录 |

---

## `verification`/`app_name` 字段的实际检测逻辑（避免误判"未检测到"）

`config/adapters/tools.tsv` 每行一个工具适配器，`tools detect` 判断"已检测"的方式：

- **`app_name` 字段**：精确匹配 `/Applications/<app_name>.app` 这个文件夹名，**不做模糊匹配**。如果用户装的应用文件夹名跟配置里的不完全一样（比如中国区特供版加了" CN"后缀、或者本地化显示名和真实文件夹名不一致），检测会失败，显示"未检测到"或"可能是残留目录"，但这不代表用户真的没装——先用 `ls /Applications | grep -i 关键词` 核实真实文件夹名，跟用户确认后再考虑改 `tools.tsv` 里的 `app_name` 值。
- **`cli_command` 字段**：靠 `command -v` 查 PATH，同理只认精确命令名。
- **`verification` 字段**：**只在字面完全等于 `"unverified"` 时**才会触发"尚未验证，需要 `--allow-unverified`"的拦截；除此之外，不管这一列写的是什么中文说明文字，都不会被展示给用户看（`tools detect` 的输出、面板的适配器表格都不显示这一列），纯粹是个人工检查提示，只有维护者直接打开 `tools.tsv` 才看得到。当前九个已知适配器的 `verification` 字段全部是描述性中文句子（不是字面 `unverified`），所以现在没有一个会真的被拦截——如果以后新增一行想让某个适配器默认拒绝连接，字面值必须精确写成 `unverified` 才有效。

---

## 常见人话任务 → 命令映射表

| 用户说的话（举例） | 对应命令（先不带 `--apply`） |
|---|---|
| "帮我看看现在都激活了哪些 skill" | `skillctl status` |
| "有没有跟 XX 相关的 skill" | `skillctl search XX` |
| "我该用哪个 skill 处理这个" | `skillctl route "一句话描述需求"` |
| "把 XX 激活一下" | 先 `search` 确认真实 id，再 `skillctl activate <id>` |
| "不用 XX 了，关掉" | `skillctl deactivate <id>`（措辞含糊时确认是"停用"还是"archive 归档"） |
| "切到 XX 场景/模式" | 先 `ls config/profiles/` 或问用户确认真实场景包名，再 `skillctl profile use <场景包名>` |
| "把这个 skill 收进仓库里" | `skillctl import <绝对路径>`（首次导入没中文名会默认等于 id，问用户要不要指定 `--display-name`） |
| "这个 skill 不要了/删掉" | `skillctl archive <id>`（讲清楚这是软删除、可恢复，让用户确认） |
| "我想把之前删的 XX 拿回来" | `skillctl restore <id>` |
| "把 Claude Code/CodeBuddy/xxx 接进来" | `skillctl tools detect` 确认已检测到，再 `skillctl tools connect <工具id>` |
| "XX 工具里怎么有一堆打不开的 skill" | `skillctl tools connect <工具id> --prune`，清理失效软链 |
| "看看仓库全貌/生成个面板" | `skillctl dashboard build && skillctl dashboard open` |
| "我要用的这个工具不在清单里" | 走下面"接入新工具"流程，不要直接手动建软链 |
| "帮我检查一下仓库有没有问题/健康检查一下" | `skillctl doctor`（只读，不用先 dry-run，但发现的每一条修复建议本身该走哪条规则、就走哪条——比如它建议的 `tools connect --prune --apply` 仍要先不带 `--apply` 确认） |
| "我想彻底不用 skillctl 了/脱离这套管理" | `skillctl eject`（先讲清楚这是永久操作：物化之后各工具目录变成独立静态副本，不再随激活状态自动同步；讲清楚后果并让用户确认，参考"安全规则"第 2 条） |
| "帮我看看 Skill 写得好不好/有没有能改进的" | `skillctl lint`（只读，检查 frontmatter 完整性、description 长度、当前激活集合内触发词重叠） |

---

## 接入新工具

`config/adapters/tools.tsv` 是唯一的工具定义来源，没有散落的 if/else，接入一个新工具本质就是"研究清楚它、加一行、连接、确认"，全程不要跳过用户确认。

### 第一步：调研目标工具，确认格式兼容

在动配置文件之前，先弄清楚：

1. **这个工具是否也用 `SKILL.md`（YAML frontmatter + Markdown 正文，`name`/`description` 字段）来识别 Skill？** 如果目标工具用的是完全不同的清单格式（比如 `manifest.json`、专属的 plugin.yaml），那么直接把仓库里的 Skill 目录软链过去，工具大概率读不出来——这种情况不能简单加一行 tools.tsv 了事，要如实告诉用户"格式不兼容，需要额外转换或者这个工具暂时接不进来"，不要硬着头皮建软链假装接上了。
2. **它的 Skill 目录在哪**：是固定路径（比如 `~/.某工具/skills`），还是要看设置里配的？在真实机器上用 `find`/`ls` 确认目录是否已经存在、命令行入口叫什么、`/Applications` 下真实的应用文件夹名叫什么（不要靠猜，参考上面"verification/app_name"那节的教训）。
3. **它是不是已经在用 `~/.agents/skills`（原生模式）**：如果是，属于"原生"，不需要新增软链模式的行，只要确认它能扫描到 `~/.agents/skills` 就行。

把调研到的信息（目录路径、检测方式、是否格式兼容）跟用户过一遍，再进入下一步。

### 第二步：在 `config/adapters/tools.tsv` 加一行

字段顺序（tab 分隔，8 列）：

```
id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
```

| 字段 | 说明 |
|---|---|
| `id` | 稳定英文标识，之后 `tools connect <id>` 用这个 |
| `display_zh` | 中文显示名，面板和 CLI 提示里用 |
| `mode` | `native`（原生共享 `~/.agents/skills`）或 `link`（需要软链） |
| `global_dir` | `mode=link` 时，该工具的 Skill 目录绝对路径（可以用 `~` 开头） |
| `project_dir` | 项目内相对路径（一般是 `.工具名/skills` 这种形式） |
| `cli_command` | 命令行程序名，没有就留空（留空不要用占位符，直接留空，字段本身已验证过在 bash 3.2 下能正确解析空字段） |
| `app_name` | `/Applications/` 下精确的文件夹名（不含 `.app` 后缀），没有 GUI 应用就留空 |
| `verification` | 人工检查提示文字，纯说明用途，不影响功能（除非字面写 `unverified`，见上文） |

真实示例（`trae-cn` 这一行，是这次接入 TraeCode CN 时加的）：

```
trae-cn	TraeCode CN	link	~/.trae-cn/skills	.trae-cn/skills		Trae CN	确认软链目标为 ~/.agents/skills
```

改完文件后，先跟用户过一遍这一行是否准确（尤其 `global_dir` 和 `app_name`），不要直接进入下一步。

### 第三步：`tools detect` → `tools connect`（dry-run 先行）

```
skillctl tools detect
```

确认新加的这行显示"已检测"（而不是"未检测到"，那说明 `app_name`/`cli_command` 填得不对，回第二步核实）。然后：

```
skillctl tools connect <新工具id>
```

不带 `--apply`，把预演结果给用户看——会新建哪些软链、有没有真实目录冲突。用户确认后再加 `--apply` 正式连接。

---

## 边界

- 不负责编写或修改 Skill 本身的内容（`SKILL.md` 正文、`references/`、`scripts/` 等），只负责仓库层面的增删改查和工具连接。
- 不负责判断某个自然语言请求"应该触发哪个具体 Skill 去执行"——那是 `skill-router`/`route` 的职责，本 Skill 只管 `skillctl` 这套管理命令本身怎么用、怎么安全地用。
- 如果用户的 `skillctl` 版本比这份文档旧、缺某个命令，如实告诉用户"这个版本还没有这个命令"，不要假装执行或编造输出（`doctor`/`eject`/`lint` 都已经实现，见上面的命令表）。
