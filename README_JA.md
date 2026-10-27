<div align="center">

<img src="Sources/Mackit/Resources/sparkle-blue.png" width="120" alt="Mackit アイコン">

# Mackit

**macOS開発者向けキャッシュクリーナー** — ツールチェーンが残す再生可能なキャッシュをすべてスキャンし、明確なリスクラベルを付けて項目を1つずつ選び、ディスク領域を取り戻します。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1f88d8?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/license-MIT-3da639?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/virskor/mackit?style=flat-square)](https://github.com/virskor/mackit/releases)
[![Downloads](https://img.shields.io/github/downloads/virskor/mackit/total?style=flat-square)](https://github.com/virskor/mackit/releases)

[日本語](README_JA.md) · [English](README.md) · [简体中文](README_ZH.md) · [繁體中文](README_ZH_HANT.md) · [한국어](README_KO.md)

🌐 [公式ウェブサイト](https://www.mingcui.cn)

</div>

---

## Mackitが必要な理由

Go、Node、Yarn、pnpm、Dart、Flutter、Rust、Python、CocoaPods、Gradle、Xcode、Android Studio…… これらのツールはどれも、あなたのマシンに**再生可能なキャッシュ**を残します。パッケージのダウンロード、ビルドの中間生成物、モジュールキャッシュ、シミュレータのデータ、ツールのインデックスです。1つだけでは大きく見えませんが、まとまると数十GBになります。そしてFinderでは、十数個のドットディレクトリに散らばっているため、サイズもわからず、安全に削除することもできません。

Mackitが行うこと:

1. **スキャン** — 60以上の規則を並行して列挙し、キャッシュ、ビルド成果物、残りファイルがどこにあっても見つけ出します。結果はストリーミングされるので、スキャンの実行中にサイズが表示されます；
2. **ラベル付け** — すべての項目にリスクレベル（安全 / 要確認 / 注意）と完全なパスが付くので、削除する前に何が起こるかがわかります；
3. **選択** — デフォルトでは何もチェックされていません。項目を1つずつ選ぶか、「安全」な項目を一括で全選択できます；
4. **削除** — ゴミ箱に移動（元に戻せます）または完全に削除。コマンドラインの項目はツール独自のクリーンアップコマンドを呼び出します。

## 機能

- **ワンタップでスキャン**: 77個のパス規則 + 13個のコマンドラインクリーンアップ規則。スキャンの実行中にリストへストリーミング表示されます
- **3段階のリスクレベル**: `安全`（純粋なキャッシュ、ツールが再作成します） / `要確認`（再ダウンロードまたは再ビルドが必要） / `注意`（ゴミ箱、iOSバックアップなど。追加の確認が必要）
- **Appのアンインストール**: サイドバーの「ツール」セクションにあるツールページ。`/Applications` と `~/Applications` にインストールされたAppと、`~/Library` 内の残りファイル（Application Support、キャッシュ、コンテナ、環境設定、ログイン項目……）を一緒に表示します。残りファイルとともにAppをアンインストールしたり、残りファイルだけをクリーンアップしたりできます。実行中のAppは拒否されます
- **Appジャンクのクリーンアップ**: クリーンアップスキャンは、Appの残りファイルのうち再生可能な部分（キャッシュ、HTTPストレージ、WebKitデータ、ログ、クラッシュレポート）を、ジャンククリーンアップモジュールの「Appのジャンク」行でカバーします — Appごとなので、1つのAppのキャッシュを残しながら他をクリーンアップできます
- **ビルド成果物スキャン**: ディレクトリ（例: `~/Projects`）を指定すると、`node_modules`、`build`、`Pods`、`.dart_tool`、`DerivedData`、`target`、`.venv` など、再構築可能なフォルダを見つけます
- **コマンドラインクリーンアップ**: `go clean -cache`、`npm cache clean`、`brew cleanup`、`dart pub cache clean` など
- **メニューバーパネル**: 常駐するメニューバーアイコンからパネルを開くと、確保可能な容量、CPU / メモリ / 温度、Appごとのメモリ使用量ランキング（ワンタップで「メモリを解放」）、空きディスク容量、CPUグラフが表示されます
- **デスクトップの統計フローティングバー**: オプションの常駐最前面バー。CPU / メモリ / 温度をコンパクトに表示し、どんな壁紙でも読みやすく、ドラッグでき位置を記憶します。トレイプロセス内にのみ存在します
- **ディスク領域分析**: サイドバーの「ツール」セクション（クリーンアップ項目の下）にあるツールページ。「容量はどこへ行った？」に答えます — 起動ディスクからパンくずでドリルダウンし、各フォルダの再帰的なサイズ、選択したフォルダの内訳を示すtreemapを表示します
- **ハードウェア情報**: モデル、ディスク、バッテリーなどの静的情報
- **ネイティブUI**: SwiftUIのサイドバー + テーブル + ツールバー。ネイティブのコンテキストメニュー、キーボードショートカット、検索、クリックで並べ替えられる列ヘッダを備えます
- **ローカライズ**: 简体中文 / English / 繁體中文 / 한국어 / 日本語、デフォルトではシステム言語に従う
- **安全機構**: 保護されたパスのリストを内蔵。システムディレクトリとキーチェーンは常に拒否されます

## スクリーンショット

![Mackit メインウィンドウ](docs/images/main-window-en.png)

> メニューバーパネル、デスクトップのフローティングバー、ハードウェアページのスクリーンショットは追って追加予定です。

## インストール

### 事前構築済みバイナリをダウンロード（推奨）

[Releases](https://github.com/virskor/mackit/releases) から最新のDMGを取得し、開いてMackitを「アプリケーション」にドラッグします。

- ユニバーサルバイナリ（arm64 + x86_64）で、AppleシリコンとIntel Macの両方に対応
- macOS 14以降が必要です（IntelマシンはmacOS 14を実行できる必要があります）
- 初回インストールはDMG経由。それ以降のアップデートはApp内のSparkle自動アップデート経由

### ソースからビルド

macOS 14+ と Xcode 16+（Swift 6）が必要です:

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

# 方法1: 一括でビルドして起動（debug、反復が最速）
./run.sh

# 方法2: release版のMackit.appをビルドしてから起動
Scripts/build-app.sh release
open Mackit.app
```

Xcodeで `Package.swift` を開いて `Mackit` schemeを実行することもできます。開発ビルドは現在のネイティブアーキテクチャのみをコンパイルします。配布可能なユニバーサルバイナリ（arm64 + x86_64）は[リリースノート](docs/RELEASE.md)を参照してください。

テストを実行:

```bash
swift test
```

## 使い方

1. 初回起動時に自動的にスキャンされます。**デフォルトでは何もチェックされません** — 削除するものはあなたが決めます
2. サイドバーでカテゴリ別に閲覧するか、ツールバーから項目 / パスを検索します
3. 「環境設定 › プロジェクトのビルド成果物」の下にコードのルートディレクトリを追加すると、`node_modules` などのビルド成果物をスキャンできます
4. Appをアンインストールするには: サイドバーの「ツール」セクションの「Appのアンインストール」を開き、Appにチェックを入れて（または行を展開して個々の残りファイルにチェックを入れて）、確認します
5. 項目にチェックを入れたら、ツールバーの「X GBクリーンアップ」をクリックします。確認シートに詳細とリスクの注意事項が表示されます
6. 「ゴミ箱に移動」を有効に保ち、確信が持ててからゴミ箱を空にします

キーボードショートカット:

| ショートカット | 操作 |
| --- | --- |
| `⌘R` | 再スキャン |
| `⌘⌫` | 選択した項目をクリーンアップ |
| `⌘⌥S` | 安全な項目をすべて選択 |
| `⌘,` | 環境設定 |

## カバー範囲

| カテゴリ | 内容 |
| --- | --- |
| ビルド成果物 | node_modules、build、Pods、.gradle、.dart_tool、DerivedData、dist、target、.venv、__pycache__ など |
| Xcode | DerivedData、Archives、iOS/watchOS DeviceSupport、DocumentationCache、モジュールキャッシュ |
| シミュレータ | dyldキャッシュ、デバイス内のAppキャッシュ、デバイスのテンポラリディレクトリ、シミュレータのログ |
| Android / Gradle | Gradleキャッシュ、wrapperのディストリビューション、デーモンのログ、Android Studioキャッシュ、Kotlin/Native、Mavenリポジトリ |
| Node / フロントエンド | npm `_cacache`、Yarn、pnpm store、Bun、node-gyp、TypeScript、ESLint、Deno |
| Flutter / Dart | pub-cache（hosted / git / temp）、Dart Analysis Server |
| Go | go-buildキャッシュ、モジュールのダウンロードキャッシュ |
| Rust | cargo registryキャッシュ/src、git依存関係 |
| Python | pip、uv、Poetry、pre-commitキャッシュ |
| Ruby | RubyGemsのスペックキャッシュ、ユーザーインストールされたgem、Bundlerキャッシュ |
| PHP | Composerキャッシュ |
| .NET | NuGetグローバルパッケージ、HTTPキャッシュ |
| Scala / JVM | Coursierキャッシュ、sbtブート、Ivyキャッシュ |
| Haskell | Cabalパッケージキャッシュとビルドストア、Stackツールチェーンとスナップショット |
| Clojure | tools.depsのgitライブラリ、Leiningenのインストール |
| Elixir / Erlang | Hexレジストリキャッシュ、Mixアーカイブ、rebar3キャッシュ |
| Lua | LuaRocksツリー |
| Julia | プリコンパイルキャッシュ、レジストリ、インストール済みパッケージ |
| OCaml | opamダウンロードキャッシュ、パッケージインデックス |
| Zig | コンパイラのグローバルキャッシュ |
| Nim | コンパイラキャッシュ、Nimbleパッケージ |
| Crystal | コンパイラキャッシュ |
| Perl | CPANのソース、ビルドの残りファイル |
| CocoaPods | CocoaPodsキャッシュ、Carthageキャッシュ、specリポジトリ |
| IDE | JetBrains、VS Code / Cursorのキャッシュとログ |
| Homebrew | ダウンロードキャッシュ |
| システムとApp | `~/Library/Caches`、サンドボックス化されたAppのキャッシュ、ログ、クラッシュレポート、iOSバックアップ |
| ゴミ箱 | `~/.Trash` 内のファイル |

コマンドラインのクリーンアップ項目は、対応するツールのカテゴリにグループ化され、該当するパス規則と並べて表示されます。

### Appのアンインストール

Appのアンインストールは、サイドバーの「ツール」セクションにある独立したツールページであり、クリーンアップスキャンの一部ではありません。ページにはインストール済みのAppがすべて表示され、実際のアイコン、バージョン、サイズ、残りファイルの数が示されます。Appごとに1行、三状態のチェックボックス付きで — チェックするとAppバンドルとそのすべての残りファイルが一度に選択され、行を展開すると個々の残りファイルがそれぞれのチェックボックスとともに表示されるので、1つのキャッシュや環境設定ファイルだけを個別に残したり削除したりできます。Appの行を右クリックすると、2つのショートカットが表示されます:

- **残りファイルとともにアンインストール…**: App本体とそのすべての残りファイルにチェックを入れ、確認を開きます
- **残りファイルのみクリーンアップ…**: 残りファイルだけをクリーンアップし、Appは残します

アンインストールは統一されたクリーンアップフローを再利用します。Appと残りファイルの両方が「環境設定 › クリーンアップ方法」の設定に従います — ゴミ箱に移動（元に戻せます）または完全に削除。実行中のAppは拒否され、まず終了するよう求める結果ノートが表示されます。確認シートにはそれらの名前が事前に表示されます。残りファイルは場所によってラベル付けされます — キャッシュとログは「安全」。Application Support、環境設定、コンテナなど、ユーザーデータが保存されている可能性のある場所は「要確認」。

App本体だけにチェックを入れた場合、確認シートは関連ファイルがまだいくつ未選択かを（Appごとの数とサイズで）指摘し、「すべて選択」のショートカットを提供します。これにより、空のディレクトリだけが残り、キャッシュがディスク上に残ったままになる事態を避けられます。

クリーンアップスキャンがAppの世界から扱うのは、再生可能な半分だけです。ジャンククリーンアップモジュールの「Appのジャンク」行は、Appごとにキャッシュ、HTTPストレージ、WebKitデータ、ログ、クラッシュレポートをクリーンアップします — Appが必要に応じて再作成するジャンクです — つまり何もアンインストールせずにこの容量を解放でき、クリーンアップスキャンからAppのデータに到達することは決してありません。

既知の制限事項: Group Containers（Appごとのentitlementの読み取りが必要）、Appにバンドルされたアンインストーラ、システムレベルのLaunchAgents/Daemons（管理者権限が必要）はカバーされていません。完全なSpotlightスキャンで発見されるカスタム領域にインストールされたAppも範囲外です。

## アクセス権

Mackitは `~/Library`、`~/.pub-cache`、`~/.gradle`、`/Applications` などの場所を読み取る必要があるため、**App Sandboxは有効になっていません**。`~/Library` 配下の一部のパスにはフルディスクアクセスが必要で、ユーザーは「システム設定 › プライバシーとセキュリティ › フルディスクアクセス」で手動で許可できます。ターミナルでパスを開くと、ターミナルを操作するためのApple Events許可が要求されます（`NSAppleEventsUsageDescription`）。メニューバーパネルの「メモリを解放」は管理者の認証を要求して `purge` を実行します（ファイルキャッシュを破棄します。App自身が保持するメモリには影響しません）。ディスク領域分析ツールは、スキャン中は意図的に `~/Documents`、`~/Desktop`、`~/Downloads` に入りません — これらを列挙するとシステムのアクセスダイアログが表示されるためです — そのためこれらのフォルダは「未スキャン」と表示され、必要に応じてスキャンできます（1クリック、または完全なスキャンにはフルディスクアクセスを許可）。CPU、メモリ、Appごとのメモリは公開システムインターフェース（`host_statistics64`、`proc_pid_rusage`）から取得されます。macOSに公開された温度APIはないため、表示される温度はシステムのサーマル状態です。「環境設定 › 一般」の「アクセス権の管理」セクションは、これらの項目をそれぞれリアルタイムで報告します — 許可されているかどうか、何が解除されるか、そして該当する設定行を正確に開くボタン（または、Appがまだ要求したことのない自動操作の許可については、システムに要求します — macOSはAppが要求した後にのみ自動操作のリストにAppを表示します）— これにより、壊れているように見える機能も、1クリックでその背後にあるアクセス権までたどることができます。

## 開発

### アーキテクチャ: メインApp + メニューバーエージェント

Mackitは1つのバイナリからの2つのプロセスであり、bundle IDによって役割を切り替える2つのbundleとして出荷されます:

| | Mackit.app (`cn.mingcui.mackit`) | MackitAgent.app (`cn.mingcui.mackit.agent`) |
| --- | --- | --- |
| 形態 | 通常のApp、Dockアイコンあり | LSUIElement、メニューバーのみ |
| 役割 | メインウィンドウ、スキャン、クリーンアップ、設定、Sparkleアップデート | メニューバーアイコンとパネル、デスクトップの統計フローティングバー、システム監視 |
| ライフサイクル | ウィンドウを閉じると終了 | 常駐。ログイン項目がログイン時に起動 |

**メインウィンドウを閉じる = メインプロセスの終了 = Dockアイコンの消失。一方、メニューバー監視は毎分動き続けます** — これが「ウィンドウは閉じたがトレイは生きている」の実装方法です。実行時のactivation policyの切り替えは一切行いません（実行時にregularとaccessoryを切り替えると、macOSがメニューバーを再構築し、毎回Dockタイルを追加・削除することになります。これこそがメニューバーがちらつき、Dock行がずれる原因です）。

2つのプロセスがどのように連携するか（`Sources/Mackit/IPC/`）:

- **コマンド**: エージェントは分散通知を送ります（ウィンドウを開く / 設定 / ハードウェア / クリーンアップ / 終了 / トースト）。メインAppが実行中でない場合、コマンドはまずディスクに永続化され、起動後に再生されます（コールドスタート補償）
- **状態**: メインAppはスキャン / クリーンアップの状態をエージェントにブロードキャストするので、パネルのヘッダに「確保可能なサイズ」と選択済みの数を表示できます。監視データは逆にエージェントだけがポーリングします — メインAppが終了した後も動き続ける必要があるためです
- **設定**: 共有ファイル `~/Library/Application Support/Mackit/shared-settings.plist`。メインAppが書き込み、エージェントが読み取り、変更時にはブロードキャストで更新されます。App Groupsは使いません。ad-hoc署名ではGroup Containerを解決できず（cfpregsは `Container: (null)` を報告し、ソース全体がdetachされます）、有料のDeveloper ID署名でのみ回復します — 開発の反復が証明書に依存してはいけません
- **ログイン項目**: エージェント（`SMAppService.loginItem`）を登録するので、ログイン時に表示されるのはメニューバーアイコンだけです。エージェントが見つからない場合、メインAppが再起動し、実行中は30秒ごとに見守ります（エージェントがクラッシュするとトレイは自己修復します）
- **単一インスタンス**: bundle IDごとにエージェントは1つだけが許可されます — ログイン項目を登録すると、launchdが同じ瞬間にエージェントを1つ起動するので、メインAppがすでに起動していればトレイアイコンが2つ表示されることになります。後のインスタンスは前任者を見つけると譲ります
- **常駐**: エージェントのInfo.plistは `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination` を無効にし、起動時に `disableAutomaticTermation` を呼びます

### macOS 14互換性

下限はコンパイルターゲットのmacOS 14です。どのソースも14.0より上のAPIを使っていません（14.0ターゲットに対する `swift build` は可用性の警告をゼロと報告します）。macOS 15.0+のランタイムを必要とする唯一のシンボル `withTaskGroup(of:returning:isolation:body:)` は、弱リンクと実行時のバージョンチェックとともにコンパイルされ、14.xではローカル実装にフォールバックするので、欠落シンボルの解決に失敗することはありません。ハードウェアページとメニューバー監視は、AppleシリコンとIntelで同じ公開インターフェースを使います（Intelにperf levelがない場合、「HardwareSampler」はグレースフルにダウングレードします）。

### ローカライズ

ユーザー向けの文字列はすべて `Sources/Mackit/Resources/Localizable.xcstrings`（String Catalog）にあり、简体中文をソース言語とし、English、繁體中文、한국어、日本語の翻訳が含まれます。コードにユーザー向けのリテラルは現れません。すべて `Utilities/L10n.swift` を経由します:

```swift
Text(verbatim: L10n.tr("toolbar.rescan"))                 // 静的文字列
Text(verbatim: L10n.fmt("toast.trashed", item.title))     // プレースホルダ付き: %@ / %lld
Text(verbatim: L10n.items(count))                         // "N項目"、複数形は処理済み
```

言語を追加するには: まずcatalogで翻訳し（Xcodeで開き、左下の `+` をクリック）、次に登録します — `Utilities/AppLanguage.swift` に、その言語自身の表記とシステム設定とのマッチングを持つ `AppLanguage` ケースを追加し、`Scripts/build-app.sh` の両方の `CFBundleLocalizations` 配列にその言語を追加し、UIに同梱されたら `LanguageFileScanner.isWhitelisted` にそのプライマリサブタグを追加して、言語パックのクリーンアップ規則がそれを残すようにします。新しい文字列はcatalogにキーとして追加します。テストスイートの `LocalizationTests` は、呼び出し側と照合してキーの完全性とプレースホルダの一貫性をチェックします。

インターフェイス言語の選択は `Utilities/AppLanguage.swift` にあります。「システム設定に従う」と5つの言語で、UserDefaultsの `appLanguage` に保存され、Appドメインの `AppleLanguages` にミラーリングされます — CFBundleの文字列参照はこのキーを読むので、再起動後に有効になります（SparkleのアップデートUIとシステムのファイルパネルも追随します）。プロセス内の切り替えではなく再起動にする理由: スキャン結果のタイトルと説明は作成時に現在の言語で確定するため、プロセス内で更新しても言語が混在したリストができるだけです（詳細はソースのコメントを参照）。

2つの複数形キー（`.one` / `.other`）は同じプレースホルダのレイアウトを保つ必要があります — `.one` にも `%lld` が必要で、名詞を単数形にするだけです。そうしないと `%@` が整数を受け取り、UIが最初のレンダリングでクラッシュします。

### ログ

ライフサイクルイベント（スキャン / クリーンアップの開始、完了、キャンセル、失敗）とウィンドウ形態の変化は、すべて統一された `os.Logger`（subsystem = bundle ID）を通ります。releaseビルドでも記録されます。各プロセスは自分のsubsystemで記録します。メインAppは `cn.mingcui.mackit`、メニューバーエージェントは `cn.mingcui.mackit.agent`。リアルタイムで見る:

```bash
log stream --predicate 'subsystem == "cn.mingcui.mackit"' --level info
# メニューバーエージェントのログ（起動、再起動、見守り）
log stream --predicate 'subsystem == "cn.mingcui.mackit.agent"' --level info
# ディレクトリごとの列挙の詳細（どの読み取れないディレクトリがスキップされたか）: --level debug を追加
```

コンソールAppでsubsystemによりフィルタできます。記録されるのは数、サイズ、所要時間、規則idだけです — ファイルの内容は決して記録されません。

### プロジェクト構成

```
Sources/Mackit/
├── MackitApp.swift               # エントリのディスパッチ（@main が bundle ID で役割を切り替え）+ メインウィンドウ/メニュー + 共有 AppDelegate
├── AgentApp.swift                # メニューバーエージェントのエントリ（MenuBarExtra + ラベル）
├── Models/                       # データモデル: 項目、カテゴリ、リスクレベル、スキャン規則、コンパレータ
├── Engine/
│   ├── RulesCatalog.swift        # 77個のスキャン規則と13個のCLIクリーンアップコマンド
│   ├── AppScanner.swift          # インストール済みAppの発見と残りファイルの検出（アンインストールツールとAppジャンク行に供給）
│   ├── FileSystem.swift          # サイズ計算、グロブ、ツールの検索、ボリューム容量
│   ├── Scanner.swift             # 並行スキャン + プロジェクトディレクトリの走査
│   ├── DiskAnalyzer.swift        # ディスク領域分析: ディレクトリごとの一覧 + 再帰的な計測
│   ├── TreemapLayout.swift       # squarified treemap レイアウト（純関数）
│   └── Cleaner.swift             # 削除 / ゴミ箱 / コマンド実行
├── Monitor/                      # CPU / メモリ / 温度のサンプリング、ハードウェア情報、メモリ解放
├── IPC/                          # プロセス間のコマンド / 状態 / 設定チャネル（分散通知 + 共有 plist）
├── Updater/
│   └── UpdateController.swift    # Sparkle自動アップデート
├── ViewModels/
│   ├── AppViewModel.swift        # ステートマシン: スキャン、選択、クリーンアップ、設定（プロセスごとに1つ）
│   ├── DiskAnalysisModel.swift   # ディスク分析ページ: ナビゲーション、ストリーミング計測、キャッシュ
│   ├── HomebrewModel.swift       # Homebrewマネージャページ: スナップショット、セクション、アクション、検索
│   └── AppUninstallModel.swift   # Appアンインストールページ: Appリスト、選択、アンインストールフロー
├── Views/                        # SwiftUI: メインウィンドウ、トレイパネル、フローティングバー、設定、ハードウェア、ディスク分析
│   └── Components/               #   再利用可能なコンポーネント（バッジ、プログレスリング、通知行、フローレイアウト……）
└── Utilities/
    ├── AppLanguage.swift         # インターフェイス言語の選択（システム + 5言語、AppleLanguages に書き込み）
    ├── MackitLog.swift           # 統一された os.Logger ラッパー
    ├── Formatters.swift          # バイトと時間のフォーマット
    ├── LaunchAtLogin.swift       # ログイン項目の登録（埋め込みの MackitAgent.app を指す）
    └── L10n.swift                # ローカライズの参照（String Catalog）
    Resources/
    ├── Localizable.xcstrings     # 5言語（zh-Hans / en / zh-Hant / ko / ja）
    └── sparkle-blue.png          # ブランドアイコン（App内表示とAppアイコンで共有）
Scripts/                          # ビルド / パッケージング / アイコン生成スクリプト
Tests/MackitTests/                # 52個のテストファイル
```

### テスト

`swift test`。52個のテストファイルが、スキャンエンジン、クリーンアップエンジン、規則カタログ、Appのアンインストール、Appジャンクのスキャン、共有ストレージ、並べ替えコンパレータ、ローカライズキーの完全性、アップデートコントローラなどをカバーします。

### リリース

署名、公証、DMGパッケージング、Sparkleアップデートパイプラインはメンテナ向けです。[docs/RELEASE.md](docs/RELEASE.md) を参照してください。

## 貢献

IssueとPRを歓迎します。ビルド、テスト、コードの規約: [CONTRIBUTING.md](CONTRIBUTING.md)。参加することで、[行動規範](CODE_OF_CONDUCT.md) を遵守することに同意したものとみなされます。

## セキュリティ

秘密鍵、証明書、資格情報は**決してリポジトリに入りません**。`secrets/` とすべての `*.p8` / `*.pem` / `*.key` ファイルは `.gitignore` によってブロックされ、pre-commitフック（`Scripts/install-git-hooks.sh` でインストール）がステージング領域をスキャンして秘密鍵を阻止します。セキュリティ上の問題で公開Issueを開かないでください — GitHub Security Advisory で非公開に報告してください。

## ライセンス

[MIT](LICENSE) © 2026 virskor

## 謝辞

- [Sparkle 2](https://sparkle-project.org/) — App内自動アップデート
