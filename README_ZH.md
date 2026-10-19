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

1. **扫** — 并发枚举 60+ 条规则，把散落各处的缓存、构建产物、残留文件统一找出来，流式回报，扫描同时就能看到体积；
2. **标** — 每一项标注风险等级（安全 / 需留意 / 谨慎）与完整路径，删之前就知道会发生什么；
3. **勾** — 默认不自动勾选任何项，逐项确认后再清理，也可以按风险等级一键全选安全项；
4. **删** — 移入废纸篓（可撤销）或永久删除；命令行清理项直接调用工具自带的清理命令。

## 功能特性

- **一键扫描**：60+ 条路径规则 + 12 条命令行清理规则，流式填充列表，扫描中即可交互
- **三级风险标识**：`安全`（纯缓存，删后由工具自动重建）/ `需留意`（需重新下载或重新构建）/ `谨慎`（废纸篓、iOS 备份等，需额外确认）
- **应用卸载**：扫描 `/Applications` 与 `~/Applications` 已安装应用，连同 `~/Library` 下的残留文件（应用支持、缓存、容器、偏好设置、登录项等）一起清理；正在运行的应用拒绝卸载
- **项目构建产物扫描**：自定义目录（如 `~/Projects`），找出 `node_modules`、`build`、`Pods`、`.dart_tool`、`DerivedData`、`target`、`.venv` 等可重建目录
- **命令行清理**：`go clean -cache`、`npm cache clean`、`brew cleanup`、`dart pub cache clean` 等
- **菜单栏面板**：常驻菜单栏图标，面板内可清理空间、CPU / 内存 / 温度、内存占用排行与一键「释放内存」、磁盘可用空间、CPU 曲线
- **桌面悬浮统计窗**：可选的常驻悬浮条，CPU / 内存 / 温度紧凑排布，任何壁纸可读，可拖动、位置记忆，只活在托盘进程里
- **硬件检测**：机型、磁盘、电池等静态信息
- **系统风格 UI**：SwiftUI 侧栏 + 表格 + 工具栏，原生右键菜单、键盘快捷键、搜索、点击表头排序
- **多语言**：简体中文 / English / 繁體中文，默认跟随系统语言
- **安全防护**：内置受保护路径清单，系统目录、钥匙串等位置一律拒绝操作

## 截图

![Mackit 主窗口](docs/images/main-window.png)

> 菜单栏面板、桌面悬浮窗、硬件检测页的截图待补充。

## 安装

### 下载预编译版本（推荐）

