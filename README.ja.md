<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-en-dark.png">
  <img src="docs/banner-en-light.png" width="100%" alt="KIKUmap：Claude と ChatGPT のチャットのためのマインドマップ">
</picture>

<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <b>日本語</b></p>

<p align="center">Mac のメニューバーに置ける、Claude と ChatGPT のチャットのためのマインドマップ。<br>実行中のもの、完了したもの、あなたを待っているものがひと目でわかります。</p>

<p align="center"><a href="https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg"><img src="docs/download-en.svg" height="56" alt="KIKUmap for macOS をダウンロード"></a></p>

<p align="center"><a href="https://www.producthunt.com/products/kikumap?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-kikumap" target="_blank" rel="noopener noreferrer"><img alt="KIKUmap - A mind map for your Claude and ChatGPT chats | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1305867&amp;theme=neutral&amp;t=1793908400163"></a></p>

<p align="center">
  <a href="https://github.com/tang1693/KIKUmap/releases/latest"><img src="https://img.shields.io/github/v/release/tang1693/KIKUmap?include_prereleases&label=version&color=187DFE" alt="最新リリース"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f1e1d?logo=apple&logoColor=white" alt="macOS 13 以降">
  <img src="https://img.shields.io/badge/Swift-no%20dependencies-F05138?logo=swift&logoColor=white" alt="Swift、依存関係なし">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3a78d0" alt="MIT ライセンス"></a>
  <a href="https://github.com/tang1693/KIKUmap/stargazers"><img src="https://img.shields.io/github/stars/tang1693/KIKUmap?style=flat&color=212120" alt="GitHub のスター"></a>
  <a href="https://ko-fi.com/vegligi"><img src="https://img.shields.io/badge/Ko--fi-buy%20me%20a%20coffee-FF5E5B?logo=kofi&logoColor=white" alt="Ko-fi で支援"></a>
</p>

<p align="center">
  <a href="https://tang1693.github.io/KIKUmap/">ウェブサイト</a> ·
  <a href="#features">機能</a> ·
  <a href="#install">インストール</a> ·
  <a href="#privacy">プライバシー</a> ·
  <a href="#faq">よくある質問</a> ·
  <a href="#support">サポート ❤️</a>
</p>

<p align="center"><img src="docs/demo/drag.gif" width="100%" alt="Work トピックをマップ上でドラッグすると、ほかのトピックが左右に分かれて場所を空け、空いた位置に収まる様子"></p>

<p align="center"><a href="https://tang1693.github.io/KIKUmap/#tour"><img src="docs/demo/intro-poster.jpg" width="100%" alt="KIKUmap の紹介動画を見る"></a></p>

## <a id="features"></a>機能

<table>
<tr>
<td width="55%"><img src="docs/demo/menubar.gif" width="100%" alt="メニューバーのアイコン：回転するリングが実行中のチャットを数え、次に赤い未読バッジ、チャットがあなたを待っているときは感嘆符が表示される様子"></td>
<td>

### 1. メニューバーで状態を確認
リングは実行中のチャットの数を示します。赤いバッジは完了して未読のチャットの数で、あなたを待っているチャット（承認や回答が必要なもの、またはエラーで止まったもの）があると **!** が付きます。オプションで、効果音や音声でどのチャットが完了したかを知らせることもできます。

</td>
</tr>
<tr>
<td>

### 2. チャットをマップに
Claude と ChatGPT アプリでピン留めしたチャット、それに Claude Code のセッションが左の列に並びます。それらを自分のトピックへドラッグしてください。各チャットには **Claude** または **GPT** のラベルが付きます。

</td>
<td width="55%"><img src="docs/demo/group.gif" width="100%" alt="3 つのチャットを選択し、まとめて Side projects にドラッグする様子"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/tags.gif" width="100%" alt="In progress タグをクリックすると、そのタグが付いたチャットがハイライトされ、続いてタグをチャットにドラッグする様子"></td>
<td>

### 3. 色、形、タグ
トピックに色と形を設定できます。チャットにタグを付け、タグをクリックするとそのタグが付いたチャットがすべてハイライトされます。タグ欄の上端をドラッグすると高さを変えられ、しまっておくこともできます（⌃⌘G）。ウィンドウが低いまま拡大表示していると、場所ができるまでタグ欄は脇に退きます。ウィンドウを高くするか、⌘- を押してください。

Settings → Colors（設定 → 配色）には、ウィンドウ全体の配色セットが 8 種類あります（Classic、KIKU flower、Bauhaus black、Retro、Deep sea、Neon、Sunset、Candy）。色を 1 つずつ自分で選ぶこともできます。

</td>
</tr>
<tr>
<td>

