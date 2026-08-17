# 管理者マニュアル

リリース管理を担当する方向けの手順書です。tools-dist で配布している全ツール
（現在は `mmdagent-ex` と `valles`）に共通の、**リリースの最初から最後までの通し手順**を
扱います。設計の背景は [development-notes.md](development-notes.md) を参照してください。

シークレットやパスワードの**値**は、本書にも他のドキュメントにも書きません（名前だけを扱います）。

---

## 全体の仕組み

```
ツールのリポジトリ (private)          tools-dist (public)
  タグ v1.0.0 を push
        │
        ├─ 配布 zip を作成
        ├─ 暗号化 (.zip.enc) ────────→  Releases  (タグ: <tool>-v1.0.0)
        └─ マニフェストを更新 ────────→  tools/<tool>-alpha.json          ← alpha
                                          tools/archive/<tool>-v1.0.0.json
                                              │
                                              │  Promote to beta（tools-dist の Actions）
                                              ▼
                                          tools/<tool>.json                ← beta（既定）
                                              │
                                    利用者 ← install.ps1
```

- 配布物の実体は **tools-dist の Releases** に置かれます（ツールのリポジトリではありません）
- 「今どのバージョンを配布中か」の唯一の情報源は **`tools/<tool>.json`**（beta）と **`tools/<tool>-alpha.json`**（alpha）です
- GitHub の `/releases/latest` は全ツール横断で最新 1 件を返すため、**使わないでください**
- タグ push で更新されるのは **alpha のマニフェストだけ**です。beta は昇格でしか変わりません

### 誰に何を届けるか

受け取り手は 3 層あり、それぞれ届け方が違います。

| 利用者層 | 受け取り方 | Windows | Quest 3（MMDAgent-EX のみ） |
|---|---|---|---|
| **開発者** | ソースからビルド | 各ツールのリポジトリを clone してビルド | 同左（Android ビルド + ADB） |
| **研究室の共同研究者・実験協力者** | **alpha** チャネル | tools-dist の alpha マニフェスト（ワンライナーに `LEELAB_CHANNEL=alpha`） | Meta Horizon の **ALPHA** リリースチャネル |
| **一般の利用者（Moonshot プロジェクト）** | **beta** チャネル | tools-dist の beta マニフェスト（素のワンライナー） | Meta Horizon の **BETA** リリースチャネル |

ツールごとの対応プラットフォームは次のとおりです。

| ツール | Windows | Quest 3 | macOS |
|---|---|---|---|
| `valles` | ✅（タグ `v*`） | — | — |
| `mmdagent-ex` | ✅（タグ `v*`） | ✅（**同じ** `v*` タグから出荷、Meta Horizon） | 開発協力者向けのオンデマンド配布（後述） |

MMDAgent-EX は 1 本の `vX.Y.Z` タグで Windows と Quest 3 の両方を出荷します。プラットフォームごとに別のタグを打つ必要はありません（旧 `android-v*` タグ運用は廃止しました。過去のタグはアーカイブとして残ります）。

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

### 原則: beta へ新規ビルドが直接入る経路は無い

beta に出る版は必ず alpha を通った版で、「alpha で問題が出なかった版を選んで写す」以外の入り方がありません。

- Windows: 昇格は `tools/<tool>-alpha.json` を `tools/<tool>.json` へコピーするだけ。再ビルドも再暗号化も再アップロードも起きません
- Quest 3: 昇格は Meta のダッシュボードで既存の Alpha ビルドに BETA チャネルを追加割り当てするだけ。APK も versionCode も変わりません

その帰結として、**昇格できるのは「いま alpha に出ている版」だけ**です。過去の版を選んで beta に出す運用は用意していません（古い内容を出したい場合は、それを改めて alpha リリースしてから昇格してください）。

### archive マニフェスト

リリースのたびに、alpha と同じ内容のスナップショットを `tools/archive/<tool>-v<version>.json` にも書き出します。alpha は次の版で上書きされるため、これが無いと過去の版を指すマニフェストが失われます（Release の資産自体は残ります）。1 リリースにつき数百バイトの JSON が 1 個増えるだけです。

---

## 前提（初回のみ）

一度整えれば以後は不要です。担当者が代わったときの確認用に列挙します。

### ツール側リポジトリのシークレット

