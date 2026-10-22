<div align="center">

<img src="Sources/Mackit/Resources/sparkle-blue.png" width="120" alt="Mackit 图标">

# Mackit

**macOS 开发缓存清理工具** — 把工具链留下的可再生缓存统一扫出来，逐项勾选、标注风险，把磁盘空间拿回来。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1f88d8?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/license-MIT-3da639?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/virskor/mackit?style=flat-square)](https://github.com/virskor/mackit/releases)
[![Downloads](https://img.shields.io/github/downloads/virskor/mackit/total?style=flat-square)](https://github.com/virskor/mackit/releases)

[简体中文](README_ZH.md) · [English](README.md)

🌐 [官方网站 / 落地页](https://www.mingcui.cn/mackit/)

</div>

---

## 为什么有 Mackit

Go、Node、Yarn、pnpm、Dart、Flutter、Rust、Python、CocoaPods、Gradle、Xcode、Android Studio…… 这些工具运行时都会在本地留下大量**可再生的缓存**：包下载缓存、构建中间产物、模块缓存、模拟器数据、工具索引。单个看不占多少，日积月累就是几十 GB；而它们在 Finder 里散落在十几处隐藏目录，既看不出体积，也不敢随便删。

Mackit 做的事情：

1. **扫** — 并发枚举 69 条路径规则，把散落各处的缓存、构建产物、残留文件统一找出来，流式回报，扫描同时就能看到体积；
2. **标** — 每一项标注风险等级（安全 / 需留意 / 谨慎）与完整路径，删之前就知道会发生什么；
3. **选** — 默认一个都不勾，由你逐项决定，也可以一键全选所有"安全"项；
4. **删** — 移入废纸篓（可恢复）或直接彻底删除；命令行条目调用工具自带的清理命令。

## 功能

- **一键扫描**：69 条路径规则 + 12 条命令行清理规则，扫描进行中就流式填入列表
- **三级风险**：`安全`（纯缓存，工具会自己重建）/ `需留意`（需要重新下载或重新构建）/ `谨慎`（废纸篓、iOS 备份等，需额外确认）
- **应用卸载**：扫描 `/Applications` 与 `~/Applications` 已安装应用，连同 `~/Library` 下的残留（应用支持、缓存、容器、偏好设置、登录项……）一并列出；正在运行的应用会被拒绝
- **构建产物扫描**：指定一个目录（如 `~/Projects`），找出 `node_modules`、`build`、`Pods`、`.dart_tool`、`DerivedData`、`target`、`.venv` 等可重建目录
- **命令行清理**：`go clean -cache`、`npm cache clean`、`brew cleanup`、`dart pub cache clean` 等
- **通用清理**：面向日常使用的独立模块——浏览器缓存（Chrome 家族、Chromium、Edge、Brave、Arc、Opera、Firefox、QQ 浏览器）、应用包内无用的语言文件（`LanguageFileScanner`，只整目录删除 `.lproj` 以保证代码签名有效，白名单保留中文任意变体、英文与 Base）、`~/Downloads` 里的安装包与压缩包；规则行按系统垃圾 / 浏览垃圾分组，默认勾到"推荐"为止，"谨慎"行（废纸篓、下载的安装包、iOS 备份）需自行勾选
- **缓存免卸载清理**：残留扫描按内容拆分——可再生的垃圾（缓存、HTTP 存储、WebKit 数据）归入通用模块的应用垃圾，数据（偏好设置、应用支持、容器、cookies）仍随应用走卸载流程，删除它们是用户的明确意图
- **菜单栏面板**：常驻菜单栏图标，点开即可看可清理空间、CPU / 内存 / 温度、按内存排序的应用列表（一键"释放内存"）、剩余磁盘空间与 CPU 曲线
- **桌面悬浮状态栏**：可选的常驻置顶条，紧凑显示 CPU / 内存 / 温度，任意壁纸下都清晰可读，可拖动并记忆位置，只存在于托盘进程
- **磁盘空间分析**：侧边栏"工具"分区（清理条目下方）的工具页，回答"空间都去哪了"——从启动磁盘逐层下钻，每个文件夹的递归体积，以及所选文件夹构成的 treemap
- **硬件信息**：机型、磁盘、电池等静态信息
- **原生界面**：SwiftUI 侧边栏 + 表格 + 工具栏，原生右键菜单、快捷键、搜索与点击排序的表头
- **本地化**：简体中文 / 英文 / 繁体中文，默认跟随系统语言
- **安全护栏**：内置受保护路径清单；系统目录与钥匙串一律拒绝

## 截图

![Mackit 主窗口](docs/images/main-window.png)

> 菜单栏面板、桌面悬浮条与硬件信息页的截图待补。

## 安装

### 下载预编译版本（推荐）

从 [Releases](https://github.com/virskor/mackit/releases) 取最新的 DMG，打开后把 Mackit 拖进"应用程序"。

- 通用二进制（arm64 + x86_64），Apple 芯片与 Intel Mac 通吃
- 需要 macOS 14 或更高版本（Intel 机型须能运行 macOS 14）
- 首次安装走 DMG；之后的更新走 App 内 Sparkle 自动更新

### 从源码构建

需要 macOS 14+ 与 Xcode 16+（Swift 6）：

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

# 方式一：一步构建并启动（debug，迭代最快）
./run.sh

# 方式二：构建 release 版 Mackit.app，再启动
Scripts/build-app.sh release
open Mackit.app
```

也可以在 Xcode 里打开 `Package.swift` 运行 `Mackit` scheme。开发构建只编译当前原生架构；可发布的通用二进制（arm64 + x86_64）见[发布说明](docs/RELEASE.md)。

运行测试：

```bash
swift test
```

## 使用

1. 首次启动会自动扫描；**默认一个都不勾**——删什么由你决定
2. 在侧边栏按分类浏览，或从工具栏搜索项目 / 路径
3. 在"设置 › 项目目录"下添加你的代码根目录，即可扫描 `node_modules` 等构建产物
4. 卸载应用：在"应用"分类中右键应用行 → "连同残留文件卸载…"（或"仅清理残留文件…"）
5. 勾选后点击工具栏的"清理 X GB"；确认面板会列出明细与风险说明
6. 保持"移入废纸篓"开启，确认无误后再清空废纸篓

快捷键：

| 快捷键 | 作用 |
| --- | --- |
| `⌘R` | 重新扫描 |
| `⌘⌫` | 清理所选 |
| `⌘⌥S` | 全选安全项 |
| `⌘,` | 设置 |

## 覆盖范围

| 分类 | 内容 |
| --- | --- |
| 应用 | `/Applications` 与 `~/Applications` 的已安装应用，及其 `~/Library` 残留（应用支持、缓存、容器、偏好设置、ByHost、窗口状态、HTTP 存储、WebKit、cookies、AppleScript、登录项、日志、崩溃报告） |
| 构建产物 | node_modules、build、Pods、.gradle、.dart_tool、DerivedData、dist、target、.venv、__pycache__ 等 |
| Xcode | DerivedData、Archives、iOS/watchOS DeviceSupport、DocumentationCache、模块缓存 |
| 模拟器 | dyld 缓存、设备内应用缓存、设备临时目录、模拟器日志 |
| Android / Gradle | Gradle 缓存、wrapper 发行包、守护进程日志、Android Studio 缓存、Kotlin/Native、Maven 仓库 |
| Node / 前端 | npm `_cacache`、Yarn、pnpm store、Bun、node-gyp、TypeScript、ESLint、Deno |
| Flutter / Dart | pub-cache（hosted / git / temp）、Dart Analysis Server |
| Go | go-build 缓存、模块下载缓存 |
| Rust | cargo registry 缓存/src、git 依赖 |
| Python | pip、uv、Poetry、pre-commit 缓存 |
| CocoaPods | CocoaPods 缓存、Carthage 缓存、spec 仓库 |
| IDE | JetBrains、VS Code / Cursor 的缓存与日志 |
| Homebrew | 下载缓存 |
| 系统与应用 | `~/Library/Caches`、沙盒应用缓存、日志、崩溃报告、iOS 备份 |
| 废纸篓 | `~/.Trash` 中的文件 |

命令行清理条目归入对应工具的分类，与相应的路径规则并列展示。

### 应用卸载

"应用"分类与主扫描一同产出。每个应用在表格中占一行，显示真实图标、版本、体积与残留文件数；每个残留文件同时也是独立的一行，可以单独勾选。右键应用行提供两个快捷操作：

- **连同残留文件卸载…**：勾选应用本身及其全部残留文件，并打开清理确认
- **仅清理残留文件…**：只清理残留，保留应用

卸载复用统一的清理流程：应用与残留文件都遵循"设置 › 清理方式"的设置——移入废纸篓（可恢复）或直接删除。正在运行的应用会被拒绝，并在结果中提示你先退出。残留文件按位置标注风险——缓存与日志为"安全"；应用支持、偏好设置、容器等可能存有用户数据的位置为"需留意"。

若只勾选应用本身，清理确认面板会提示每个应用还有多少关联文件未勾选（数量与体积），并提供"全选"快捷操作，避免最后只剩一个空目录、缓存还留在磁盘上。

已知限制：Group Containers（需要读取各应用的 entitlement）、应用自带的卸载程序与系统级 LaunchAgents/Daemons（需要管理员权限）不在覆盖范围内；通过完整 Spotlight 扫描发现的自定义位置安装的应用也不在范围内。

## 权限

Mackit 需要读取 `~/Library`、`~/.pub-cache`、`~/.gradle`、`/Applications` 等位置，因此**未启用 App Sandbox**。`~/Library` 下的部分路径需要"完全磁盘访问权限"，可在"系统设置 › 隐私与安全性 › 完全磁盘访问权限"中手动授予。在终端中打开路径会请求控制终端的 Apple Events 权限（`NSAppleEventsUsageDescription`）。托盘面板的"释放内存"会请求管理员授权并执行 `purge`（丢弃文件缓存，不影响应用自身占用的内存）。磁盘空间分析工具在扫描时刻意不进入 `~/Documents`、`~/Desktop`、`~/Downloads`——枚举它们会弹出系统访问对话框——这些文件夹会被列为"未扫描"，可按需扫描（点一下，或授予完全磁盘访问权限以完整扫描）。CPU、内存与各应用内存来自公开系统接口（`host_statistics64`、`proc_pid_rusage`）；macOS 没有公开的温度接口，所示温度为系统热状态。

## 开发

### 架构：主 App + 托盘代理

Mackit 是同一份二进制里的两个进程，打成两个 bundle，通过 bundle ID 切换角色：

| | Mackit.app（`cn.mingcui.mackit`） | MackitAgent.app（`cn.mingcui.mackit.agent`） |
| --- | --- | --- |
| 形态 | 常规应用，有 Dock 图标 | LSUIElement，只有菜单栏 |
| 职责 | 主窗口、扫描、清理、设置、Sparkle 更新 | 菜单栏图标与面板、桌面状态栏、系统监控 |
| 生命周期 | 关窗即退出 | 常驻；登录项在登录时启动 |

**关掉主窗口 = 主进程退出 = Dock 图标消失，而菜单栏监控照常每分钟走一次**——"窗口关了但托盘还在"就是这样实现的，全程不做运行时的 activation policy 切换（regular 与 accessory 之间运行时切换会让 macOS 重建菜单栏、反复增删 Dock 磁贴，这正是菜单栏闪烁、Dock 行串位的原因）。

两个进程如何协作（`Sources/Mackit/IPC/`）：

- **命令**：代理通过分布式通知下发（打开窗口 / 设置 / 硬件 / 清理 / 退出 / 浮窗提示）；主 App 未运行时，命令先落盘，待其启动后补发（冷启动补偿）
- **状态**：主 App 向代理广播扫描 / 清理状态，面板头部因此能显示"可清理体积"与已勾选数量；监控数据则由代理独享轮询——主 App 退出后它仍须继续走时
- **设置**：共享文件 `~/Library/Application Support/Mackit/shared-settings.plist`，由主 App 写入、代理读取，变更时广播刷新。不用 App Groups：ad-hoc 签名下 Group Container 无法解析（cfpregs 报 `Container: (null)`，整个源码会被 detach），只有付费 Developer ID 签名才能恢复——开发迭代不能依赖证书
- **登录项**：注册代理（`SMAppService.loginItem`），登录时只出现菜单栏图标；代理缺失时主 App 会重新拉起了它，并在运行期间每 30 秒照看一次（代理崩溃后托盘自愈）
- **单实例**：每个 bundle ID 只允许一个代理——注册登录项会让 launchd 在同一瞬间拉起一个，若主 App 已经起过一个，就会出现两个托盘图标；后起的实例见到前辈即退让
- **常驻**：代理的 Info.plist 关闭 `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination`，并在启动时调用 `disableAutomaticTermation`

### macOS 14 兼容

底线是编译目标 macOS 14：没有任何源码使用 14.0 以上的 API（针对 14.0 目标 `swift build` 零可用性警告）。唯一需要 macOS 15.0+ 运行时的符号 `withTaskGroup(of:returning:isolation:body:)` 以弱链接加运行时版本检查的方式编入，在 14.x 上回退到本地实现，因此不会出现符号解析失败。硬件页与菜单栏监控在 Apple 芯片和 Intel 上使用同一套公开接口（Intel 没有 perf level 时 `HardwareSampler` 会优雅降级）。

### 本地化

所有面向用户的字符串都放在 `Sources/Mackit/Resources/Localizable.xcstrings`（String Catalog），以简体中文为源语言，另有英文与繁体中文翻译。代码中不出现面向用户的字面量，一切都经过 `Utilities/L10n.swift`：

```swift
Text(verbatim: L10n.tr("toolbar.rescan"))                 // 静态字符串
Text(verbatim: L10n.fmt("toast.trashed", item.title))     // 带占位符：%@ / %lld
Text(verbatim: L10n.items(count))                         // "N 项"，复数已处理
```

新增语言：在 Xcode 中打开 catalog，点左下角 `+` 再翻译即可，无需改代码。新字符串以键的形式加入 catalog；测试套件中的 `LocalizationTests` 会对照调用点检查键完整性与占位符一致性。

界面语言选择在 `Utilities/AppLanguage.swift`："跟随系统"外加三种语言，存于 UserDefaults 的 `appLanguage`，并镜像进 App 域的 `AppleLanguages`——CFBundle 的字符串查找读这个键，因此重启后生效（Sparkle 的更新界面与系统文件面板也随之切换）。为什么是重启而不是进程内切换：扫描结果的标题与描述在创建时即以当前语言定稿，进程内刷新只会得到一份中英混杂的列表（详见源码注释）。

两个复数键（`.one` / `.other`）必须保持相同的占位符布局——`.one` 也要有 `%lld`，只把名词换成单数形式；否则 `%@` 会收到整数，界面首次渲染即崩溃。

### 日志

生命周期事件（扫描 / 清理的开始、完成、取消、失败）与窗口形态变化统一走 `os.Logger`（subsystem = bundle ID），release 构建同样记录。两个进程各按自己的 subsystem 记录：主 App 是 `cn.mingcui.mackit`，托盘代理是 `cn.mingcui.mackit.agent`。实时查看：

```bash
log stream --predicate 'subsystem == "cn.mingcui.mackit"' --level info
# 托盘代理日志（启动、重启、照看）
log stream --predicate 'subsystem == "cn.mingcui.mackit.agent"' --level info
# 逐目录枚举细节（跳过了哪些不可读目录）：加 --level debug
```

在"控制台"App 中按 subsystem 过滤。只记录数量、体积、耗时与规则 id——绝不记录文件内容。

### 项目结构

```
Sources/Mackit/
├── MackitApp.swift               # 入口分发（@main 按 bundle ID 切换角色）+ 主窗口/菜单 + 共享 AppDelegate
├── AgentApp.swift                # 托盘代理入口（MenuBarExtra + 标签）
├── Models/                       # 数据模型：项目、分类、风险等级、扫描规则、比较器
├── Engine/
│   ├── RulesCatalog.swift        # 69 条扫描规则与 12 条 CLI 清理命令
│   ├── AppScanner.swift          # 已安装应用发现与残留检测
│   ├── FileSystem.swift          # 体积计算、通配、工具查找、卷容量
│   ├── Scanner.swift             # 并发扫描 + 项目目录遍历
│   ├── DiskAnalyzer.swift        # 磁盘空间分析：逐目录列举 + 递归测量
│   ├── TreemapLayout.swift       # squarified treemap 布局（纯函数）
│   └── Cleaner.swift             # 删除 / 废纸篓 / 命令执行
├── Monitor/                      # CPU / 内存 / 温度采样、硬件信息、内存释放
├── IPC/                          # 进程间命令 / 状态 / 设置通道（分布式通知 + 共享 plist）
├── Updater/
│   └── UpdateController.swift    # Sparkle 自动更新
├── ViewModels/
│   ├── AppViewModel.swift        # 状态机：扫描、选择、清理、设置（每进程一个）
│   └── DiskAnalysisModel.swift   # 磁盘分析页：导航、流式测量、缓存
├── Views/                        # SwiftUI：主窗口、托盘面板、悬浮条、设置、硬件、磁盘分析
│   └── Components/               #   可复用组件（徽章、进度环、提示行、流式布局……）
└── Utilities/
    ├── AppLanguage.swift         # 界面语言选择（系统 + 三种语言，写 AppleLanguages）
    ├── MackitLog.swift           # 统一 os.Logger 封装
    ├── Formatters.swift          # 字节与时间格式化
    ├── LaunchAtLogin.swift       # 登录项注册（指向内置的 MackitAgent.app）
    └── L10n.swift                # 本地化查找（String Catalog）
    Resources/
    ├── Localizable.xcstrings     # 三种语言（zh-Hans / en / zh-Hant）
    └── sparkle-blue.png          # 品牌图标（App 内展示与应用图标共用）
Scripts/                          # 构建 / 打包 / 图标生成脚本
Tests/MackitTests/                # 36 个测试文件
```

### 测试

`swift test`。36 个测试文件覆盖扫描引擎、清理引擎、规则目录、应用卸载、共享存储、排序比较器、本地化键完整性、更新控制器等。

### 发布

签名、公证、DMG 打包与 Sparkle 更新管线面向维护者，见 [docs/RELEASE.md](docs/RELEASE.md)。

## 贡献

欢迎 Issue 与 PR。构建、测试与代码约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。参与即表示你同意遵守[行为准则](CODE_OF_CONDUCT.md)。

## 安全

私钥、证书与凭据**绝不进入仓库**：`secrets/` 与所有 `*.p8` / `*.pem` / `*.key` 文件均被 `.gitignore` 拦截，pre-commit 钩子（通过 `Scripts/install-git-hooks.sh` 安装）会扫描暂存区兜底拦截私钥。请不要为安全问题开公开 Issue——请通过 GitHub Security Advisory 私下报告。

## 许可证

[MIT](LICENSE) © 2026 virskor

## 致谢

- [Sparkle 2](https://sparkle-project.org/) — App 内自动更新