### 4. キーボード中心
⇥ 子トピック · ⏎ 兄弟トピック · ⌥↑↓ 移動 · ⌘Z 取り消し · ⌘F 検索 · スペースでチャットを開く。

</td>
<td width="55%"><img src="docs/demo/keys.gif" width="100%" alt="Tab で子トピック、Return で兄弟トピックを追加し、Option-上矢印で移動、Command-Z で取り消す様子"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/timeline.gif" width="100%" alt="タイムライン：過去の実行とその時刻、カウントダウン付きのスケジュール済みタスク"></td>
<td>

### 5. タイムライン
各チャットがいつ実行されていたか、そしてこれから予定されているスケジュール済みタスクをカウントダウン付きで表示します。

</td>
</tr>
<tr>
<td>

### 6. 書き出しと読み込み
Claude の各チャットを、要約、プロンプト、会話、アーティファクトのファイルとして書き出します。別の Claude アカウントに読み込むこともできます。

</td>
<td width="55%"><img src="docs/demo/export.gif" width="100%" alt="書き出しウィンドウと、書き出された Markdown ファイルとアーティファクトのフォルダ"></td>
</tr>
<tr>
<td width="55%"><img src="docs/demo/widget.png" width="100%" alt="3 つのサイズの KIKUmap ウィジェット：過去 24 時間の作業時間、使用量、大サイズではさらに最もよく動いたチャットと過去 7 日間"></td>
<td>

### 7. デスクトップウィジェット
過去 24 時間と過去 7 日間の作業時間に加え、Claude と ChatGPT の使用量をプラン名とともに表示します。3 つのサイズがあり、macOS 14 以降が必要です。

</td>
</tr>
<tr>
<td>

### 8. 統計
チャットとセッションごとの時間を 7、14、30、90 日の範囲で表示します。⌘Y。

</td>
<td width="55%"><img src="docs/demo/stats.png" width="100%" alt="統計：7 日間のチャットとセッションごとの時間を示す棒グラフ"></td>
</tr>
</table>

<table>
<tr>
<td width="50%" valign="top"><img src="docs/demo/unread.gif" width="100%" alt="完了したチャットが光る"><br><b>完了したチャット</b>がマップ上で光ります。</td>
<td width="50%" valign="top"><img src="docs/demo/search.gif" width="100%" alt="検索"><br>トピック、チャット、タグを<b>検索</b>。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/today.gif" width="100%" alt="メニューの Today"><br><b>Today</b>（今日）：どのチャットとセッションが、どれだけ動いたか。</td>
<td width="50%" valign="top"><img src="docs/demo/usage.gif" width="100%" alt="メニューの Usage"><br>現在のセッションと今週の<b>使用量</b>。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/pdf.gif" width="100%" alt="マップを PDF に"><br>マップ全体を <b>PDF</b> に。</td>
<td width="50%" valign="top"><img src="docs/demo/backups.gif" width="100%" alt="毎日のバックアップ"><br>マップの<b>毎日のバックアップ</b>。</td>
</tr>
<tr>
<td width="50%" valign="top"><img src="docs/demo/theme.gif" width="100%" alt="ライトまたはダーク"><br><b>ライトまたはダーク。</b></td>
<td width="50%" valign="top"><img src="docs/demo/language.gif" width="100%" alt="英語と中国語"><br><b>English · 中文。</b></td>
</tr>
</table>

**対応アプリ：** Claude デスクトップアプリ · Claude Code（ターミナル、VS Code、Cursor、アプリの Code モード）· ChatGPT デスクトップアプリ · VS Code またはターミナルの Codex。

