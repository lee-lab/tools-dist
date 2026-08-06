# tools-dist プロジェクト固有の指示

## プロジェクト概要

研究室ツールの Windows 向け公開配布リポジトリ。利用者が PowerShell の 1 行コマンドでインストールできるようにするための、共通インストーラとツールごとのマニフェストを置く。

- 利用者は開発経験の無い Windows ユーザを想定している
- ツール本体の zip はこのリポジトリの Releases に置く（タグは `<tool>-v<version>`）
- **このリポジトリは公開**。ツール本体のソースも zip 経由で公開されることを前提にすること

## install.ps1 を編集するときの必須事項

- **UTF-8 BOM 付きで保存すること。** Windows PowerShell 5.1 は BOM 無し UTF-8 を cp932 として読むため、BOM が無いと日本語が壊れて構文エラーになる
- **Windows PowerShell 5.1 の構文だけを使うこと。** 三項演算子、`??`、`Join-Path` の 3 引数以上、`ConvertFrom-Json -AsHashtable` は使えない
- `Set-StrictMode -Version Latest` を有効にしているため、マニフェストの任意項目は必ず `Get-Prop` 経由で読むこと（存在しないプロパティへの直接アクセスは例外になる）
- 管理者権限を要求しないこと。インストール先は `%LOCALAPPDATA%\LeeLab\` 配下に限る
- 利用者に表示するメッセージは日本語で、専門用語を避けること。エラー時は「開発者に連絡してください」まで案内すること

### 実機で踏んだ罠（デグレさせないこと）

いずれも Windows 実機でしか再現せず、静的な構文チェックでは検出できなかったもの。

- **外部コマンドの標準エラー出力。** `$ErrorActionPreference = 'Stop'` のまま `& cmd 2>&1` を書くと、進捗表示を標準エラーに出すだけのコマンド（uv など）で `NativeCommandError` が発生し、正常動作中にスクリプトが止まる。外部コマンドは必ず `Invoke-Native` 経由で呼び、成否は `$LASTEXITCODE` で判断すること
- **`Invoke-WebRequest` の戻り値の型。** 配信側が Content-Type をテキストとして宣言しない場合、`.Content` は文字列ではなく `Byte[]` になる。astral.sh の uv インストーラがこれに該当した。文字列として扱う前に型を確認すること
- **JSON の文字コード。** Content-Type に charset が無いと `Invoke-WebRequest` は既定の文字コードで復号し、マニフェスト中の日本語が化ける。`Get-RemoteJson` は `WebClient` に UTF-8 を明示して読んでいる。ここを `Invoke-WebRequest` に戻さないこと
- **`uv venv` は既存の環境を上書きしない。** `--clear` が無いと**更新時にだけ**失敗する。初回インストールしか試していないと見逃す
- **外部スクリプトを `Invoke-Expression` で取り込まない。** こちらの StrictMode / ErrorActionPreference の影響を受けて誤動作する。一時ファイルに書き出して別プロセスで実行すること

新規インストールだけでなく、**必ず更新パスも検証すること**。実運用では更新の方が回数が多い。

## マニフェスト (`tools/*.json`)

- `preserve` の指定漏れは、更新のたびに利用者の設定が消える不具合になる。新しいツールを追加するときは、そのツールがどこにユーザデータを書くか必ず確認すること
- バージョンの唯一の情報源は `tools/<tool>.json`。GitHub の `/releases/latest` は全ツール横断で最新の 1 件を返すため使わないこと
- `tools/index.json` への追加を忘れるとインストーラのメニューに出ない

## wheels/

- PyPI に無いパッケージのビルド済み wheel を置く場所
- 追加・更新するときは、再現できるビルドスクリプトを `scripts/` に必ず添えること
- 現在: `PyOgg 0.7`（PyPI 版 0.6.14a1 には `OpusEncoder` / `OpusDecoder` が無いため）

## 検証

Windows 実機が無い環境でも、構文チェックは WSL から Windows PowerShell を呼んで行える。

```shell
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '...'
```

インストーラのロジックを変更したときは、最低限どちらも確認すること。

1. ファイルとしての構文解析（`Parser::ParseFile`）
2. `irm | iex` 相当の文字列としての構文解析（`Parser::ParseInput`）
