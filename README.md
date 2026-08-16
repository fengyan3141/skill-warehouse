# skill-warehouse

**一个仓库，多个货架**——把 Claude Code、Cursor、Codex、Trae 等工具各自维护一份 Skill 目录，改成所有工具共享同一份仓库内容。改一处，处处生效；每个工具当前露出哪些 Skill，由场景包决定，不是全量塞给所有工具。

命令行入口叫 `skillctl`。仅支持 **macOS**（依赖 `ditto`、`/Applications` 应用检测，其他平台需要重新设计文件操作层）。

---

## 为什么要这个

多个 AI 编程工具（Claude Code、Cursor、Codex、Trae 系、CodeBuddy、Qoder…）现在都支持 `SKILL.md` 格式的 Agent Skills。但每个工具都有自己的 Skill 扫描目录，直接的后果是：同一个 Skill 在不同工具里各存一份，改了一处忘了改另一处，甚至同名不同内容互相打架。

`skillctl` 把"存"和"露出"拆开：所有 Skill 只在一个仓库目录里维护一份，各工具看到的是指回仓库的软链（或者对原生共享目录的工具，直接共享同一个目录）。不想同时把几十上百个 Skill 全塞进每个工具的上下文，用"场景包"按需切换当前露出哪一批。

## 30 秒看懂能做什么

```bash
skillctl status                          # 看现状：哪些 Skill 在仓库、哪些已激活
skillctl profile use core --apply        # 切到 core 场景包（这个场景包永远保留）
skillctl tools connect claude-code --apply  # 把当前激活集合同步给 Claude Code
skillctl doctor                          # 体检：断链、工具检测、一致性等，只读
skillctl eject --apply                   # 不想用了？把软链换成独立真实拷贝，随时退出
```

所有会改动状态的命令默认只预演、不带 `--apply` 不会真正执行；不带任何参数运行 `skillctl` 能看到完整的场景式速查。

---

## Quickstart

前提：macOS，已安装 `bash`（系统自带的 3.2 就够）。

### 1. 安装管理组件

```bash
git clone <你 fork/克隆到的地址> skill-warehouse
cd skill-warehouse
./install-manager.sh --apply
```

这会把 `skillctl` 和配套脚本安装到 `~/.skill-library/bin/`，之后统一用绝对路径调用：

```bash
~/.skill-library/bin/skillctl <子命令>
```

安装器只替换 `$SKILL_LIBRARY_ROOT/{bin,lib,config}`，从不触碰 `skills/`、`archive/`、`state/`、`catalog.tsv`、shell 启动文件或 `PATH`；升级前会把旧版备份到 `manager-backups/<时间戳>/`。`config/` 内部区别对待：`config/aliases.tsv`（中文别名）和 `config/profiles/` 下的每个场景包文件是你自己的数据，本地已经存在就不会被升级覆盖，只在第一次安装、本地还没有对应文件时才从包里种一份默认值当起点；`config/adapters/`、`config/route-evals.tsv` 等其余内容照常整体跟包同步，升级会拿到新适配器之类的改进。把 `~/.skill-library/bin` 加进你的 `PATH`，或者直接用绝对路径，二选一，README 后面统一用不带路径的 `skillctl` 指代这个绝对路径入口。

### 2. 导入随包的两个示例 Skill

`import` 的来源参数必须是**绝对路径**（相对路径会被拒绝，报错"来源必须是已存在的绝对目录"）。还在仓库根目录下的话：

```bash
skillctl import "$(pwd)/examples/commit-message-writer" --apply
skillctl import "$(pwd)/examples/code-review-checklist" --apply
```

`import` 默认只复制、不删除来源；`config/aliases.tsv` 和 `config/profiles/core` 已经预先配好这两个 Skill 的中文名和默认场景包，所以不需要额外传 `--display-name`。

### 3. 激活场景包

```bash
skillctl profile use core --apply
```

这会在 `~/.agents/skills/` 下建好这两个 Skill 的软链。Codex、Cursor、Gemini CLI 这类"原生共享"工具直接读这个目录，重开一次对话就能看到。

### 4. 把你在用的工具接进来

```bash
skillctl tools detect
```

会显示九个已知适配器（见下文）里哪些已检测到。对软链模式的工具（比如 Claude Code）：

```bash
skillctl tools connect claude-code --apply
```