前往 [Releases](https://github.com/virskor/mackit/releases) 下载最新 DMG，打开后把 Mackit 拖入 Applications。

- 通用二进制（arm64 + x86_64），Apple silicon 与 Intel Mac 通用
- 要求 macOS 14 或更高版本（Intel 机型需可升级到 macOS 14）
- 首次安装用 DMG，后续更新走应用内 Sparkle 自动更新

### 从源码构建

需要 macOS 14+ 与 Xcode 16+（Swift 6）：

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

# 方式一：一键编译并启动（debug，迭代最快）
./run.sh

# 方式二：构建 release 版 Mackit.app 再启动
Scripts/build-app.sh release
open Mackit.app
```

也可以在 Xcode 中打开 `Package.swift`，选择 `Mackit` scheme 运行。开发构建只编本机原生架构，迭代最快；分发用的通用二进制（arm64 + x86_64）见 [发布说明](docs/RELEASE.md)。

运行测试：

```bash
swift test
```

## 使用

1. 首次打开会自动扫描；**默认不勾选任何项**，删什么由你决定
2. 用侧栏按分类查看，或在工具栏搜索条目 / 路径
3. 在「设置 › 项目目录」中添加代码根目录，扫描 `node_modules` 等构建产物
4. 卸载应用：在「应用」分类右键点击应用本体，选「连同残留文件一起卸载…」（或「仅清理残留文件…」）
5. 勾选后点击工具栏「清理 X GB」，确认面板会列出明细与风险提示
6. 建议保持「移入废纸篓」，确认无误后再清空废纸篓

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
| 应用 | `/Applications` 与 `~/Applications` 已安装应用，及其在 `~/Library` 的残留文件（应用支持、缓存、容器、偏好设置、ByHost、窗口状态、HTTP 存储、WebKit、Cookie、应用脚本、登录项、日志、崩溃报告） |
| 项目构建产物 | node_modules、build、Pods、.gradle、.dart_tool、DerivedData、dist、target、.venv、__pycache__ 等 |
| Xcode | DerivedData、Archives、iOS/watchOS DeviceSupport、DocumentationCache、模块缓存 |
| 模拟器 | dyld 缓存、设备内应用缓存、设备临时目录、模拟器日志 |
| Android / Gradle | Gradle caches、wrapper 发行包、daemon 日志、Android Studio 缓存、Kotlin/Native、Maven 仓库 |
| Node / 前端 | npm `_cacache`、Yarn、pnpm store、Bun、node-gyp、TypeScript、ESLint、Deno |
| Flutter / Dart | pub-cache（hosted / git / temp）、Dart Analysis Server |
| Go | go-build 缓存、模块下载缓存 |
| Rust | cargo registry cache/src、Git 依赖库 |
| Python | pip、uv、Poetry、pre-commit 缓存 |
| CocoaPods | CocoaPods 缓存、Carthage 缓存、Spec 仓库 |
| IDE | JetBrains、VS Code / Cursor 缓存与日志 |
| Homebrew | 下载缓存 |
| 系统与应用 | `~/Library/Caches`、沙盒应用缓存、日志、崩溃报告、iOS 备份 |
| 废纸篓 | `~/.Trash` 中的文件 |

命令行清理项会归入各自工具的分类下，与对应的路径规则展示在一起。

### 应用卸载

「应用」分类随主扫描一起产生。每个应用在表格里占一行，显示真实图标、版本、体积与残留文件数；每条残留文件也是独立一行，可单独勾选。右键点击应用本体有两个快捷入口：

- **连同残留文件一起卸载…**：勾选应用本体加它的全部残留文件，进入清理确认
- **仅清理残留文件…**：只清残留、保留应用

卸载复用统一的清理流程：应用本体与残留文件都按「设置 › 清理方式」移入废纸篓（可撤销）或永久删除。正在运行的应用会被拒绝卸载并在结果中提示先退出。残留文件按位置标注风险等级——缓存、日志为「安全」，应用支持、偏好设置、容器等可能保留用户数据的为「需留意」。

如果只用表格复选框勾了应用本体，清理确认面板会提示还有多少关联文件没勾选（按应用列出条数与体积），并给出「全部勾选」一键补上，避免卸载完只剩一个空壳目录、缓存还留在磁盘上。

已知限制：Group Containers（需逐个应用读 entitlements）、应用自带的卸载器、系统级 LaunchAgents/Daemons（需管理员权限）暂不覆盖；Spotlight 全盘发现装在自定义位置的应用也不在范围内。

## 权限说明

Mackit 需要读取 `~/Library`、`~/.pub-cache`、`~/.gradle`、`/Applications` 等位置，因此**未启用 App Sandbox**。`~/Library` 下的部分路径需要「完全磁盘访问」权限，用户可在「系统设置 › 隐私与安全性 › 完全磁盘访问」中手动开启。在终端中打开路径时会请求控制 Terminal 的 Apple Events 权限（`NSAppleEventsUsageDescription`）。托盘面板的「释放内存」会请求管理员授权并执行 `purge`（清空磁盘文件缓存，不影响应用自身占用的内存）。CPU、内存与内存占用排行取自系统公开接口（`host_statistics64`、`proc_pid_rusage`）；macOS 没有公开的温度数值接口，温度显示的是系统热状态。

## 开发

### 架构：主程序 + 托盘 agent

Mackit 是两个进程、同一份二进制，装在两个 bundle 里按 bundle ID 分角色：

| | Mackit.app（`cn.mingcui.mackit`） | MackitAgent.app（`cn.mingcui.mackit.agent`） |
| --- | --- | --- |
| 形态 | regular，有 Dock 图标 | LSUIElement，只在菜单栏 |
| 职责 | 主窗口、扫描、清理、设置、Sparkle 更新 | 菜单栏图标与面板、桌面悬浮统计窗、系统监控轮询 |
| 生命周期 | 关窗即退出 | 常驻；登录项在登录时拉起 |

**关掉主窗口 = 主进程退出 = Dock 图标消失，而菜单栏监控一分钟不停**——这就是关窗后 Dock 图标消失、托盘继续运行的实现方式，全程不做任何 activation policy 切换（运行期在 regular 与 accessory 之间切换，macOS 每次都会重建菜单栏并增删 Dock 磁贴，菜单栏闪一下、整行 Dock 图标左右位移都是这么来的）。

两个进程的协作（`Sources/Mackit/IPC/`）：

- **命令**：agent 发分布式通知（打开窗口 / 设置 / 硬件 / 清理 / 退出 / Toast）；主程序没在跑时命令先落盘，启动后读走补执行（冷启动补偿）
- **状态**：主程序把扫描 / 清理状态广播给 agent，面板头部因此能显示「可清理体积」与勾选数；监控数据反过来只由 agent 自己轮询——主程序退出后也必须继续跳动
- **设置**：共享文件 `~/Library/Application Support/Mackit/shared-settings.plist`，主程序写、agent 读，改完广播刷新。不用 App Group：ad-hoc 签名下 Group Container 解析不出来（cfpregs 报 `Container: (null)` 后整个源被 detach），只有换成付费 Developer ID 签名才恢复，开发迭代不能绑在证书上
- **登录项**：注册的是 agent（`SMAppService.loginItem`），登录时只出现菜单栏图标；主程序启动时若 agent 不在跑会补拉，运行期间每 30 秒看护一次（agent 崩溃后托盘能自愈）
- **单实例**：同 bundle ID 只允许一个 agent——注册登录项的同一瞬间 launchd 会立即拉起一个，若主程序此前已拉起过就会出现两个托盘图标，后启动的实例看到前辈就让位
- **常驻保护**：agent 的 Info.plist 关闭 `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination`，启动时再调用 `disableAutomaticTermation`

### macOS 14 兼容

最低就是编译目标 macOS 14：源码里没有高于 14.0 的 API（`swift build` 对 14.0 目标零可用性警告）。唯一需要 macOS 15.0+ 运行时的 `withTaskGroup(of:returning:isolation:body:)` 以弱导入加运行时版本判断的方式编入二进制，14.x 上走本地回退实现，不会解析到缺失符号。硬件信息页、菜单栏监控在 Apple silicon 与 Intel 两种架构下走同一套公开接口（`HardwareSampler` 对 Intel 无 perflevel 的情况有退化处理）。

### 多语言

界面文案集中在 `Sources/Mackit/Resources/Localizable.xcstrings`（String Catalog），源语言为简体中文，另含英语与繁体中文两份翻译。代码不出现任何面向用户的字面量，统一走 `Utilities/L10n.swift`：

```swift
Text(verbatim: L10n.tr("toolbar.rescan"))                 // 静态文案
Text(verbatim: L10n.fmt("toast.trashed", item.title))     // 带占位符：%@ / %lld
Text(verbatim: L10n.items(count))                         // 「N 项」，单复数已处理
```

新增语言：在 Xcode 里打开该 catalog，点击左下角 `+` 添加语言并翻译即可，无需改代码。新增文案时在 catalog 中补 key，测试里的 `LocalizationTests` 会校验 key 是否齐全、占位符是否与调用处一致。

界面语言的选择在 `Utilities/AppLanguage.swift`：「跟随系统」加三种语言，存进 UserDefaults 的 `appLanguage`，并同步写 App 域的 `AppleLanguages`——CFBundle 的字符串查找读这个键，重启后即按它解析（Sparkle 更新界面、系统文件面板同样跟随）。之所以要重启而不是进程内切换：扫描结果的标题与说明在创建时按当前语言固化，进程内刷新只会得到新旧混排的列表（详见源码注释）。

单复数两套 key（`.one` / `.other`）必须保持占位符布局一致——`.one` 里也要写 `%lld`，只把名词换成单数；否则 `%@` 会收到整数，界面一渲染就崩。

### 日志

生命周期事件（扫描 / 清理的开始、完成、取消、失败）与窗口形态变化都走统一的 `os.Logger`（subsystem = bundle ID），release 构建同样记录。两个进程各记各的：主程序是 `cn.mingcui.mackit`，托盘 agent 是 `cn.mingcui.mackit.agent`。实时观察：

```bash
log stream --predicate 'subsystem == "cn.mingcui.mackit"' --level info
# 托盘 agent 的日志（启动、拉起、看护）
log stream --predicate 'subsystem == "cn.mingcui.mackit.agent"' --level info
# 逐目录的枚举细节（跳过了哪些不可读目录）加 --level debug
```

「控制台」App 里按 subsystem 过滤即可。只记计数、体积、耗时与规则 id，不记文件内容。

### 项目结构

```
Sources/Mackit/
├── MackitApp.swift               # 入口派发（@main 按 bundle ID 分角色）+ 主程序窗口/菜单 + 共用 AppDelegate
├── AgentApp.swift                # 托盘 agent 入口（MenuBarExtra + 标签）
├── Models/                       # 数据模型：清理项、分类、风险等级、扫描规则、排序比较器
├── Engine/
│   ├── RulesCatalog.swift        # 60+ 条扫描规则与 12 条 CLI 清理命令
│   ├── AppScanner.swift          # 已安装应用发现与残留文件探测
│   ├── FileSystem.swift          # 体积计算、通配符展开、工具定位、卷容量
│   ├── Scanner.swift             # 并发扫描 + 项目目录遍历
│   └── Cleaner.swift             # 删除 / 废纸篓 / 命令行执行
├── Monitor/                      # CPU / 内存 / 热状态采样、硬件信息、内存释放
├── IPC/                          # 两进程命令 / 状态 / 设置变更通道（分布式通知 + 共享 plist）
├── Updater/
│   └── UpdateController.swift    # Sparkle 自动更新
├── ViewModels/
│   └── AppViewModel.swift        # 状态机：扫描、选择、清理、设置（两个进程各持一份）
├── Views/                        # SwiftUI 界面：主窗口、托盘面板、悬浮窗、设置、硬件检测
│   └── Components/               #   跨视图复用组件（徽标、进度环、提示行、流式布局…）
└── Utilities/
    ├── AppLanguage.swift         # 界面语言选择（跟随系统 + 三语言，写 AppleLanguages）
    ├── MackitLog.swift           # 统一 os.Logger 封装
    ├── Formatters.swift          # 字节与时间格式化
    ├── LaunchAtLogin.swift       # 开机启动注册（指向内嵌的 MackitAgent.app）
    └── L10n.swift                # 本地化查找（String Catalog）
    Resources/
    ├── Localizable.xcstrings     # 三语言文案（zh-Hans / en / zh-Hant）
    └── sparkle-blue.png          # 品牌图标（应用内展示与 App 图标共用）
Scripts/                          # 构建 / 打包 / 图标生成脚本
Tests/MackitTests/                # 22 个测试文件
```

### 测试

`swift test`。22 个测试文件覆盖扫描引擎、清理引擎、规则目录、应用卸载、共享存储、排序比较器、本地化 key 完整性、更新控制器等。

### 发布

签名、公证、DMG 与 Sparkle 更新链路是维护者向的内容，见 [docs/RELEASE.md](docs/RELEASE.md)。

## 贡献

欢迎提 Issue 与 PR。构建、测试与代码约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。参与本项目即表示你遵守 [行为准则](CODE_OF_CONDUCT.md)。

## 安全

私钥、证书与凭据**不进仓库**：`secrets/` 与各类 `*.p8` / `*.pem` / `*.key` 被 `.gitignore` 挡住，pre-commit hook（`Scripts/install-git-hooks.sh` 安装）还会扫描暂存区拦截私钥。发现安全问题请勿公开提 Issue，请通过 GitHub Security Advisory 私下提交。

## 许可证

[MIT](LICENSE) © 2026 virskor

## 致谢

- [Sparkle 2](https://sparkle-project.org/) — 应用内自动更新
