# 发布说明（维护者向）

本文档面向 Mackit 的维护者：签名、公证、DMG 打包与 Sparkle 自动更新链路。普通用户请回到 [README](../README.md)。

## 签名与分发

`Scripts/build-app.sh` 默认做本地 ad-hoc 签名，只够本机运行。要分发时设置签名身份环境变量，脚本会改用 Developer ID 签名并启用硬化运行时（公证的前置条件）：

```bash
MACKIT_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" Scripts/build-app.sh release
```

版本号默认取自最近的 git tag（`git describe --tags`），可用 `MACKIT_VERSION` / `MACKIT_BUILD_NUMBER` 覆盖。dSYM 会一并拷贝到 `Mackit.app` 旁边，用于符号化崩溃报告。

`Scripts/build-app.sh` 支持的环境变量：

| 变量 | 作用 |
| --- | --- |
| `MACKIT_SIGN_IDENTITY` | 签名身份。设置后按 Developer ID 签名并启用硬化运行时；不设置则本地 ad-hoc 签名 |
| `MACKIT_ARCHES` | 空格分隔的架构列表，如 `"arm64 x86_64"` 构建通用二进制；不设则编本机原生架构（开发迭代默认，最快） |
| `MACKIT_VERSION` | 覆盖版本号（默认取自最近的 git tag） |
| `MACKIT_BUILD_NUMBER` | 覆盖构建号（默认取 commit 计数；Sparkle 靠 `CFBundleVersion` 判断新旧，必须单调递增） |
| `MACKIT_UPDATE_FEED_URL` | Sparkle appcast 地址（https）。设置后主程序 Info.plist 写入 `SUFeedURL` 等键，Sparkle 随应用启动；不设置则开发构建不带更新源，更新相关 UI 隐藏 |
| `MACKIT_UPDATE_PUBLIC_KEY` | EdDSA 公钥（`SUPublicEDKey`），由 Sparkle 的 `generate_keys` 生成；与 feed 配套使用 |
| `MACKIT_UPDATE_AUTO_CHECK` | 自动检查开关默认值，默认 1（true） |
| `MACKIT_UPDATE_AUTO_UPDATE` | 自动下载开关默认值，默认 1（true）：后台下载，安装前仍会征求同意 |
| `MACKIT_UPDATE_INTERVAL` | 定时检查间隔（秒），默认 86400 |

## 打包 DMG

```bash
# 本地构建（不签名，仅本机运行）
Scripts/build-dmg.sh release

# 完整交付版：Developer ID 签名 + 公证 + 装订
MACKIT_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
MACKIT_API_KEY="$HOME/Downloads/AuthKey_XXXXXXXX.p8" \
MACKIT_API_KEY_ID=XXXXXXXX \
MACKIT_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
Scripts/build-dmg.sh release
```

产物在 `dist/`：`Mackit-<version>.dmg` 与同名 `.sha256`。版本号读构建产物的 Info.plist，也就是最近的 git tag（当前为 `v1.0.2`）。

DMG 内含 Applications 快捷方式、安装箭头背景图（`Scripts/make-dmg-background.swift` 生成，坐标与 Finder 布局对应）和卷图标。首次在本机运行时，设置 Finder 布局会弹一次「辅助功能 / 自动化」授权；允许后布局才会生效，拒绝或无人值守时脚本等待 `MACKIT_LAYOUT_TIMEOUT`（默认 60 秒）后跳过布局，不影响 DMG 本身。

默认构建通用二进制（arm64 + x86_64），签名与公证都按 fat 文件整体处理，无需任何额外步骤；构建时会看到一条 `x86_64 architecture is deprecated` 的 SDK 警告（macOS 27 起），编译不受影响。只要 Apple silicon 版时设 `MACKIT_ARCHES=arm64`；脚本会把包内实际架构打印出来，可据此确认交付的不是半截包。

公证凭据三选一：

