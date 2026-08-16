# skill-warehouse（skillctl 开发仓库）

`skillctl` 是"一个仓库、多个货架"的多工具 Skill 管理 CLI + 本地面板，纯 bash +
awk 写的，仅 macOS，兼容系统自带 bash 3.2。仓库根目录就是发布内容本身；项目
定位、命令参考、架构决策（含"不加 GUI"等冻结项）见 README.md / ROADMAP.md，
这里不重复。`work/` 是开发测试套件，不随包安装，只在这个仓库里用。

## 怎么跑

- 全量测试：`work/run_skill_library_tests.sh`（当前 18 套件，纯只读/沙箱，
  不碰真实环境）
- 烟雾测试：`tests/smoke.sh`
- 同步到真实 `~/.skill-library` 验证：`./install-manager.sh --apply`
  ——只替换代码和 adapters/route-evals 等参考配置，用户已有的
  `config/aliases.tsv`/`config/profiles/*` 不会被覆盖（这条曾经不成立，
  真实环境里踩过两次，已在 install-manager.sh 修好）

## 新增测试要走公共隔离前置

任何会 shell 出 `skillctl`/`build-*.sh` 等脚本的新测试，先
`. test_env_common.sh` 再 `skill_test_env_init "$TEST_HOME"`，不要自己手拼
`SKILL_LIBRARY_ROOT` 等一串环境变量——手拼容易漏一个，漏的那个就会落到真实的
`~/.skill-library`；也不要在同一个测试里既调用 `skill_test_env_init` 又给
`SKILLS_ACTIVE`/`SKILL_LIBRARY_ROOT` 之类高优先级变量做全局固定 export 后再靠
每次调用的 `HOME=` 覆盖切换——这两种覆盖方式不会互相跟随，混用会导致
状态/激活结果读到错误目录（已经踩过两次）。

# 已知坑：裸 `$变量` 紧跟中文/全角标点，在 bash 3.2 下会崩

## 现象

`$var` 后面不加分隔符、直接跟一个非 ASCII 字符（中文字、中文标点、全角标点，比如
`；，。、（）` 等），在 macOS 自带的 `/bin/bash`（3.2）下会被解释成变量名的一部分，
触发 `set -u` 下的 `unbound variable`。例如：

```bash
printf '%s' "$members、$display_line"   # 会炸：$members、 被当成一个变量名
printf '%s' "${members}、${display_line}"  # 安全：花括号显式界定了变量名边界
```

这个坑本项目已经在真实开发中踩过三次（分别出现在 `build-dashboard.sh` 的
`render_profiles_section`、`skillctl` 里 `lint_check_frontmatter` 的报错分支、
以及"阶段3：命令收敛"新增的 `usage_error()` 报错分支里），每次都是新写的代码
里悄悄带出来的。

`bash -n` 语法检查完全抓不出这种问题——它只检查语法合法性，不知道这段语法在
运行时会把 `$members、` 解析成一个不存在的变量名。唯一可靠的办法是跑真实的
`/bin/bash 3.2` 手动过一遍，或者靠下面这条静态扫描。

## 规则

任何地方写 `$变量` 时，只要后面紧跟的不是英文字母/数字/下划线/空白/引号，
一律加花括号写成 `${变量}`，不要心存侥幸"这次应该没事"。

## 自动检查

`work/check_cjk_punctuation_after_var.sh`：扫描仓库根目录和 `work/` 下所有
shell 脚本（含无扩展名的 `skillctl`），用 `LC_ALL=C awk` 按字节
匹配"裸 `$变量` 后面直接跟一个 >= 0x80 的字节"，跳过整行注释（注释里的示例文字
不会被求值，不构成真实风险）。命中就打印 `文件:行号` 并返回非零。

这一步是 `work/run_skill_library_tests.sh` 的第一步，命中即整个测试套件直接
失败退出，不会往下跑其余测试套件——不修好这个就没必要看后面的断言结果。
