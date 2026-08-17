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
- 「今どのバージョンを配布中か」の唯一の情報源は **`tools/<tool>.json`**（beta）と **`tools/<tool>-alpha.json`**（alpha）です
- GitHub の `/releases/latest` は全ツール横断で最新 1 件を返すため、**使わないでください**

---

## リリースチャネル (alpha / beta)

配布は 2 つのチャネルに分かれています。

| チャネル | 対象 | マニフェスト | 利用者のコマンド |
|---|---|---|---|
| `beta`（既定） | 一般の利用者（Moonshot プロジェクト）。安定して使える版 | `tools/<tool>.json` | 素のワンライナー |
| `alpha` | 研究室の実験協力者。更新頻度が高い | `tools/<tool>-alpha.json` | `$env:LEELAB_CHANNEL = 'alpha'` を付けて実行 |

**beta は新しいビルドではなく、alpha に出ている版の「昇格」です。** Releases に置いた暗号化 zip（タグ `<tool>-v<version>`）は両チャネルで共有し、昇格はマニフェストの内容を写すだけです。ビルドも暗号化もやり直しません。

- 素のワンライナーは今までどおり beta です。チャネルを指定しない利用者に影響はありません
- インストーラは `install.json` にチャネルを記録し、別チャネルを指定して実行されたときは確認を求めます
- `PAYLOAD_PASSWORD` は当面**チャネル共通**です（alpha 専用のパスワードは設けていません）

### beta へ昇格する

1. alpha の版が十分に確かめられたことを確認する

   ```shell
   curl -s https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/valles-alpha.json | grep version
   ```

2. tools-dist の Actions で **「Promote to beta」** を実行する（ツール名と、`v` を付けないバージョンを指定）

   ```shell
   gh workflow run promote-beta.yml --repo lee-lab/tools-dist -f tool=valles -f version=1.2.0
   ```

3. `tools/<tool>.json` が更新されたことを確認し、利用者に「更新してください」と伝える

昇格できるのは**いま alpha に出ている版だけ**です。指定したバージョンが alpha のマニフェストと一致しなければワークフローは止まります（過去の版を選んでの昇格は未対応。必要になったら、そのときにワークフローを拡張してください）。

> **暫定的な不整合（対応中）。** ツール側のリリースワークフロー（MMDAgent-EX の `windows-release.yml`、valles の `release.yml`）は、まだ `tools/<tool>.json` を直接更新します。alpha のマニフェストへ書くよう変更するまでの間、ツールをリリースするとその場で **beta が変わります**。後続の対応で解消する短期的な状態です。

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

### ツールの種別を決める

マニフェストの `kind` で 2 種類を扱えます。**インストーラの共通部分（暗号化・パスワード・SHA-256 照合・ショートカット・アンインストール登録・更新）はどちらも同じ**で、違うのは実行環境の用意の仕方だけです。

| `kind` | 対象 | インストーラの動き | 例 |
|---|---|---|---|
| `python`（既定） | Python で書かれたツール | uv を入れ、専用の仮想環境を作って依存を導入する | Valles |
| `native` | ビルド済みの Windows 実行ファイル | 展開してショートカットを作るだけ。uv も Python も通らない | MMDAgent-EX |

`kind` を省略すると `python` になります（この項目より前に作られたマニフェストのため）。

### ツール側リポジトリの準備

1. リポジトリ直下に次を用意する

   `kind: python` の場合:

   | ファイル | 内容 |
   |---|---|
   | `requirements.txt` | 依存パッケージ。**`git+` 依存は使わないこと**（利用者に Git が必要になる） |
   | 起動スクリプト | 例: `main.py` |
   | `<tool>.ico` | ショートカット用アイコン。PNG は使えない |

   `kind: native` の場合は、ビルド成果物から配布ツリーを組み立てる**パッケージ用スクリプト**を用意します。実行に必要なものが全部入っているかはこちらの責任になります（MMDAgent-EX では `scripts/package_windows_dist.ps1`）。アイコンは実行ファイルに埋め込まれたものが自動で使われるため、`.ico` は不要です。

2. `.gitattributes` に `export-ignore` を書き、リリース zip から開発用ファイルを除外する

   ```
   test/     export-ignore
   .github/  export-ignore
   ```

   `kind: native` では zip を `git archive` で作らないため、この手順は不要です。代わりにパッケージ用スクリプト側で何を入れるかを決めます。

3. `valles` の `.github/workflows/release.yml` をコピーし、冒頭の `TOOL_NAME` を変更する

   `kind: native` では、暗号化より前に**ビルドとパッケージのステップ**が入ります。`lee-lab/MMDAgent-EX` の `.github/workflows/windows-release.yml` が実例です（Windows ランナーでビルドし、そのあとの手順は valles と同じ）。

4. シークレットを 2 つ登録する

   ```shell
   gh secret set TOOLS_DIST_TOKEN  --repo lee-lab/<tool>
   gh secret set PAYLOAD_PASSWORD  --repo lee-lab/<tool>
   ```

   - `TOOLS_DIST_TOKEN`: tools-dist に対して `Contents: Read and write` 権限を持つ fine-grained PAT（既存のものを流用可）
   - `PAYLOAD_PASSWORD`: 配布物の暗号化パスワード。一般公開するツールでは登録不要

   > **組織シークレットは使えません。** GitHub Free プランでは、組織シークレットを private リポジトリから参照できないためです。ツールごとに登録してください。

