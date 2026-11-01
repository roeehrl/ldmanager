<p align="center">
  <img src="docs/assets/icon.png" width="112" alt="LD Manager のアイコン">
</p>

<h1 align="center">LD Manager</h1>

<p align="center">
  <b>Mac で何が動いているかを知り、動かないものを直す。</b><br>
  LaunchAgent と LaunchDaemon のための、無料でオープンソースのネイティブ macOS アプリと CLI です。
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.ja.md">日本語</a></p>

<p align="center">
  <a href="https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT ライセンス" src="https://img.shields.io/badge/licence-MIT-blue"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-0A84FF">
</p>

<p align="center">
  <a href="#what-it-does">できること</a> ·
  <a href="#install">インストール</a> ·
  <a href="#the-ldm-command">CLI</a> ·
  <a href="#why-not-launchcontrol-lingon-or-launchctl">なぜ…ではないのか</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#contributing">コントリビュート</a>
</p>

<p align="center">
  <img src="docs/assets/hero.gif" width="880" alt="LD Manager で失敗したジョブ：インスペクタにはプログラムが見つからないため終了コード 78 で終了したことが表示され、Doctor が修正を提案し、エディタが 1 行だけの差分を示し、ジョブが緑色に変わる様子">
  <br><sub>ジョブが終了コード 78 で失敗し、LD Manager が原因を示し、Doctor が修正を提案し、エディタが差分を表示し、ジョブが動き出します。画像内のデータはすべて架空のものです。</sub>
</p>

> この文書は英語版 README の翻訳です。**[英語版 README](README.md) が正式かつ最新の版**であり、内容に違いがある場合は英語版が優先されます。長いリファレンス的な節は要約のみとし、英語版の該当箇所へのリンクを付けています。

`launchctl` は `Bootstrap failed: 5: Input/output error` と表示するだけで、あとは推測するしかありません。
LD Manager は launchd が持つすべての層――ディスク上の plist、ロードされているかどうか、有効／無効のオーバーライド、ログイン項目のスイッチ、PID、起動回数、直近の終了コード――を読み取り、何が問題でどう直せばよいかをわかりやすい言葉で伝えます。

<a id="what-it-does"></a>

## できること

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.png">
  <img src="docs/assets/hero-light.png" alt="LD Manager のメインウインドウ：launchd のジョブをステータス、スケジュール、実行回数、直近の結果とともに並べた表と、選択したジョブの状態をすべての層について示すインスペクタ">
</picture>

- **すべてのジョブと本当の状態が見えます。** 自分の LaunchAgent、全ユーザーの LaunchAgent、システムの LaunchDaemon、そして Apple 自身のジョブ（読み取り専用）。それぞれについて、すべての層をまとめた 1 つのステータスを表示します：実行中、待機中、失敗、無効、ログイン項目でオフ、未ロード、不正。
- **失敗の原因がわかります。** Doctor は、不正な plist、`Label` の欠落、プログラムが存在しない・実行できない・quarantine 属性が付いている、展開されていない `~`、所有者やアクセス権の誤り、ログフォルダの欠落、再起動ループ、有効なのにロードされていないジョブ、失敗した実行をチェックし、それぞれに修正方法を提案します。
- **スケジュールと終了コードを人間の言葉で読めます。** `StartCalendarInterval {Weekday 1, Hour 9, Minute 30}` は *Mondays at 09:30*（毎週月曜日 09:30）と表示され、次回以降の実行日時も示されます。`78` は *EX_CONFIG: usually a missing or non-executable program*（たいていはプログラムが存在しないか実行できない）、`-15` は *killed by SIGTERM*（SIGTERM で終了された）と表示されます。
- **キーを失わずに編集できます。** わかりやすいフォーム、Keys ビュー、生の XML の 3 つの方法があります。変更はファイル自身のディクショナリに適用されるため、フォームが知らないキーもそのまま残ります。保存のたびに必ず差分を先に表示し、*Recent Changes* から復元できるバックアップを残します。
- **開始、停止、有効化、無効化、ロード、アンロード**――スイッチで、ピン留めしたジョブ用のメニューバー項目で、あるいは `ldm` で。
- **スクリプトから使えます。** `ldm` は同じコアを使った CLI で、`--json` に対応し、`--dry-run` では実行される `launchctl` コマンドをそのまま表示します。終了コードもドキュメント化されています。