**ネイティブで軽量：** Swift と AppKit のみ。Electron も Web ビューも、サードパーティのコードも使っていません（線画アイコンは [Lucide](https://lucide.dev)、ISC ライセンス）。

## <a id="install"></a>インストール

1. [Kikumap.dmg をダウンロード](https://github.com/tang1693/KIKUmap/releases/latest/download/Kikumap.dmg)し（macOS 13 以降、Apple シリコンと Intel に対応）、KIKUmap を「アプリケーション」にドラッグします。
2. 初回起動時、macOS はこのアプリを検証できないと表示します（公証を受けていないため）。**完了** をクリックし、**システム設定 → プライバシーとセキュリティ → このまま開く** を選びます。
3. 紹介画面で求められたら **アクセシビリティ** を許可してください。それ以外はすべて任意です。
4. Claude または ChatGPT でチャットをピン留めすると、KIKUmap がそれを追跡します。

<details>
<summary>ソースからビルド</summary>

Xcode Command Line Tools が必要です。

```bash
git clone https://github.com/tang1693/KIKUmap.git
cd KIKUmap
open Install.command
```

`Install.command` は `swiftc` でビルドし、`~/Applications` にインストールして、ローカル証明書で署名します。そのため、再ビルドしても権限はそのまま残ります。`scripts/build-release.sh` はディスクイメージを作成します。
</details>

## <a id="privacy"></a>プライバシー

- すべてのデータは Mac 上の `~/Library/Application Support/ClaudeConsole/` に保存され、外に出ることはありません。
- 必須の権限は 1 つだけです。Claude と ChatGPT のウィンドウにあるチャットの一覧を読み取るための **アクセシビリティ** です。どの権限も、macOS が許可を求める前に用途を説明します。
- ネットワーク通信は行いません。例外は、Anthropic と OpenAI への任意の使用量照会（デフォルトはオフ）だけです。この照会には Claude Code と Codex がすでに Mac に保持しているサインイン情報を読み取って使い、それを保存することはありません。どちらの会社もアプリがこうした照会をしてよいとは表明していないため、将来ブロックされる可能性があります。
- 書き出し（要約付き）と読み込みは、クリップボード経由で貼り付けを行います。KIKUmap が貼り付ける内容には、クリップボード履歴アプリが記録しないよう印が付けられ、ほかのデバイスにも同期されません。各要約は Claude 自身のコピーボタンを経由するため、クリップボード履歴アプリに残る場合があります。各ステップのあとで、クリップボードは元の内容に戻されます。

<details>
<summary>各データソースと権限の用途</summary>

| 表示するもの | 取得元 | 権限 |
|---|---|---|
| Claude のピン留めチャットの実行中・未読 | Claude アプリのサイドバー | アクセシビリティ |
| Claude があなたを待っている状態（承認や回答）と完了した Cowork タスク。Claude のウィンドウを閉じていても取得（任意） | 通知センターにある Claude の通知 | フルディスクアクセス |
| Claude Code のセッション | `~/.claude/settings.json` の Claude Code フック（事前にバックアップ） | 不要 |
| ChatGPT のチャット | ChatGPT アプリが `~/.codex` に置くファイル（読み取り専用） | 不要 |
| ChatGPT の通常のチャット（Codex 以外）の実行中・完了・未読 | ChatGPT ウィンドウのサイドバー（ウィンドウの一部が見えている間） | アクセシビリティ |
| 見ている間に完了したセッションを既読として扱う | そのエディタまたはターミナルのウィンドウタイトル（そのアプリが最前面にある間） | アクセシビリティ |
| デスクトップウィジェット | KIKUmap がウィジェット用に書き出すファイル 1 つ（`widget.json`） | 不要 |
| Claude の使用量とスケジュール済みタスク（任意） | Anthropic の使用量 API（Claude Code のサインインを使用） | キーチェーン |
| ChatGPT の使用量（任意、実験的） | OpenAI の使用量インターフェイス（Codex のサインインを使用） | 不要 |

ChatGPT：Codex のチャットが最もよくサポートされています（アプリのファイルから読み取るため、ウィンドウを閉じていても正確です）。通常のチャットのサポートは限定的で、ChatGPT のウィンドウから、その一部が見えている間だけ読み取ります。

表示されないもの：ピン留めしていないチャット、およびほかのコンピュータ、サーバ、クラウドで実行されているもの。
</details>

<details>
<summary>すべてのキーボードショートカット</summary>

| | |
|---|---|
| ⇥ / ⌥⇥ | 新しい子トピック / 新しい親トピック |
| ⏎ / ⌥⏎ / ⇧⏎ | 下に兄弟トピック / 上に兄弟トピック / 新しいメイントピック |
| ⌘⏎、ダブルクリック | 名前を変更 |
| ⌫ / ⌥⌫ | 削除（ピン留めしたチャットは左の列に残ります）/ トピックだけを削除し、中の項目は残す（複数選択時も同様） |
| ⌥. | 折りたたむ / 展開する |
| ↑ ↓ ← → | その方向にある最も近い項目を選択 |
| ⌥↑ ⌥↓ / ⌥← ⌥→ | 上下に移動 / 階層を移動 |
| ⌘↓、スペースを軽く押す | チャットをそのアプリで開く |
| ⌘↑ | 含まれているトピックへ上がる |
| 何もない場所でドラッグ、⇧/⌘-クリック | 複数選択 |
| スペースを押したまま、2 本指でスワイプ | マップ内を移動 |
| ⌃⌘S / ⌃⌘G / ⌃⌘T | 左の列 / タグ / タイムライン |
| 左の列で ↑ ↓ | 上または下の行を選択（マップでもそのチャットが選択されます） |
| 左の列で ⏎、スペース | チャットをそのアプリで開く |
| ⌘Y | 統計 |
| ⌘R | 更新 |
| ⌘Z / ⇧⌘Z | 取り消し / やり直し |
| ⌘F | 検索 |
| ⌘E / ⇧⌘E | マップを PDF に / チャットを書き出す |
| ⇧⌘U | 未読 / 既読にする |
| ⌘+ / ⌘- / ピンチ / ⌘0 | 拡大 / 縮小 / ズーム / ウィンドウに合わせる |
| ⌃⌥C（変更可能。ただし KIKUmap 自身の ⌃⌘S / ⌃⌘G / ⌃⌘T / ⌥⌘H には設定できません） | どこからでもマップを表示 / 非表示 |
</details>

## <a id="faq"></a>よくある質問

<details>
<summary><b>Anthropic や OpenAI が作ったものですか？</b></summary>

いいえ。KIKUmap は独立したオープンソースプロジェクトです。Claude アプリには公開 API がないため、KIKUmap はアクセシビリティ経由でウィンドウを読み取っています。Claude や ChatGPT のアップデートによって、KIKUmap が対応するまで一部の機能が動かなくなることがあります。
</details>

<details>
<summary><b>なぜ「このまま開く」が必要なのですか？</b></summary>

公証には有料の Apple Developer アカウントが必要ですが、KIKUmap は無料です。ソースからビルドすることもできます。純粋な Swift で、依存関係はありません。
</details>

<details>
<summary><b>Claude のウィンドウを閉じるとどうなりますか？</b></summary>

⌘W はウィンドウを隠すだけです。KIKUmap は Claude のチャットをウィンドウから読み取るため、ウィンドウが現在のデスクトップに戻るまでチャットを確認できません。その間、実行中だったチャットは「running?」（実行中？）と表示されます。ウィンドウが戻ったときに完了していたチャットは「done after 14:00」（14:00 以降に完了。最後に実行中と確認した時刻）と表示されます。いつ完了したかはわからないためです。Claude Code と Codex のチャットには影響しません。ChatGPT の通常のチャットも同じように、ウィンドウの一部が見えている間に ChatGPT のウィンドウから読み取ります。
</details>

<details>
<summary><b>セッションが完了したときに見ていたのに、なぜ未読のままなのですか？</b></summary>

KIKUmap が完了したセッションを自動で既読にするのは、最前面のウィンドウがそのセッションのものとしか考えられない場合だけです。Claude Code なら、VS Code または Cursor でそのフォルダを開いているウィンドウか、タイトルにそのフォルダと `claude` の両方が表示されているターミナルウィンドウ。Codex なら、VS Code でそのフォルダを開いているウィンドウです。ほかのウィンドウやタブにも表示されている可能性がある場合（同じフォルダやその上位フォルダを開いている別のエディタウィンドウがあるなど）は、未読のままになります。ターミナルで動いている Codex のセッションも未読のままです（KIKUmap にはどのターミナルで動いているかがわからないため）。既読にするには、KIKUmap から開くか、選択して ⇧⌘U を押してください。
</details>

<details>
<summary><b>何かが表示されない</b></summary>

- 上部バーの **▸ To-do**（やること）に、足りないものがそれぞれのボタンとともに一覧表示されます。
- Claude のチャット：チャットをピン留めし、Claude のサイドバーを開いたまま Chat を表示し、Pinned を展開しておいてください。
- Claude Code：Settings → Access → Claude Code → **Connect**（設定 → アクセス → Claude Code → 接続）を選び、新しいセッションを開始します。
- ウィジェット：macOS 14 以降で、KIKUmap を「アプリケーション」に入れておく必要があります。デスクトップを右クリック → **ウィジェットを編集**。
- それでも解決しない場合：Settings → Access → **Diagnostic report**（設定 → アクセス → 診断レポート。チャットのタイトルやメッセージは含まれません）を作成し、[issue を作成](https://github.com/tang1693/KIKUmap/issues)してください。
</details>

<details>
<summary><b>名前の由来は？</b></summary>

*Kiku*（菊）は日本語の「菊」です。メニューバーにある小さな花のことです。
</details>

## 貢献

issue やプルリクエストを歓迎します。特に、Claude や ChatGPT のアップデートで何かが動かなくなったときはぜひお願いします。[コントリビューションガイド](.github/CONTRIBUTING.md)と[行動規範](.github/CODE_OF_CONDUCT.md)をご覧ください。セキュリティの問題は[セキュリティポリシー](.github/SECURITY.md)に従って報告してください。

## <a id="support"></a>サポート

KIKUmap は無料です。役に立ったら、コーヒーを 1 杯おごっていただけると開発の励みになります ❤️

<p><a href="https://ko-fi.com/vegligi"><img src="docs/kofi-en.svg" height="64" alt="Ko-fi でコーヒーをおごる"></a></p>

## ライセンス

[MIT](LICENSE)。Claude は Anthropic の、ChatGPT は OpenAI の商標です。本プロジェクトは独立したもので、いずれの企業からも承認を受けていません。