- App Store Connect API 密钥：`MACKIT_API_KEY`（.p8 路径）+ `MACKIT_API_KEY_ID` + `MACKIT_API_ISSUER`（App Store Connect › 用户和访问 › 密钥里的 Issuer ID）。密钥角色需为 Admin / App Manager / Developer
- Apple ID：`MACKIT_APPLE_ID` + `MACKIT_APP_PASSWORD`（App 专用密码）+ `MACKIT_TEAM_ID`
- 钥匙串 profile：先 `xcrun notarytool store-credentials "mackit-notary" ...`，再设 `MACKIT_NOTARY_PROFILE=mackit-notary`

公证的硬性前提是 Developer ID Application 签名：Apple Development / Apple Distribution 身份的包 notarytool 一律拒收，脚本会直接报错，不会产出看着像交付版、实际过不了 Gatekeeper 的包。钥匙串里没有该证书时，先在 developer.apple.com 对应团队里创建并导入。

## 自动更新（Sparkle 2）

应用内自动更新走 [Sparkle 2](https://sparkle-project.org)：客户端定时拉取 appcast（RSS），按 `CFBundleVersion` 比较出新版本后下载、校验 EdDSA 签名与代码签名、原位替换 bundle 并重启。首次安装仍用 DMG；更新通道是独立的 `.tar.bz2` 归档 + `appcast.xml`，两者托管在同一个 HTTPS 位置。

发布一次更新的完整流程：

```bash
# 1. 生成签名密钥对（只做一次）。公钥打印出来，私钥存进登录钥匙串。
.build/sparkle-tools/bin/generate_keys

# 2. 打 tag 后构建带更新源的交付版（feed 与公钥写进 Info.plist）
git tag v1.2.0
MACKIT_SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
MACKIT_UPDATE_FEED_URL="https://github.com/virskor/mackit/releases/latest/download/appcast.xml" \
MACKIT_UPDATE_PUBLIC_KEY="<generate_keys 输出的公钥>" \
Scripts/build-dmg.sh release

# 3. 打包更新归档并生成 / 追加 appcast
MACKIT_ED_KEY_FILE=<私钥文件路径，不要提交进仓库> \
MACKIT_DOWNLOAD_URL_PREFIX="https://github.com/virskor/mackit/releases/download/v1.2.0/" \
MACKIT_NOTES_FILE=notes-1.2.0.md \
Scripts/build-update.sh
```

第 3 步产出 `dist/updates/appcast.xml` 与 `dist/updates/Mackit-<version>.tar.bz2`，上传到 `MACKIT_DOWNLOAD_URL_PREFIX` 指向的位置即可。更新说明文件（`.html` / `.md` / `.txt`）会嵌入 appcast，不需要单独托管。`MACKIT_UPDATES_DIR` 里的历史归档要一直留着——将来开 delta 更新（二进制差分）需要它们。

## 托管与发布（GitHub Releases）

安装包、更新归档与 appcast 全部托管在 GitHub Releases，无需自备服务器。feed 地址在构建时经 `MACKIT_UPDATE_FEED_URL` 写进 Info.plist，固定为：

```
https://github.com/virskor/mackit/releases/latest/download/appcast.xml
```

每个 Release 需要上传四类资产：

| 资产 | 来源 |
| --- | --- |
| `Mackit-<version>.dmg` | `build-dmg.sh` 产物（已签名、公证、装订） |
| `Mackit-<version>.dmg.sha256` | 同上，随 DMG 生成 |
| `Mackit-<version>.tar.bz2` | `build-update.sh` 产物 |
| `appcast.xml` | 同上，`MACKIT_DOWNLOAD_URL_PREFIX` 必须指向**该 release 自己的 tag** |

`releases/latest` 永远解析到最新的正式版（draft 与预发行都会被跳过），所以：

- 每个 release 都必须带上当版生成的 `appcast.xml`，否则 `latest` 解析到的版本没有 feed，旧版用户检查更新会 404
- 不要把正式版标成预发行（prerelease）——被 `latest` 跳过的版本等于从 feed 里消失
- `MACKIT_DOWNLOAD_URL_PREFIX` 按 tag 区分（`.../releases/download/v1.2.0/`），archives 的 URL 随发布即固定，不会漂移

用 GitHub CLI 发布：

```bash
gh release create v1.2.0 \
  dist/Mackit-1.2.0.dmg dist/Mackit-1.2.0.dmg.sha256 \
  dist/updates/Mackit-1.2.0.tar.bz2 dist/updates/appcast.xml \
  --title "Mackit 1.2.0" --notes-file docs/release-notes/v1.2.0.md
```

仓库仍为私有时，匿名拉取 feed 与资产会 404（GitHub 对私有仓库的资产要求鉴权），这是预期行为；仓库公开后匿名即可下载，更新链路随之生效。`gh-pages` 分支上另存一份累积版 appcast（含全部历史版本条目），供将来若启用 GitHub Pages、想换更短 feed 地址时切换 `MACKIT_UPDATE_FEED_URL` 使用；两条链路产物一致，可随时互切。

几个容易踩的点：

- **构建号必须单调递增**。Sparkle 以 `CFBundleVersion` 判断新旧，`build-app.sh` 默认取 commit 计数（`git rev-list --count HEAD`），每次提交自然变大；CI 里可用 `MACKIT_BUILD_NUMBER` 覆盖。写死同一个值会让更新器永远认为「装的就是最新版」
- **更新包与宿主必须是同一个 Developer ID 身份签名**，Sparkle 的 XPC 服务会校验两端 Team ID 一致。宿主 app 已公证、更新包由应用自己下载落盘（不经浏览器隔离），更新包本身不强制公证
- **归档格式固定 `.tar.bz2`**：Sparkle 运行时只认 zip / tar / tar.gz / tar.bz2 / tar.xz / .aar，没有 `.tar.zst`，格式选错会「下载成功但解包失败」
- **私钥不进仓库**。`MACKIT_ED_KEY_FILE` 指向的文件与登录钥匙串里的私钥等价，泄露即可被推送恶意更新；CI 里放 secret，本机放钥匙串
- 从 DMG 直接运行（未拖进 `/Applications`）时 Sparkle 拒绝更新，这是预期行为
- 开发构建不设 `MACKIT_UPDATE_FEED_URL`，Info.plist 不带 Sparkle 键，更新器不启动，设置页的「更新」段也随之隐藏

本地验证更新链路：起一个本地 HTTP 服务指向更新目录，让旧版本去查它。两种改法任选：

1. 构建旧版时直接把 `MACKIT_UPDATE_FEED_URL` 设成 `http://127.0.0.1:8765/appcast.xml`，`MACKIT_DOWNLOAD_URL_PREFIX` 设成 `http://127.0.0.1:8765/`，appcast 与归档都指向本地；
2. 不改构建，对已安装的旧版写 `defaults write cn.mingcui.mackit SUFeedURL http://127.0.0.1:8765/appcast.xml`——Sparkle 的 user defaults 覆盖优先于 Info.plist，测完 `defaults delete cn.mingcui.mackit SUFeedURL` 即恢复生产地址。

HTTP（非 HTTPS）feed 不会被阻断：Sparkle 此时会强制要求更新带 EdDSA 签名且宿主已签名（两者都满足），归档 enclosure 的 scheme 也允许 http。启动旧版即可看到「发现新版本 → 下载 → 安装并重启」全流程。

设置页「更新」段提供两个开关：自动检查（默认开，每 24 小时一次）与自动下载（找到新版本后后台下载，安装前仍会征求同意）。「立即检查…」在 App 菜单设置项下方。所有更新相关日志走 `os.Logger` 的 `updates` 分类。

## 凭据安全

- `.p8` / `.p12` / `.pem` / `.key` 等私钥材料一律不进仓库，`.gitignore` 已挡住；pre-commit hook（`Scripts/install-git-hooks.sh`）会扫描暂存区兜底拦截
- 公证书是公开信息，可以进仓库存档；与公证书对应的私钥不行
- CI 里凭据放 secret，本机放登录钥匙串（`generate_keys` 可直接存入）