<table>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/doctor-dark.png"><img src="docs/assets/doctor-light.png" alt="Doctor：対応が必要なジョブの一覧と、選択したジョブについての各チェック、その根拠、修正ボタン"></picture><br><b>Doctor</b> が失敗を説明し、修正を提案します。</td>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/editor-dark.png"><img src="docs/assets/editor-light.png" alt="エディタ：プログラム、スケジュール、ログファイルを設定するフォームと、下部に変更された 1 つのキーの差分"></picture><br><b>ロスレスな編集</b>：保存する前に差分を確認できます。</td>
  </tr>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/assets/recent-dark.png"><img src="docs/assets/recent-light.png" alt="Recent Changes：plist のバックアップ一覧と Show、Restore ボタン"></picture><br><b>Recent Changes</b>：保存のたびにバックアップが残ります。</td>
    <td width="50%"><img src="docs/assets/cli.png" alt="ターミナルで ldm list、ldm doctor、ldm explain 78 を実行している様子"><br><b><code>ldm</code></b>：同じ Doctor をターミナルで。</td>
  </tr>
</table>

macOS 26 以降が必要です。

<a id="install"></a>

## インストール

**[LD Manager for Mac をダウンロード](https://github.com/roeehrl/ldmanager/releases/latest/download/LD-Manager.dmg)**（macOS 26 以降）。Apple による署名と公証を受けています。ディスクイメージを開き、LD Manager を「アプリケーション」フォルダにドラッグしてください。`ldm` コマンドはアプリに同梱されており、**Settings → Command-line tool** からインストールできます。[`ldm-macos.zip`](https://github.com/roeehrl/ldmanager/releases/latest/download/ldm-macos.zip) を単体でダウンロードすることもできます。各リリースには SHA-256 チェックサムが記載されています。

<a id="from-source"></a>

### ソースからビルドする

Xcode 26 と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）が必要です。

```bash
scripts/build-app.sh
```

これで `build/LD Manager.app` が作られ、`ldm` は `Contents/Helpers` に同梱されます。アプリの **Settings → Command-line tool** で `/usr/local/bin` にリンクできます。

スクリプトは、最初に見つかった *Developer ID Application* または *Apple Development* 証明書で署名します（hardened runtime 付きで、そのまま公証できます）。`SIGN_IDENTITY` が設定されていればそれを使います。`SIGN_IDENTITY=-` ではアドホック署名になり、特権ヘルパー以外はすべて動作します。

リリースを作るには（署名、公証、staple、ディスクイメージ、単体の `ldm`、チェックサムを `build/release` に出力）、App Store Connect API キーの認証情報または notarytool のプロファイルを用意して `scripts/release.sh` を実行します。詳しくはスクリプトの冒頭を参照してください。

CLI だけを単独でビルドすることもできます：

```bash
swift build -c release --product ldm
```

テストは `swift test` で実行します。

<a id="quick-start-with-ldm"></a>

### `ldm` クイックスタート

```bash
ldm list --status problems     # jobs that need attention
ldm doctor report              # why "report" fails, and how to fix it
ldm explain 78                 # what an exit code means
ldm new backup --every 1h -- ~/bin/backup.sh
ldm logs backup -f
```

上から順に、対応が必要なジョブの一覧、`report` が失敗する理由とその直し方、終了コードの意味、1 時間ごとに実行するジョブの作成、そのログの追跡表示です。

<a id="the-ldm-command"></a>

## `ldm` コマンド

```text
ldm list [--status failed|running|disabled|problems] [--scope user|allUsers|system] [--json|--plain]
ldm show <job> [--json] [--background]
ldm doctor [<job>] [--json] [--background]
ldm start|stop|restart|load|unload|enable|disable <job> [--dry-run]
ldm logs <job> [-n 40] [-f]
ldm new <name> (--every 15m | --cron "30 9 * * 1" | --keep-alive | --watch <path>) [--log <file>] -- <program> [args…]
ldm edit <job> [--program <path>] [--every …] [--log <file>] [--dry-run]
ldm remove <job> --confirm <label>
ldm explain <code>
ldm helper
```

ジョブは、完全な label、label の最後の要素、ファイル名、または label のうち一意に決まる任意の部分で指定できます。`--dry-run` は実行する代わりに、実際の `launchctl` コマンドをそのまま表示します。出力先がターミナルでない場合や `NO_COLOR` が設定されている場合は、色を付けません。

`--background` は「ログイン項目と機能拡張」の「アプリのバックグラウンドでのアクティビティ」を読み直します。macOS は毎回パスワードを求めるため、このフラグを付けない場合、`ldm` は前回読み取った結果を使います。

| 終了コード | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 一般的なエラー |
| 2 | 使い方の誤り、または名前が複数のジョブに一致した |
| 3 | 該当するジョブがない |
| 4 | 管理者の認証が必要、またはキャンセルされた |
| 5 | launchd が操作を拒否した |
| 6 | `doctor` が問題を検出した |

<a id="why-not-launchcontrol-lingon-or-launchctl"></a>

## なぜ LaunchControl、Lingon、launchctl ではないのか

- **LaunchControl** は最も充実した launchd ツールで、launchd を日常的に扱うなら価格に見合う価値があります。LD Manager は無料でオープンソース、よりわかりやすい言葉で説明し、JSON 出力に対応したスクリプト可能な CLI を備えています。現時点では、エキスパート向けの機能は LaunchControl のほうが豊富です。
- **Lingon** はジョブの作成を簡単にしてくれますが、ジョブが動いていない理由はあまり示しません。LD Manager はまさにその疑問を中心に作られています。
- **KnockKnock / BlockBlock** はセキュリティの観点から Mac に常駐する項目を表示し、新しい項目が追加されると警告します。ジョブの編集、開始、診断は行いません。併用してください。
- **システム設定 › 一般 › ログイン項目と機能拡張** には、登録済み項目のオン／オフのスイッチしかありません。スケジュール、ログ、終了コードも、編集機能もありません。
- **`launchctl` とテキストエディタ** は、launchd をよく知っていれば十分です。LD Manager はエラーをわかりやすく言い換え、実際のコマンドを表示し（`--dry-run`）、編集のたびにバックアップを残します。
- **`brew services`** が管理するのは Homebrew の formula だけです。

<a id="faq"></a>

## FAQ

**システムのジョブを編集しても安全ですか？**
保存のたびに、まず差分を表示してバックアップを残します。署名済みシステムボリューム上の Apple のジョブは読み取り専用です。システムの LaunchDaemon や `/Library` への変更は、macOS の管理者認証ダイアログ、または一度だけ承認するオプションのヘルパーを通して行われます。

**どこかにデータを送信しますか？**
いいえ。ネットワーク接続は一切行わず、アナリティクスもありません。launchd の状態は `launchctl` で、plist はディスク上のファイルから読み取ります。

**なぜ macOS 26 が必要なのですか？**
最新の SwiftUI と、最近の macOS におけるログイン項目（Background Task Management）の挙動を利用しているためです。古いバージョンへの対応については議論の余地があります――「コントリビュート」を参照してください。

**なぜ Mac App Store で配布しないのですか？**
サンドボックス化されたアプリでは、`launchctl` を操作することも、他のアプリの launchd ジョブを読み取ることもできないからです。

**「LD」は何の略ですか？**
launchd です。

<a id="how-it-works"></a>

## 仕組み（概要）

launchd の状態を取得する公開 API はないため、LD Manager は管理者と同じ方法で読み取ります。domain ごとに `launchctl print` を、オーバーライドには `launchctl print-disabled` を使い、plist ファイルそのものも読みます。パーサーは認識できない行を無視します。「アプリのバックグラウンドでのアクティビティ」（以前の macOS では「バックグラウンドでの実行を許可」）のスイッチは root だけが読める Background Task Management のデータベースにあり、LD Manager は `sfltool dumpbtm` で読み取ります。ヘルパーがなければ求められたときだけ読み取り（毎回管理者認証ダイアログが表示されます）、ヘルパーがあれば何も表示せずに読み取ります。これらのスイッチはプログラムから変更できないため、アプリはシステム設定の「ログイン項目と機能拡張」パネルを開きます。詳しくは英語版の [How it works](README.md#how-it-works) を参照してください。

<a id="the-privileged-helper"></a>

## 特権ヘルパー

システムの LaunchDaemon や `/Library` 内のファイルを変更するには root 権限が必要です。ヘルパーがなければ、そうした操作のたびに macOS の管理者認証ダイアログが表示されます。代わりに LD Manager は小さなヘルパー（アプリに同梱された `SMAppService` デーモン）をインストールでき、**システム設定 › 一般 › ログイン項目と機能拡張 › アプリのバックグラウンドでのアクティビティ** で一度承認するだけで済みます。

- 起動時には何も尋ねません。root 権限が必要な操作を初めて行うとき、LD Manager はヘルパーについて説明し、**Continue**（続ける）、**Use Password Instead**（代わりにパスワードを使う）、**Cancel**（キャンセル）を選べるようにします。パスワードを選ぶとその選択は記憶され、以後はダイアログではなくバナーでお知らせします。
- **Continue** を選ぶと、システム設定が小さなガイドとともに開きます。LD Manager は承認を自動的に検出し、ヘルパーが応答することを確認したうえで、途中だった操作を完了します。
- ヘルパーが受け付けるのは LD Manager と同梱の `ldm` だけで、コード署名（同じチーム、特定のバンドル ID）によって検証します。ヘルパーが行うのは決められた処理だけで、それぞれに検証があります：`system` domain に対する `launchctl`、`/Library/LaunchDaemons` と `/Library/LaunchAgents` への plist の書き込みと削除、それらのアクセス権の修正、ログフォルダの作成、quarantine 属性の削除、ログイン項目の読み取り。
- **Settings › Privileged helper** からいつでも削除できます。`ldm helper` はヘルパーに接続できるかどうかを報告します。ヘルパーはアイドル時に終了し、launchd が現在のアプリから起動し直すため、アップデートは自動的に反映されます（`ldm helper --restart` で強制的に再起動できます）。

変更は `launchctl bootstrap`、`bootout`、`enable`、`disable`、`kickstart`、`kill` を通して行われます。システムの LaunchDaemon への変更と `/Library` への書き込みでは、macOS を通して管理者パスワードを求めます。

<a id="layout"></a>

## ディレクトリ構成（概要）

`Sources/LDCore` がコア（ジョブのモデル、plist の読み取りとロスレスな編集、`launchctl` アダプタ、スケジュール、終了コード、Doctor）、`Sources/ldm` が CLI、`Sources/LDManagerHelper` が root で動く特権ヘルパー、`App/` が SwiftUI アプリ、`Tests/` がユニットテスト、`demo/` がスクリーンショットを作るための架空のデモ環境です。全体の一覧は英語版の [Layout](README.md#layout) を参照してください。

<a id="contributing"></a>

## コントリビュート

issue とプルリクエストを歓迎します。バグ報告には `ldm show <job> --json` の出力を添えていただけると非常に助かります。最初の一歩には、[`good first issue`](https://github.com/roeehrl/ldmanager/labels/good%20first%20issue) や [`help wanted`](https://github.com/roeehrl/ldmanager/labels/help%20wanted) ラベルの付いた issue がおすすめです。60 秒で終わるセットアップは [CONTRIBUTING.md](CONTRIBUTING.md) を、スクリーンショットの元になっている架空のデモ環境は [`demo/`](demo/README.md) を参照してください。これを使えば、変更を試すために自分の launchd ジョブに触れる必要はありません。

<a id="roadmap"></a>

## ロードマップ

- 何かが launchd ジョブを追加・変更したときの通知と、今後の実行予定のタイムライン。
- バックグラウンド項目のエクスプローラー：所有アプリ、Team ID、孤立した項目。
- ショートカットのアクションと、よく使うジョブのテンプレート。

<a id="license"></a>

## ライセンス

MIT です。[LICENSE](LICENSE) を参照してください。LaunchControl、Lingon、KnockKnock、BlockBlock はそれぞれの所有者の製品であり、LD Manager はそれらとも Apple とも提携関係にありません。