### 5.（可选）生成本地面板

```bash
skillctl dashboard build --apply
skillctl dashboard open
```

一个自包含的只读 HTML 页面：顶部统计卡片、Skill 列表、场景包成员、工具接入状态。改变激活/连接状态的命令执行后会自动重建，一般不用手动跑。

到这里，你已经有一个能用的仓库了。接下来把你自己的 Skill `import` 进来，参考下面「核心概念」理解场景包怎么组织，或者看「接入清单外的工具」把仓库接进一个不在默认九个里的工具。

---

## 核心概念：仓库（唯一真源）与货架（受管软链）

- **仓库**（`~/.skill-library/skills/`）是全部 Skill 的唯一真源，不在 Codex/Claude/Cursor 等工具的自动扫描路径下，因此不会因为工具扫描逻辑不同而产生冲突或重复。
- **货架** —— 也就是 `~/.agents/skills/` 里的一批相对软链，只把当前场景包需要的 Skill 暴露给工具扫描；软链指向仓库，删除或替换它不会影响仓库里的真实内容。软链**按英文 id 命名**（如 `commit-message-writer`），中文名只是 `catalog.tsv` 里的 `display_name` 字段，仅在 `list`/`status`/面板等展示场景里出现，不会出现在软链文件名或任何路径里。
- 二者的关系：仓库负责"存"，货架负责"露出"。仓库里可以有几十上百个 Skill，但某一时刻真正激活、进入工具上下文的通常只有个位数到十几个（用"场景包"分组）。
- **`profile use` 的语义**（三句话说清楚）：`core` 永远在；切换到某个具名场景包会替换掉其他场景包遗留的成员（不在"core ∪ 目标场景包"里的会被停用）；但通过 `activate` 单独激活、不属于任何场景包的 skill 不受影响，记在 `state/manual.list` 里，切场景包不会把它们清掉。切换时如果有成员被停用，输出会显式列出"将停用 N 个：..."，不会静默发生。随包只带了 `core` 一个场景包（因为示例内容比较少），机制本身不受限——在 `config/profiles/` 下按需新增文件，一行一个 Skill id 即可。

## 中文优先：不用记英文 ID

用户和 AI 都可以直接用自然语言操作，例如："帮我写个提交信息""临时启用代码审查""这个自动匹配不对，给我其他选择"。等价的英文命令（面板和脚本内部用于稳定标识，不要求用户输入）：

```bash
skillctl activate commit-message-writer --apply
skillctl profile use core --apply
```

## 命令参考

只读查询：`list` / `search <关键词>` / `status` / `tools detect` / `dashboard open` / `doctor` / `lint` / `export <id> [--output <绝对路径>]`

会改动状态（默认只预演，加 `--apply` 才真正执行）：`activate` / `deactivate` / `profile use` / `import` / `archive` / `restore` / `tools connect` / `tools disconnect` / `dashboard build` / `eject`

不带参数运行 `skillctl` 看场景式速查，`skillctl help` 看完整参数说明。

```bash
skillctl import /absolute/path/to/skill
skillctl import /absolute/path/to/skill --activate --apply
skillctl import /absolute/path/to/new-version --replace --apply
skillctl deactivate skill-name --apply
skillctl archive skill-name --apply
skillctl restore skill-name --apply
skillctl restore skill-name --archive-id 20260814-124500-ab12cd34 --reactivate --apply
skillctl export skill-name                                    # 默认输出到 ~/Desktop/skill-export-skill-name/
skillctl export skill-name --output /absolute/path/to/somewhere
```

`export` 把仓库里的一个 Skill 打包成不带仓库登记信息的干净拷贝（只有 `SKILL.md` 和内容目录），用来手动上传到 claude.ai 账户库或分享给他人；只读操作，不需要 `--apply`，目标路径已存在时会拒绝执行、不覆盖。

`import` 默认复制来源、不删除原目录；仓库里已有同名同内容版本时报告"已存在"并保持不变，同名不同内容时默认停止，只有显式 `--replace --apply` 才会先把旧版本归档、再换成新版本，且复制失败会自动回滚到旧版本。`--display-name` 是可选参数：首次导入且仓库里没有对应别名时，不提供就默认 `display_name = id`（即中文名展示位置显示英文 id，不会自行翻译）；想要一个中文名，用 `--display-name` 显式提供。

