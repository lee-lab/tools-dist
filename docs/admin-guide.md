# 管理者マニュアル

リリース管理を担当する方向けの手順書です。設計の背景は [development-notes.md](development-notes.md) を参照してください。

---

## 全体の仕組み

```
ツールのリポジトリ (private)          tools-dist (public)
  タグ v1.0.0 を push
        │
        ├─ 配布 zip を作成
        ├─ 暗号化 (.zip.enc) ────────→  Releases  (タグ: <tool>-v1.0.0)
        └─ マニフェストを更新 ────────→  tools/<tool>.json
                                              │
                                    利用者 ← install.ps1
```

- 配布物の実体は **tools-dist の Releases** に置かれます（ツールのリポジトリではありません）
- 「今どのバージョンを配布中か」の唯一の情報源は **`tools/<tool>.json`** です
- GitHub の `/releases/latest` は全ツール横断で最新 1 件を返すため、**使わないでください**

---

## 新しいバージョンをリリースする

1. 変更を `main` にマージする

2. タグを打って push する

   ```shell
   git tag v1.2.0
   git push origin v1.2.0
   ```

3. GitHub Actions の「リリース公開」ワークフローが完走するのを確認する

   ```shell
   gh run watch
   ```

4. 配布中バージョンが更新されたことを確認する

   ```shell
   curl -s https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/valles.json | grep version
   ```

5. 利用者に「更新してください」と伝える（利用者はインストールと同じコマンドを実行するだけです）

> タグ名は `v` + セマンティックバージョン（`v1.2.0`）にしてください。この形式でないとワークフローが停止します。
> 同じタグでやり直す場合、既存の Release は自動的に削除されて作り直されます。

---

## 新しいツールを配布対象に追加する

### ツール側リポジトリの準備

1. リポジトリ直下に次を用意する

   | ファイル | 内容 |
   |---|---|
   | `requirements.txt` | 依存パッケージ。**`git+` 依存は使わないこと**（利用者に Git が必要になる） |
   | 起動スクリプト | 例: `main.py` |
   | `<tool>.ico` | ショートカット用アイコン。PNG は使えない |

2. `.gitattributes` に `export-ignore` を書き、リリース zip から開発用ファイルを除外する

   ```
   test/     export-ignore
   .github/  export-ignore
   ```

3. `valles` の `.github/workflows/release.yml` をコピーし、冒頭の `TOOL_NAME` を変更する

4. シークレットを 2 つ登録する

   ```shell
   gh secret set TOOLS_DIST_TOKEN  --repo lee-lab/<tool>
   gh secret set PAYLOAD_PASSWORD  --repo lee-lab/<tool>
   ```

   - `TOOLS_DIST_TOKEN`: tools-dist に対して `Contents: Read and write` 権限を持つ fine-grained PAT（既存のものを流用可）
   - `PAYLOAD_PASSWORD`: 配布物の暗号化パスワード。一般公開するツールでは登録不要

   > **組織シークレットは使えません。** GitHub Free プランでは、組織シークレットを private リポジトリから参照できないためです。ツールごとに登録してください。

### tools-dist 側の準備

5. `tools/<tool>.json` を作る（`tools/valles.json` をコピーして編集）

   | 項目 | 説明 |
   |---|---|
   | `python` | 必要な Python バージョン。uv が自動で用意する |
   | `entry` | 起動するスクリプト |
   | `icon` | `.ico` のファイル名 |
   | `preserve` | **更新時に引き継ぐファイル・フォルダ**（後述） |
   | `wheels` | PyPI に無く、tools-dist から供給する wheel |
   | `notes` | インストール完了時に表示する補足（**英語で**） |

   `version` と `package` はワークフローが自動で埋めます。初期値は `version: "0.0.0"`、`package.url: ""` のままにしてください。

6. `tools/index.json` に 1 行追加する（`display_name` と `description` は**英語で**）

7. コミットして push する

### `preserve` の決め方（重要）

**更新時、アプリのフォルダはまるごと置き換わります。** `preserve` に書かれたものだけが退避・復元されます。

指定漏れは「更新のたびに利用者の設定が消える」という分かりにくい不具合になります。そのツールが**どこにユーザデータを書くか**を必ず確認してください。

Valles の例:

```json
"preserve": ["settings.json", "contents", "valles/s2m/cache"]
```

設定ファイル、ダウンロードしたモデル、キャッシュなどが対象です。

---

## パスワードを変更する

```shell
gh secret set PAYLOAD_PASSWORD --repo lee-lab/<tool>
```

変更後、**新しいバージョンをリリースするまで反映されません。** 既に公開済みの配布物は古いパスワードのままです。

新しいパスワードは利用者に周知してください。周知前にリリースすると、利用者は更新できなくなります。

---

## 一般公開に切り替える

`PAYLOAD_PASSWORD` シークレットを**削除して、新しいバージョンをリリースするだけ**です。

```shell
gh secret delete PAYLOAD_PASSWORD --repo lee-lab/<tool>
git tag v2.0.0 && git push origin v2.0.0
```

ワークフローは暗号化を行わず、マニフェストから `encrypted` が外れ、インストーラはパスワードを尋ねなくなります。コードの変更は不要です。

---

## 困ったとき

### ワークフローが 403 で失敗する

`TOOLS_DIST_TOKEN` の有効期限切れがほぼ確実です。fine-grained PAT には期限があり、切れると権限設定の誤りと見分けにくいエラーになります。

新しいトークンを作り直して、各ツールのリポジトリに再登録してください。作成時の設定は次のとおりです。

| 項目 | 値 |
|---|---|
| Resource owner | `lee-lab`（自分のアカウントにするとアクセスできません） |
| Repository access | `Only select repositories` → `lee-lab/tools-dist` |
| Permissions | `Contents: Read and write` のみ |

### 利用者から「パスワードが通らない」と言われた

1. `tools/<tool>.json` の `version` と、実際に配布されている Release のタグが一致しているか確認する
2. `PAYLOAD_PASSWORD` を変更した後にリリースしたか確認する（変更前のリリースには古いパスワードが必要）
3. 利用者が最新のパスワードを持っているか確認する

### インストーラを変更した

**必ず Windows 実機でテストを通してください。** 静的な構文チェックでは検出できない不具合が多数あります。

```powershell
powershell -ExecutionPolicy Bypass -File tests\test-install.ps1
powershell -ExecutionPolicy Bypass -File tests\test-install-flow.ps1
```

どちらも何もインストールしないため、安全に実行できます。編集時の注意点は [CLAUDE.md](../CLAUDE.md) にまとめてあります。

### 利用者への案内

インストール手順は次の URL を伝えるだけで完結します。

- 日本語: https://github.com/lee-lab/tools-dist/blob/main/docs/user-guide.ja.md
- English: https://github.com/lee-lab/tools-dist/blob/main/docs/user-guide.en.md

パスワードは URL とは**別の手段で**お伝えください。
