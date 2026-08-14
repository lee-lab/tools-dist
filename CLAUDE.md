# tools-dist プロジェクト固有の指示

## プロジェクト概要

研究室ツールの Windows 向け公開配布リポジトリ。利用者が PowerShell の 1 行コマンドでインストールできるようにするための、共通インストーラとツールごとのマニフェストを置く。

- 利用者は開発経験の無い Windows ユーザを想定している
- ツール本体の zip はこのリポジトリの Releases に置く（タグは `<tool>-v<version>`）
- **このリポジトリは公開**。ツール本体のソースも zip 経由で公開されることを前提にすること

## install.ps1 を編集するときの必須事項

- **`install.ps1` は BOM 無し・純 ASCII で保存すること。コメントも英語で書くこと。**
  - `irm <url> | iex` で実行されるが、**`Invoke-RestMethod` は先頭の BOM を文字列に残す。** BOM があると `<#` がブロックコメント開始として認識されず、コメント本文がすべてコードとして解釈されてスクリプト全体が壊れる
  - BOM を外せるのは非 ASCII バイトが 1 つも無い場合に限る。BOM が無いと PowerShell 5.1 はシステムのコードページ（日本語環境では cp932）で読むため、非 ASCII の文字が壊れる
  - `tests/test-install.ps1` がこれを強制している（BOM の有無・純 ASCII・irm 経路での解析）
  - **`System.Net.WebClient.DownloadString` は BOM を除去してしまうため、検証に使わないこと。** これで確認して問題を見逃した実績がある
- 一方、**テストスクリプトと生成する `uninstall.ps1` は BOM 付き UTF-8 のまま**でよい。これらは `-File` でしか実行されず `iex` を通らないため、BOM があっても壊れない。むしろ非 ASCII を含む可能性があるため BOM が必要
- **Windows PowerShell 5.1 の構文だけを使うこと。** 三項演算子、`??`、`Join-Path` の 3 引数以上、`ConvertFrom-Json -AsHashtable` は使えない
- `Set-StrictMode -Version Latest` を有効にしているため、マニフェストの任意項目は必ず `Get-Prop` 経由で読むこと（存在しないプロパティへの直接アクセスは例外になる）
- 管理者権限を要求しないこと。インストール先は `%LOCALAPPDATA%\LeeLab\` 配下に限る
- **利用者に表示するメッセージはすべて英語で書くこと。** 利用者に英語母語話者が含まれるため。日本人利用者も英語は読めるので、英語に統一する
  - 対象: `Write-Host` / `Read-Host` / `Fail` などの出力、生成する `uninstall.ps1` の内容、ショートカット名、マニフェストの `display_name` / `description` / `notes`、リリースノート
  - 対象外: コード内コメント、ファイル冒頭の説明ブロック、本ファイルや README の開発者向け記述（これらは日本語でよい）
  - 専門用語を避け、平易な英語で書くこと。エラー時は「開発者に連絡してください」に相当する案内まで含めること
- `install.ps1` はコメントも含めて英語・純 ASCII とする（上記の文字コードの制約による）

### 実機で踏んだ罠（デグレさせないこと）

いずれも Windows 実機でしか再現せず、静的な構文チェックでは検出できなかったもの。

- **外部コマンドの標準エラー出力。** `$ErrorActionPreference = 'Stop'` のまま `& cmd 2>&1` を書くと、進捗表示を標準エラーに出すだけのコマンド（uv など）で `NativeCommandError` が発生し、正常動作中にスクリプトが止まる。外部コマンドは必ず `Invoke-Native` 経由で呼び、成否は `$LASTEXITCODE` で判断すること
- **`Invoke-WebRequest` の戻り値の型。** 配信側が Content-Type をテキストとして宣言しない場合、`.Content` は文字列ではなく `Byte[]` になる。astral.sh の uv インストーラがこれに該当した。文字列として扱う前に型を確認すること
- **JSON の文字コード。** Content-Type に charset が無いと `Invoke-WebRequest` は既定の文字コードで復号し、マニフェスト中の日本語が化ける。`Get-RemoteJson` は `WebClient` に UTF-8 を明示して読んでいる。ここを `Invoke-WebRequest` に戻さないこと
- **`uv venv` は既存の環境を上書きしない。** `--clear` が無いと**更新時にだけ**失敗する。初回インストールしか試していないと見逃す
- **外部スクリプトを `Invoke-Expression` で取り込まない。** こちらの StrictMode / ErrorActionPreference の影響を受けて誤動作する。一時ファイルに書き出して別プロセスで実行すること

- **`Expand-Archive` に戻さないこと。** 展開は `[System.IO.Compression.ZipFile]::ExtractToDirectory` を使っている。`Expand-Archive` は PowerShell 側でエントリを 1 件ずつ処理するため、ネイティブツールの配布物（数百 MB・数千ファイル）では実用にならない。.NET 側は相対パスをプロセスのカレントディレクトリ基準で解決するので、**渡す前に必ず絶対パスにすること**

- **`Where-Object` の結果に直接 `.Count` を使わない。** 結果が 1 件だけのとき、`PSCustomObject` では PSObject のプロパティ探索が優先され `.Count` が取れず `$null` になる。必ず `@(...)` で包んでから数えること（テストで実際に踏んだ）

新規インストールだけでなく、**必ず更新パスも検証すること**。実運用では更新の方が回数が多い。

## 配布物の暗号化

- 一般公開前のツールは、配布物を暗号化して Releases に置く。このリポジトリは公開のため、暗号化しないと誰でも取得できてしまう
- 形式は OpenSSL の `enc -aes-256-cbc -pbkdf2 -md sha256 -salt` と互換。**CI 側 (openssl) とインストーラ側 (.NET) で実装が別れているため、片方だけ変更すると誰も開けない配布物ができる**
- この互換性は `tests/fixtures/sample.enc` を使った回帰テストで守っている。暗号処理を触ったら必ず `tests/test-install.ps1` を通すこと
- マニフェストの `sha256` は**復号後**の zip のもの。この照合がパスワード誤りの最終的な検出手段になっている
- 一般公開に切り替えるときは、ツール側の `PAYLOAD_PASSWORD` シークレットを削除して再リリースするだけでよい

## テスト

| ファイル | 内容 |
|---|---|
| `tests/test-install.ps1` | 個々の関数の単体テスト。副作用なし |
| `tests/test-install-flow.ps1` | `Install-Tool` 全体の配線検証。uv・ショートカット・レジストリを差し替え、配布物は `file://` で取得するため、実際には何もインストールされない |