`deactivate` 只移除受管软链；`archive` 把真实 Skill 移入带时间戳和内容哈希的归档目录（`archive/<id>/<归档ID>/`），并写入记录原场景包和受管链接的清单；`restore` 默认恢复最近一个版本但不重新激活，多个历史版本可用 `--archive-id` 指定，只有 `--reactivate --apply` 才会尝试恢复原受管软链（遇到冲突会安全跳过并告警，不覆盖）。没有永久删除命令，`archive` 是唯一的"下架"方式（软删除，可恢复）。

### 体检与内容质量：`doctor` / `lint`

```bash
skillctl doctor   # 仓库/软链健康：断链、货架上未收编进仓库的真实目录、工具检测漏检、manual.list 一致性、catalog 一致性
skillctl lint     # Skill 内容质量：frontmatter 完整性、description 长度、触发词重叠
```

两者都是全程只读、不改动任何文件的诊断命令，逐项给 ✅/⚠️/❌ 加一行具体的修复命令；发现 ❌ 时退出码非零，方便接进 CI 或脚本。改动状态之前先跑一遍 `doctor`，是个好习惯。

### 退出机制：`eject`

```bash
skillctl eject          # 预演：会物化多少条软链、涉及哪些目录、备份写到哪
skillctl eject --apply
```

把所有已连接工具目录（含 `~/.agents/skills` 本身）里受管的软链，逐个替换成当前指向内容的真实拷贝。`--apply` 前会先把将改动的目录备份到 `~/.skill-library/eject-backups/<时间戳>/`，备份失败直接中止、不碰任何文件。这基本等于永久脱离 skillctl 管理——物化之后各工具目录变成互相独立的静态副本，不再随激活状态自动同步。不会改动不归属仓库的外部软链或已经存在的真实目录。

## 低上下文路由（实验性）

```bash
skillctl route "帮我写个 commit message"
skillctl route-status
```

`route` 只读、不落盘，最多返回三个候选，标准输出不超过 1200 字符。自动选择需要同时满足：Top1 命中率 ≥ 90%、Top3 命中率 ≥ 98%、歧义场景误选率 ≤ 5%（`evaluate-router.sh` 评测后写入 `state/router-gate.tsv`，与当前 `catalog.tsv` 哈希绑定）。`route-status` 会核对哈希是否仍然匹配、结果是否仍在有效期内；哈希不匹配、状态缺失或指标不达标时一律视为"自动选择未启用"，此时应该始终用中文名称向用户确认，不替用户自动决定。

这两个命令目前是隐藏的实验性子命令（也可以用 `skillctl experimental route ...` / `skillctl experimental route-status` 调用，效果完全一样），不出现在场景速查和主参考里——不是因为不稳定，而是因为默认样例数据太少，命中率门槛达不到，日常不会用到自动选择。仓库里随附一个 `examples/skillctl-assistant`（教 AI 安全操作 skillctl 本身）之外，还有一个配套的 `skill-router` Skill（在仓库根目录，不在 `examples/` 下，因为它是路由功能的一部分而不是独立示例）——想启用低上下文路由：

```bash
skillctl import "$(pwd)/skill-router" --activate --apply
```

`--activate` 会把它记进 `state/manual.list`，之后切场景包也不会被清掉，不需要另外编辑 `config/profiles/core`。

## 已知软件适配器（九个）

原生模式（直接共享 `~/.agents/skills`，无需连接）：`codex`（ChatGPT 客户端内的 Codex 功能）、`cursor`、`gemini-cli`。
软链模式（有独立的 Skill 目录，需要 `tools connect` 建立软链）：`claude-code`、`kiro`、`trae`、`trae-cn`（TraeCode CN，独立数据目录）、`codebuddy`、`qoder`。

**格式兼容性**：以上九个都能直接接入，前提是它们识别 Skill 的方式跟本仓库一致——一个目录、根目录一份 `SKILL.md`（YAML frontmatter 含 `name`/`description`，正文任意 Markdown）。仓库对外分发的就是这个格式本身，不做任何转换；如果某个工具用的是别的清单格式（比如 JSON manifest），软链过去它大概率读不出来，不能直接照抄这九个的接法，见下面"接入清单外的工具"。

