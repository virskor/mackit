# 参与贡献 Mackit

欢迎提 Issue 和 Pull Request。本文说明如何在本机构建、测试，以及本项目的代码约定。

## 环境要求

- macOS 14+
- Xcode 16+（Swift 6）

## 构建与运行

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

./run.sh                  # 编译 debug 并启动（迭代最快）
./run.sh release          # 编译 release 并启动
./run.sh debug -n         # 只编译，不启动
```

也可以直接用 Xcode 打开 `Package.swift`，选择 `Mackit` scheme 运行。开发构建只编本机原生架构。

## 测试

```bash
swift test
```

新增功能请一并补测试，参考 `Tests/MackitTests/` 现有的组织方式。涉及界面文案的改动会由 `LocalizationTests` 校验 key 完整性与占位符一致性。

## 代码约定

- **Swift 6 Strict Concurrency 已开启**，新增代码需通过并发检查；确需豁免时在注释里说明原因
- **注释解释「为什么」，不复述「做什么」**：约束、取舍、踩过的坑才值得写；显而易见的逻辑不写注释
- **面向用户的文案一律走本地化**：代码里不出现面向用户的字面量，统一 `Utilities/L10n.swift`（`L10n.tr` / `L10n.fmt` / `L10n.items`），文案补进 `Sources/Mackit/Resources/Localizable.xcstrings` 的三种语言
- **单复数两套 key（`.one` / `.other`）占位符布局必须一致**——`.one` 里也要写 `%lld`，只把名词换成单数，否则 `%@` 会收到整数，界面一渲染就崩
- 日志走 `Utilities/MackitLog.swift`（`os.Logger`），只记计数、体积、耗时与规则 id，不记文件内容
- 新扫描规则加在 `Engine/RulesCatalog.swift`，与现有规则的组织方式保持一致

## 提交与 PR

- 提交信息用 [Conventional Commits](https://www.conventionalcommits.org/)：`feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:`，描述用中文即可
- PR 保持小步、聚焦；说明动机与影响面，关联相关 Issue
- 合并前自查：`swift build` 通过、`swift test` 通过、文案已补三种语言

## 安全

- 私钥、证书、凭据（`*.p8` / `*.pem` / `*.key` / `*.p12` 等）**永不进仓库**，`.gitignore` 已挡住；建议安装 pre-commit hook 兜底：`Scripts/install-git-hooks.sh`（换机器克隆后跑一次）
- 发布链路的凭据管理见 [docs/RELEASE.md](docs/RELEASE.md)

## 行为准则

参与本项目即表示你遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