どちらも Windows 上で実行する。インストーラを変更したら両方を通すこと。

## マニフェスト (`tools/*.json`)

- **`kind` は `python`（省略時） と `native` の 2 種類。** `native` はビルド済みの Windows 実行ファイルを配る種別で、uv / Python / venv / wheels / requirements を一切通らない。共通部分（暗号化・パスワード・SHA-256 照合・展開・ショートカット・アンインストール登録・更新）は同じ経路を使うこと。**`kind` を増やすときは、既定が `python` である前提を壊さないこと**（この項目より前に作られたマニフェストには `kind` が無い）
- `preserve` の指定漏れは、更新のたびに利用者の設定が消える不具合になる。新しいツールを追加するときは、そのツールがどこにユーザデータを書くか必ず確認すること。インストール先の外にしか書かないツール（MMDAgent-EX）では空でよいが、それはコードで確認してから決めること
- バージョンの唯一の情報源は `tools/<tool>.json`。GitHub の `/releases/latest` は全ツール横断で最新の 1 件を返すため使わないこと
- `tools/index.json` への追加を忘れるとインストーラのメニューに出ない

## リリース公開の権限

- クロスリポジトリ公開に使う `TOOLS_DIST_TOKEN` は、**ツールごとにリポジトリシークレットとして登録すること**
- lee-lab は GitHub Free プランのため、**組織シークレットは公開リポジトリからしか参照できない**。ツール側のリポジトリは通常プライベートなので組織シークレットでは動かない
- トークンに必要な権限は `lee-lab/tools-dist` に対する `Contents: Read and write` の 1 つだけ。`Workflows` 権限は付けないこと

## wheels/

- PyPI に無いパッケージの wheel と、監査済み成果物のミラーを置く場所
- 追加・更新するときは、**再現できるスクリプトを `scripts/` に必ず添えること**。自前ビルドならビルドスクリプト、ミラーなら再取得・照合スクリプト（ミラーで置き換えてはいけない: 成果物そのものを置くことに意味がある）
- 現在:
  - `PyOgg 0.7`（PyPI 版 0.6.14a1 には `OpusEncoder` / `OpusDecoder` が無いため）→ `scripts/build-pyogg-wheel.sh`
  - `pywebrtc-audio 0.1.0` 全成果物（valles#67 の音声処理コアの依存退避、上流は新興プロジェクト）→ `scripts/mirror-pywebrtc-audio.sh`

## requirements_hashed（マニフェストの任意項目）

監査済み依存をダイジェストで縛るための仕組み。`--no-deps --require-hashes` で、**本体の `requirements.txt` より先に**インストールする。

- **順序を入れ替えてはいけない。** 同じピンは `requirements.txt` にも書かれており（開発者の素の install を動かすため）、既に入っている要求に pip / uv は何も検証しない。本体を先に流すと検証が一度も走らない
- 指定ファイルが配布物に無ければ**失敗させる**（黙って飛ばすと「検証したつもり」の環境ができる）
- どちらも `tests/test-install-flow.ps1` が守っている。この 2 つの assertion を消さないこと

## 検証

Windows 実機が無い環境でも、構文チェックは WSL から Windows PowerShell を呼んで行える。

```shell
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '...'
```

インストーラのロジックを変更したときは、最低限どちらも確認すること。

1. ファイルとしての構文解析（`Parser::ParseFile`）
2. `irm | iex` 相当の文字列としての構文解析（`Parser::ParseInput`）