```bash
skillctl tools detect
skillctl tools connect claude-code --apply
skillctl tools disconnect claude-code --apply
```

`tools detect` 按"检测到应用或命令行工具 → 已检测；没有应用/命令行但目录已存在 → 可能是残留目录；两者都没有 → 未检测到"的顺序判断，只覆盖以上九个已批准的软件，不会检测或连接清单之外的工具。软链模式的连接只同步**当前激活集合**（`~/.agents/skills` 里的受管软链），不会把整个仓库分发出去；标记为 `unverified` 的适配器默认拒绝连接，需要显式加 `--allow-unverified`。

`app_name` 靠精确匹配 `/Applications/<app_name>.app` 这个文件夹名判断，`cli_command` 靠 `command -v` 查 PATH，两者都不做模糊匹配——本地化显示名、渠道版后缀（如" CN"）跟真实文件夹名对不上，就会被判定"未检测到"，需要手动核实真实文件夹名后修正 `app_name`（`skillctl doctor` 会把这种情况和真的没装区分开，分别给出不同的下一步建议）。`verification` 字段目前只是给人看的说明文字，`tools detect`/面板都不展示它，唯一起作用的场景是字面**精确等于** `unverified` 时触发连接拦截；随包的九个适配器该字段都是描述性中文句子，没有一个会被拦截。

## 接入清单外的工具

不在上面九个批准名单里的工具，接入前先确认它是否也用 `SKILL.md`（YAML frontmatter + Markdown 正文，`name`/`description` 必填）识别 Skill——本仓库对外分发的就是这个原始格式，不做任何转换。格式不兼容的工具无法通过软链直接接入。

确认兼容后，在 `config/adapters/tools.tsv` 里加一行（tab 分隔，8 列）：

```
id	display_zh	mode	global_dir	project_dir	cli_command	app_name	verification
```

| 字段 | 说明 |
|---|---|
| `id` | 稳定英文标识，`tools connect <id>` 用这个 |
| `display_zh` | 中文显示名 |
| `mode` | `native`（原生共享 `~/.agents/skills`）或 `link`（独立目录，需要软链） |
| `global_dir` | `mode=link` 时该工具的 Skill 目录绝对路径，可以用 `~` 开头 |
| `project_dir` | 项目内相对路径，一般是 `.工具名/skills` |
| `cli_command` | 命令行程序名；没有就留空（TSV 空字段，不要填占位符） |
| `app_name` | `/Applications/` 下精确文件夹名，不含 `.app` 后缀；没有 GUI 应用就留空 |
| `verification` | 人工检查提示文字，不影响功能（除非字面写 `unverified`，见上文） |

示例（接入 TraeCode CN 这类本地化/渠道版应用时的写法）：

```
trae-cn	TraeCode CN	link	~/.trae-cn/skills	.trae-cn/skills		Trae CN	确认软链目标为 ~/.agents/skills
```

加完这一行，先 `skillctl tools detect` 确认显示"已检测"（不是就回去核实 `app_name`/`cli_command`），再 `skillctl tools connect <新id>` 不带 `--apply` 看预演结果，确认无误后再 `--apply` 正式连接。验证过一个新适配器、确认真实可用之后，欢迎提 PR 加进默认九个里。

## 只读面板

```bash
skillctl dashboard build --apply
skillctl dashboard open
```