### tools-dist 側の準備

5. `tools/<tool>.json` を作る（同じ `kind` の既存マニフェストをコピーして編集）

   両方に共通の項目:

   | 項目 | 説明 |
   |---|---|
   | `kind` | `python`（省略時） / `native` |
   | `preserve` | **更新時に引き継ぐファイル・フォルダ**（後述） |
   | `shortcuts` | `desktop` / `start_menu` / `console_variant` の可否 |
   | `notes` | インストール完了時に表示する補足（**英語で**） |

   `kind: python` のみ:

   | 項目 | 説明 |
   |---|---|
   | `python` | 必要な Python バージョン。uv が自動で用意する |
   | `entry` | 起動するスクリプト |
   | `icon` | `.ico` のファイル名 |
   | `wheels` | tools-dist から供給する wheel（PyPI に無いもの／監査済み成果物のミラー） |
   | `requirements_hashed` | ハッシュ検証付きで**先に**入れる requirements ファイルの一覧（任意、後述） |

   `kind: native` のみ:

   | 項目 | 説明 |
   |---|---|
   | `exe` | 配布物の中の実行ファイル名（必須）。**これが zip に無いとインストールは失敗します** |
   | `args` | 実行ファイルに渡す引数（任意） |
   | `icon` | アイコン用ファイル名（任意）。省略すると実行ファイルに埋め込まれたアイコンを使う |

   ショートカットの**作業フォルダは常にアプリのフォルダ**に設定されます。`console_variant` はネイティブでは無視されます（別のコンソール版が無く、中身の無い窓が開くだけになるため）。

   `version` と `package` はワークフローが自動で埋めます。初期値は `version: "0.0.0"`、`package.url: ""` のままにしてください。

   同じ内容で `tools/<tool>-alpha.json` も作ってください（alpha チャネル用）。`tools/index.json` に書くのは beta のパス（`tools/<tool>.json`）だけで、alpha のパスはインストーラがそこから導きます。

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

ユーザデータを**インストール先の外**に書くツールでは、`preserve` は空のままで構いません。MMDAgent-EX がこの例で、コンテンツも設定もデスクトップの `MMDAgent-Contents` フォルダに置かれるため、アプリのフォルダが丸ごと入れ替わっても失われません。「空でよい」ことを確認した根拠は、ツール側のコードで確かめてから決めてください。

### `requirements_hashed`（監査済み依存のハッシュ検証）

依存パッケージの**成果物そのものを監査した**場合、その正確なダイジェストでインストールを縛れます。ツール側にハッシュ付きの requirements ファイルを 1 つ置き、マニフェストから指すだけです。

```json
"requirements_hashed": ["requirements-pywebrtc.txt"],
"requirements": "requirements.txt"
```

インストーラはこのファイルを `--no-deps --require-hashes` で、**本体の `requirements.txt` より先に**入れます。守るべき点が 3 つあります。

1. **ファイルを分ける。** pip も uv もハッシュ検証は「ファイル単位で全部か無しか」です。`requirements.txt` の 1 行だけにハッシュを足すことはできず、他の全パッケージにもハッシュが必要になります（PyOgg のように wheel リンクから入るものは供給できません）。だから別ファイルにします
2. **順序が逆だと検証が消える。** 同じピンは `requirements.txt` にも書いておきます（開発者の素の `pip install -r requirements.txt` を動かすため）。しかし既に入っている要求に対して pip / uv は何も検証しないので、本体を先に流すとハッシュ検証は一度も走りません。インストーラ側でこの順序を固定し、テストで守っています
3. **配布物に必ず同梱する。** マニフェストが指すファイルが zip に無いとインストールは**失敗します**（黙って飛ばすと「検証したつもり」の環境が出来上がるため）。`.gitattributes` の `export-ignore` で除外していないか確認してください

wheel を `wheels` にミラーしてある場合は `--find-links` から供給されるため、上流のパッケージが PyPI から消えてもインストールできます。ミラーの sha256 は PyPI の公表値と同一なので、ハッシュ検証はミラー経由でもそのまま通ります。

> **Valles は次のリリースでこの 2 行が必要です。** `requirements-pywebrtc.txt`（監査済み `pywebrtc-audio`）は valles#67 で追加されましたが、現在配布中の 1.0.0 の zip にはまだ入っていません。**1.0.0 のマニフェストに書くとインストールが失敗します。** #67 以降を含む版をリリースするときに、`tools/valles.json` へ次を追加してください。
>
> ```json
> "requirements_hashed": ["requirements-pywebrtc.txt"],
> "wheels": [
>   "wheels/PyOgg-0.7-py2.py3-none-win_amd64.whl",
>   "wheels/pywebrtc-audio-0.1.0/pywebrtc_audio-0.1.0-cp312-cp312-win_amd64.whl"
> ]
> ```
>
> wheel は `python` に指定した版に合わせます（現在は 3.12 なので cp312）。Python の版を上げるときは wheel の行も合わせて直してください。ミラーには cp310〜cp313 の win_amd64 が揃っています。

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