各ツールのリポジトリの **Settings → Secrets and variables → Actions** に登録します。値は本書には書きません。

| 用途 | シークレット名 |
|---|---|
| Windows 配布（全ツール共通） | `TOOLS_DIST_TOKEN`, `PAYLOAD_PASSWORD` |
| Quest 配布（MMDAgent-EX のみ） | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `META_APP_ID`, `META_APP_SECRET` |

> **組織シークレットは使えません。** GitHub Free プランでは、組織シークレットを private リポジトリから参照できないためです。ツールごとに登録してください。

登録方法と `TOOLS_DIST_TOKEN` の作成条件は「[新しいツールを配布対象に追加する](#新しいツールを配布対象に追加する)」と「[困ったとき](#困ったとき)」にあります。

### Meta Horizon のチャネルとメンバー（MMDAgent-EX のみ）

Meta Horizon Developer Dashboard に **ALPHA** と **BETA** の 2 チャネルがあり、それぞれ独立したメンバーリストを持ちます。

- ALPHA: 共同研究者の Meta アカウントを登録します
- BETA: 利用者を**メールアドレスで招待**するか、後述の**参加用リンク**で参加してもらいます。既定の上限は **200 人**、申請すれば **2500 人**まで引き上げられます
- 同じアカウントを両方に入れることもできます。未登録のアカウントには配信されません

初期設定の詳細は MMDAgent-EX リポジトリの `dev/android-cicd.md` を参照してください。

### Quest チャネルの参加用リンク（MMDAgent-EX のみ）

メールアドレスを 1 件ずつ登録する代わりに、**リンクを開いてもらうだけで参加できる URL** を発行できます。Developer Dashboard のチャネル設定にある **「Grant access to users by URL」** を有効にすると、そのチャネル専用の `https://www.meta.com/s/...` が得られます。利用者はリンクを開き、ヘッドセットにサインインしているのと同じ Meta アカウントでサインインするだけです。

| チャネル | 参加の扱い | 管理者の作業 |
|---|---|---|
| ALPHA（実験協力者） | クリックした時点で参加完了 | なし（自動承認） |
| BETA（一般の利用者） | クリックは**参加リクエスト** | Dashboard で 1 件ずつ承認します |

BETA を手動承認にしているのは、一般公開前の配布物が意図しない相手に届かないようにするためです。**承認待ちのリクエストは Dashboard を見に行かないと分かりません。** 利用者に案内したあとは、しばらく Dashboard を確認してください。

- **リンクは発行から 90 日で失効します。** そのチャネルに新しいビルドを上げると期限が延びるため、リリース頻度の高い ALPHA は実質失効しません。**BETA は昇格が続かないと失効します**。失効したら Dashboard で再発行してください
- **現行の URL の唯一の情報源は site-doc のインストールページ**（`content.ja/getting-started/install.md` と `content.en/getting-started/install.md` の Meta Quest 3 節）です。URL がローテートしたら **site-doc だけを直してください**
- マニフェストの `notes` には URL 自体を書かず、**インストールページを指す 1 行だけ**を置いています。beta 昇格でマニフェストは alpha から丸ごと写されるため `notes` はチャネル中立でなければならず、また URL が変わるたびにマニフェストを触りたくないためです

### 配布パスワードの周知

配布物は `PAYLOAD_PASSWORD` で暗号化されており、インストール時に利用者がパスワードを入力します。**このパスワードは公開ドキュメント・リポジトリ・インストール案内の URL には一切書かず、口頭や別の手段で個別に伝えてください。** 公開リポジトリに置いた配布物が「知っている人だけ」の配布として成立するのは、この一点によります。

---

## 新しいバージョンをリリースする（alpha）

タグを push すると alpha チャネルが更新されます。**この操作で beta は変わりません。**

### 通常: `/release-alpha` スキル

各ツールのリポジトリで Claude Code の `/release-alpha` を実行すると、次を一気通貫で行います。

1. 前提チェック（ブランチ・未コミット変更・`gh` 認証・`origin/main` との同期）
2. 現状の把握（リポジトリ最新タグ / alpha マニフェストのバージョン / 差分コミット）
3. 次バージョンの決定（コミット要約を見せて対話選択。alpha は既定でパッチ版）
4. annotated タグの作成と push（push 直前に必ず停止して確認）
5. CI の監視（失敗時はログ抜粋を出してそこで停止。**タグは勝手に消しません**）
6. 公開結果の検証（alpha マニフェストと archive スナップショット、およびツール側リポジトリの Release `vX.Y.Z` のアセット）
7. リリースノートの清書（ツール側リポジトリに Release がある場合のみ。詳細は次段落）
8. MMDAgent-EX では、同じタグから出た Quest 版の結果（Meta Horizon ALPHA へのアップロードと APK のアーカイブ）を確認
9. 完了報告（プラットフォームごとの結果を並べ、beta はまだ変わっていないことを明示）

### 同等の手動手順（Windows）

1. 変更を `main` にマージする

2. タグを打って push する

   ```shell
   git tag -a v1.2.0 -m "<Tool> v1.2.0"
   git push origin v1.2.0
   ```

3. GitHub Actions の「リリース公開」ワークフローが完走するのを確認する

   ```shell
   gh run watch
   ```

   ワークフローは、配布 zip の作成 → sha256 照合 → openssl で暗号化（復号の往復検証つき）→ tools-dist に Release `<tool>-v<version>` を作成 → `tools/<tool>-alpha.json` と `tools/archive/<tool>-v<version>.json` を更新して commit、の順に進みます。`kind: native`（MMDAgent-EX）では、暗号化の前に Windows ランナーでのビルドとパッケージが入ります。

   あわせて、各ツールのリポジトリ側にも開発者向けの記録として Release `v<version>` が自動作成されます（MMDAgent-EX は平文 zip と Quest APK と自動生成ノート、valles はノートのみ）。自動生成ノートには前タグ以降のマージ済み PR が並ぶため、バージョン間の差分の記録になります。リリースノートは `/release-alpha` スキルが所定の書式（日本語→英語、カテゴリ別サマリー、`#XX` 参照、制作者名なし）に清書します。

4. **alpha の**配布中バージョンが更新されたことを確認する

   ```shell
   curl -s https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/valles-alpha.json | grep version

   # archive スナップショットが作られているか（200 なら OK）
   curl -s -o /dev/null -w '%{http_code}\n' \
       https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/archive/valles-v1.2.0.json
   ```

5. alpha の利用者に「更新してください」と伝える（利用者はインストールと同じコマンドを実行するだけです）

> タグ名は `v` + セマンティックバージョン（`v1.2.0`）にしてください。この形式でないとワークフローが起動しません（`V1.2.0` や `1.2.0` は不一致です）。
> 同じタグでやり直す場合、tools-dist 側の既存 Release は自動的に削除されて作り直されます。

### Quest 3 も同じタグから出ます（MMDAgent-EX のみ）

**Quest 用に別のタグを打つ必要はありません。** 上の `v1.2.0` の push で起動する `release.yml` が、Windows の配布 zip と並行して署名済み APK をビルドし、Meta Horizon の **ALPHA** チャネルへアップロードします。

- MMDAgent-EX リポジトリの GitHub Release `vX.Y.Z` には、Windows の平文 zip と Quest APK（`MMDAgent-EX-Quest-<version>-versionCode<N>.apk`）が並びます。この `versionCode` が後の BETA 昇格でビルドを識別する鍵になります
- `versionCode` は単調増加する番号です。値そのものに意味はなく、Meta が同一 versionCode の再アップロードを拒否するための識別子として使います
- Quest 版のバージョン番号は Windows と常に同一です
- 確認は Meta Horizon Developer Dashboard のビルド一覧で、その versionCode の ALPHA ビルドが現れていることを見ます

#### アドホックな Quest テストビルド

正式なリリースを伴わずに Quest の実機確認をしたいときは、MMDAgent-EX の Actions から `android-release.yml` を **workflow_dispatch** で手動起動します。Meta Horizon の ALPHA チャネルへ APK を上げるだけで、タグも GitHub Release も作らず、tools-dist のマニフェストにも一切触れません。

> 旧 `android-v*` タグによる Quest リリースは**廃止しました**。過去のタグと Release はアーカイブとしてそのまま残しますが、新しく打たないでください。

---

## beta へ昇格する

alpha で十分に動作確認できた版を、一般の利用者に出す操作です。

### 通常: `/release-beta` スキル

Claude Code で `/release-beta` を実行すると、alpha / beta 両マニフェストの現状を並べて見せ、昇格対象（＝現在の alpha）を確認したうえで tools-dist の昇格ワークフローを実行・監視・検証し、続けて Quest の手動昇格チェックリストを案内します。

### 同等の手動手順（Windows）

1. alpha の版が十分に確かめられたことを確認する

   ```shell
   curl -s https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/valles-alpha.json | grep version
   ```

2. tools-dist の Actions で **「Promote to beta」** を実行する（ツール名と、`v` を付けないバージョンを指定）

   ```shell
   gh workflow run promote-beta.yml --repo lee-lab/tools-dist -f tool=valles -f version=1.2.0
   ```

   ワークフローは配布物の URL が取得できることを確認してから、`tools/<tool>-alpha.json` を `tools/<tool>.json` へコピーして commit します。

3. `tools/<tool>.json` が更新されたことを確認し、利用者に「更新してください」と伝える

   ```shell
   curl -s https://raw.githubusercontent.com/lee-lab/tools-dist/main/tools/valles.json | grep version
   ```

昇格できるのは**いま alpha に出ている版だけ**です。指定したバージョンが alpha のマニフェストと一致しなければワークフローは止まります（過去の版を選んでの昇格は未対応。必要になったら、そのときにワークフローを拡張してください）。

### Quest 3 の昇格（MMDAgent-EX のみ・手動）

**CI では行えません。** Meta Horizon Developer Dashboard での手動操作になります。

1. 昇格対象の versionCode を特定する（MMDAgent-EX リポジトリの Release `vX.Y.Z` のアセット名に含まれます。Windows zip と同じ Release に APK が同居しています）

   ```shell
   gh release view v3.13.0 --repo lee-lab/MMDAgent-EX --json assets --jq '.assets[].name'
   ```

   APK が見当たらない場合、その版は Windows のみが出荷されています。Quest 側は前のビルドが ALPHA / BETA に残ったままなので、Quest も新しくしたい場合は Quest ビルドを含む版を改めて alpha リリースしてください。

2. Dashboard のビルド一覧からその versionCode の ALPHA ビルドを選ぶ
3. リリースチャネルに **BETA** を追加で割り当てる（ALPHA からの移動ではなく追加。再アップロードは不要で APK も versionCode も変わりません）
4. BETA チャネルのメンバーに対象の利用者が招待済みかを確認する
5. Dashboard 上で当該ビルドに BETA チャネルが割り当たっていることを確認する

手順の詳細と、CI で自動化しない理由は MMDAgent-EX リポジトリの `dev/android-cicd.md` にあります。

---

## 利用者への案内

### Windows

インストールも更新も**同じ 1 行**です。Windows PowerShell に貼って Enter し、メニューからツールを選び、配布パスワードを入力してもらいます。

```powershell
# beta（既定）
irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex

# alpha（実験協力者）
$env:LEELAB_CHANNEL = "alpha"; irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

- インストール先は `%LOCALAPPDATA%\LeeLab\<tool>\app`。管理者権限も UAC も不要です
- **更新は同じコマンドの再実行**です。別チャネルを指定して実行すると、インストーラがチャネル切り替えの確認を求めます
- アンインストールは Windows の「設定 > アプリ」から行います
- 更新でアプリのフォルダは丸ごと入れ替わります。引き継がれるのはマニフェストの `preserve` に書かれたものだけです（後述）

手順ページは次の URL を伝えるだけで完結します。パスワードは URL とは**別の手段で**お伝えください。

- 日本語: https://github.com/lee-lab/tools-dist/blob/main/docs/user-guide.ja.md
- English: https://github.com/lee-lab/tools-dist/blob/main/docs/user-guide.en.md

### Quest 3（MMDAgent-EX のみ）

該当チャネル（ALPHA / BETA）にメンバー登録された Meta アカウントで Quest にサインインしていれば、**Meta Horizon ストア経由で自動更新**されます。管理者から伝えることは「更新が出た」ことだけで、利用者側の特別な操作は要りません。

まだチャネルに入っていない利用者には、[参加用リンク](#quest-チャネルの参加用リンクmmdagent-ex-のみ)を案内します。リンクそのものは伝えず、**手順ページの URL だけ**を伝えれば足ります（対象別の参加用リンクがページ内にあります）。

- 日本語: https://mmdagent-ex-doc.netlify.app/ja/getting-started/install/
- English: https://mmdagent-ex-doc.netlify.app/getting-started/install/

### macOS（MMDAgent-EX のみの例外運用）

macOS は開発協力者向けの**オンデマンド配布**で、チャネル体制の外にあります。エンドユーザ配布は行いません。

- `/release-upload-mac` スキルで、既存の `vX.Y.Z` タグの GitHub Release に `MMDAgent-EX-vX.Y.Z-macos-arm64.zip` を添付します
- Windows のリリースは GitHub Release を作らないため、対象タグに Release が無いのが普通です。その場合は**先に Release を作ってから**アセットを上げます
- Apple Silicon (arm64) のみ、ad-hoc 署名のみ（初回起動は右クリック → 開く）

規定は MMDAgent-EX リポジトリの `CLAUDE.md`（`## Release Packaging`）にあります。

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

   `kind: native` では、暗号化より前に**ビルドとパッケージのステップ**が入ります。`lee-lab/MMDAgent-EX` の `.github/workflows/release.yml` が実例です（Windows ランナーでビルドし、そのあとの手順は valles と同じ。同じワークフローが Quest 用の Android ジョブも並行して回します）。

   > このワークフローが書くのは **alpha のマニフェスト**（`tools/<tool>-alpha.json`）と archive スナップショットだけです。beta（`tools/<tool>.json`）に触れてはいけません。

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

| 症状 | 対処 |
|---|---|
| マニフェストを取得したら古いままに見える | `raw.githubusercontent.com` は最大 5 分ほどキャッシュします。失敗と断ずる前に API で実体を見てください: `gh api "repos/lee-lab/tools-dist/contents/tools/<tool>.json" --jq '.content' \| base64 -d` |
| 昇格ワークフローがバージョンで弾かれる | `version` の先頭に `v` を付けています。`1.2.0` の形で渡してください |
| 昇格ワークフローが「alpha と一致しない」で止まる | 昇格できるのは現在の alpha だけです。alpha マニフェストの実際の値を取得して渡してください。alpha リリースの CI がまだ完走していない可能性もあります |
| タグを push したが CI が起動しない | タグ形式がワークフローの `on.push.tags` と一致していません（`v1.2.0` は一致、`V1.2.0` や `1.2.0` は不一致） |
| リリース CI が失敗した | 原因を直して `main` に push し、**同じタグのまま Actions から `workflow_dispatch` で再実行**してください。push 済みのタグは消さないこと（tools-dist 側に Release が作られている可能性があり、整合の判断が要ります）。どうしてもやり直すならバージョンを上げる方が安全です |
| Quest のアップロードが `version code already exists`（MMDAgent-EX） | 同一 versionCode での再アップロードです。ワークフローを再実行して番号を進めてください |
| 利用者に新版が見えない（Quest） | そのアカウントが該当チャネルのメンバーに登録されているか確認してください。ALPHA と BETA のメンバーリストは別管理です |

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

### 廃止済みの旧経路（MMDAgent-EX）

かつて `vX.Y.Z` タグの GitHub Release に Windows zip（full / diff バンドル）を添付していた開発者向け配布は**廃止しました**。`v3.12.0` が最後で、過去の Release はアーカイブとしてそのまま残しますが、新しく作らないし更新もしません。共同研究者は alpha チャネルへ移行済みです。**full / diff バンドルの運用を復活させないでください。**

---

## 関連ドキュメント

| 参照先 | 内容 |
|---|---|
| [development-notes.md](development-notes.md) | tools-dist 側の設計の背景・実装メモ |
| [user-guide.ja.md](user-guide.ja.md) / [user-guide.en.md](user-guide.en.md) | 利用者に渡すインストール手順 |
| [CLAUDE.md](../CLAUDE.md) | インストーラを編集するときの注意点 |
| MMDAgent-EX `dev/windows-distribution.md` | Windows 配布の仕組み（ツール側）— 配布物の中身、VC++ ランタイム同梱、欠落 DLL 検査 |
| MMDAgent-EX `dev/android-cicd.md` | Quest 3 配布の仕組み — Meta 開発組織の初期設定、署名 keystore、versionCode 採番、BETA 昇格 |
| 各ツールの `CLAUDE.md`（`## Channel Release`） | ツール名・タグ形式・ワークフローファイルの定義。`/release-alpha` と `/release-beta` はここを読んで動きます |