面板是自动生成的自包含 HTML（`dashboard/index.html`），中文优先、英文 ID 弱化展示为技术信息，打开先看到 Skill 文件夹的真实绝对路径（带复制按钮，粘贴到 Finder"前往文件夹" Cmd+Shift+G 可直接跳转，路径随每个人的真实环境自动识别，不是写死的），然后是顶部统计卡片（全部/已激活/仓库中/已归档/缺失冲突各多少个），再往下是 Skill 列表、场景包成员、归档记录、真实目录/外部软链冲突，以及九个适配器的检测状态。归档区块头部同样有一个"归档文件夹"地址（带复制按钮），指向 `archive/` 这个总目录，每个 Skill 归档后就放在这个文件夹下自己的 `<id>` 子目录里。Skill 列表支持按 id/中文名/简介实时搜索（不用点搜索按钮），以及两个互斥的点选模式：「归档模式」开启后点选条目显示红色边框，底部浮出红色「复制归档命令」按钮，点击把对应的 `skillctl archive <id> --apply` 复制到剪贴板并提示"归档是可恢复的下架，随时能用 restore 恢复"；「激活/停用模式」开启后点选条目显示蓝色边框，按每一项**当前的状态**分别生成 `activate` 或 `deactivate`（已激活的生成停用命令，仓库中的生成激活命令），底部浮出蓝色「复制命令」按钮——多选时每个 id 各生成一行命令，混着已激活和未激活的一起选也能一次拿到全部正确的命令。开启任一模式会自动关掉另一个并清空已选。页面标题旁明确标注"只读面板"；所有交互都是纯前端生成命令 + 复制到剪贴板，不新增本地服务，内联脚本不包含任何 `fetch` 或写入型请求。生成失败时保留上一版面板，不会留下半成品文件。`activate`/`deactivate`/`profile use`/`tools connect`/`tools disconnect`/`eject`（以及带 `--activate`/`--reactivate` 的 `import`/`restore`）这些改变激活或连接状态的 `--apply` 命令成功后会自动跑一次 `dashboard build`，一般不需要手动重建；但打开页面看还是要自己跑 `dashboard open`，这一步不会自动发生。

## 迁移已有的 Skill

如果你已经在 `~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills` 这类目录里攒了一批 Skill，想把它们收进仓库统一管理：

```bash
./migrate-skills.sh
./migrate-skills.sh --apply --conflict=identical
```

- 默认只预演，不创建仓库目录，也不创建备份。
- 迁移目标是仓库 `~/.skill-library/skills`，**不是** `~/.agents/skills`。
- **应用前会先创建一份带时间戳的完整备份**，用 `/usr/bin/ditto` 原样克隆每个存在的来源目录（保留符号链接和元数据）；备份任一步失败都会在做任何迁移动作之前中止。
- 名称和内容完全相同的副本可以自动归并（`--conflict=identical`）；同名但内容不同的版本默认保持原样，等待人工选择。
- 真实目录不会被直接删除，归并后的旧副本进入备份目录；不追随或迁移工具目录里的外部软链。
- 迁移脚本本身**不会**重建 `~/.agents/skills` 下的激活软链——那是之后单独运行 `skillctl profile use core --apply` 的职责，两者刻意解耦。

## FAQ

**为什么不直接用某个工具自带的 Skill 市场/在线安装？**
这个项目管的是"我自己已经写好的 Skill，怎么在我用的好几个工具之间共享"，不是内容分发。跟"从哪找到别人写的 Skill"是两个不同的问题，本项目不打算做后者（见 [ROADMAP](ROADMAP.md)）。

**为什么不做成一个桌面 GUI？**
命令行 + 本地只读 HTML 面板已经覆盖日常需要的操作和查看场景，加一层 GUI 增加的是维护成本，不是能力。市面上已经有走 GUI 路线的同类项目（比如 Skills Dock），路线不同，各取所需。

**支持 Windows/Linux 吗？**
不支持，短期内也不打算支持。核心实现依赖 macOS 专属的 `ditto`（保真度更好的文件拷贝）和 `/Applications` 应用检测，移植需要重新设计文件操作层。

**软链会不会把我原来的目录搞坏？**
`activate`/`profile use`/`tools connect` 遇到目标位置已经是真实目录或者不认识的外部软链时，一律跳过、不覆盖，只会提示你两条路：`import` 收编进仓库，或者不管它保留原样。任何触碰真实目录的操作（`eject`、`migrate-skills.sh --apply`）执行前都会先自动备份，备份失败直接中止。

**多个工具会不会互相看到对方的私有状态？**
不会。仓库和货架只是文件系统里的目录和软链，不涉及任何进程间通信或网络请求；`route`/`status` 等命令全程本地只读，不上传、不调用外部服务。

## 发布前检查清单（维护者自查）

- [x] 仓库名（skill-warehouse）与命令名（skillctl）分离，两者独立检索均未发现直接冲突
- [x] 全部脚本通过 `shellcheck`
- [x] 干净账户（无既有 `~/.skill-library`）走通一遍上面的 Quickstart
- [x] 文档描述的行为与代码实际行为逐条核对一致
- [ ] 首次公开发布前，把 `LICENSE` 里的版权署名换成你希望使用的名义（默认写的是 "skill-warehouse contributors"）

## License

[MIT](LICENSE)
