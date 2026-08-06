# Lee Lab ツール配布

研究室で開発しているツールを Windows へ簡単に導入するための配布リポジトリです。

利用者は **Python をインストールする必要はありません**。インストーラが必要なものをすべて自動で用意します。

---

## インストール方法

1. スタートメニューで `PowerShell` と入力し、**Windows PowerShell** を起動します（管理者権限は不要です）。
2. 次の 1 行をコピーして貼り付け、Enter を押します。

```powershell
irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

3. 画面の指示に従ってツールを選びます。
4. 完了すると、デスクトップに起動用のアイコンができます。

インストールには数分かかります。途中で閉じずにお待ちください。

### 必要なディスク容量

Valles の場合、およそ **4.5GB** を使用します。内訳は次のとおりです。

| 用途 | 容量 | 備考 |
|---|---|---|
| アプリ本体と実行環境 | 約 2.2GB | ツールごとに必要 |
| ダウンロードの控え | 約 2.2GB | **全ツールで共有**。更新を速くするために保持されます |

2 つ目のツールを入れるときは、共有部分が再利用されるため必要な容量は少なくて済みます。更新も、この控えのおかげで十数秒で完了します。

ディスクの空きが厳しい場合、次のコマンドで控えを削除できます（次回の更新が遅くなるだけで、動作には影響しません）。

```powershell
& "$env:USERPROFILE\.local\bin\uv.exe" cache clean
```

### 更新のしかた

**同じコマンドをもう一度実行してください。** 新しいバージョンがあれば更新されます。設定内容やダウンロード済みのモデルはそのまま引き継がれます。

### アンインストールのしかた

Windows の **設定 > アプリ > インストールされているアプリ** の一覧から、ツール名を選んでアンインストールしてください。

---

## 配布中のツール

| ツール | 説明 |
|---|---|
| [Valles](https://github.com/lee-lab/valles) | MMDAgent-EX のための遠隔操作アプリケーション |

---

## 困ったときは

**「このシステムではスクリプトの実行が無効になっているため…」と出る**

上記のコマンドは `irm ... | iex` の形式なので、通常この制限を受けません。それでも出る場合は、PowerShell で次を実行してから、もう一度お試しください。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**アプリが起動しない / 起動してすぐ消える**

スタートメニューの `Lee Lab` フォルダにある **「（ツール名）(診断モード)」** から起動してください。黒い画面にエラー内容が表示されるので、その内容を開発者にお知らせください。

**インストールが途中で止まる**

社内ネットワークのプロキシや、ウイルス対策ソフトが通信を遮断している可能性があります。エラーメッセージをそのままコピーして開発者にご連絡ください。

**64bit 版の Windows が必要です、と出る**

このツール群は 64bit 版 Windows 10 / 11 専用です。ARM 版 Windows には対応していません。

---

## 開発者向け

### リポジトリの構成

```
tools-dist/
├── install.ps1        共通インストーラ（利用者はこれを実行する）
├── tools/
│   ├── index.json     配布中のツール一覧（インストーラのメニューの元）
│   └── <tool>.json    ツールごとのマニフェスト
├── wheels/            PyPI に無いビルド済み wheel
└── scripts/           wheel のビルドなど、メンテナンス用スクリプト
```

ツール本体の zip は、このリポジトリの **Releases** に置きます。タグ名は `<tool>-v<version>`（例: `valles-v1.0.0`）の形式でツールごとに名前空間を分けます。

> **注意:** GitHub の `/releases/latest` は全ツール横断で最新の 1 件を返すため、ここでは使えません。各ツールの「現在の配布バージョン」は `tools/<tool>.json` が唯一の情報源です。リリース公開時は必ずマニフェストも更新してください（後述のワークフローが自動で行います）。

### マニフェストの項目

| 項目 | 説明 |
|---|---|
| `version` | 現在配布中のバージョン |
| `python` | 必要な Python のバージョン。uv が自動で用意する |
| `package.url` | 本体 zip の URL（Releases の添付ファイル） |
| `package.sha256` | zip の SHA256。インストーラが検証する |
| `requirements` | zip 内の依存定義ファイル名 |
| `entry` | 起動するスクリプト（zip のルートからの相対パス） |
| `icon` | ショートカットのアイコン（`.ico`） |
| `wheels` | PyPI に無く、このリポジトリから供給する wheel |
| `preserve` | **更新時に引き継ぐファイル・フォルダ**。設定やキャッシュを指定する |
| `shortcuts` | デスクトップ / スタートメニュー / 診断モードの各ショートカットを作るか |
| `notes` | インストール完了時に表示する補足 |

`preserve` の指定漏れは、更新のたびに利用者の設定が消えるという分かりにくい不具合になります。ツールを追加するときは必ず確認してください。

### 新しいツールを追加する

1. ツール側のリポジトリに、`requirements.txt` と起動スクリプト、`.ico` を用意する
2. `tools/<name>.json` を作る（`tools/valles.json` を雛形にする）
3. `tools/index.json` に 1 行追加する
4. ツール側に `.github/workflows/release.yml` を置く（valles のものを雛形にする）
5. ツール側のリポジトリに `TOOLS_DIST_TOKEN` シークレットを登録する

`TOOLS_DIST_TOKEN` は、このリポジトリに対して `Contents: read and write` 権限を持つ fine-grained personal access token です。GitHub Actions の `GITHUB_TOKEN` は自分のリポジトリしか書けないため、クロスリポジトリ公開には使えません。

トークン作成時の設定は次のとおりです。必要な権限は `Contents` の 1 つだけで、`Workflows` 権限は不要です（`.github/workflows/` を書き換えないため）。

| 項目 | 値 |
|---|---|
| Resource owner | `lee-lab`（自分のアカウントにするとアクセスできません） |
| Repository access | `Only select repositories` → `lee-lab/tools-dist` |
| Repository permissions | `Contents: Read and write` |

> **組織シークレットは使えません。** lee-lab は GitHub Free プランであり、組織シークレットは公開リポジトリからしか参照できません。ツール側のリポジトリは通常プライベートなので、**ツールごとにリポジトリシークレットとして登録**してください。同じトークンを各リポジトリに登録すれば流用できます。

```shell
gh secret set TOOLS_DIST_TOKEN --repo lee-lab/<tool>
```

トークンには有効期限があり、切れるとリリースワークフローが 403 で失敗します。エラーの見た目が権限設定の誤りと区別しづらいため、期限を長めに設定するか、期限日を記録しておいてください。

### PyOgg の wheel を再ビルドする

PyPI の PyOgg は 0.6.14a1 までで、Valles が使う `OpusEncoder` / `OpusDecoder` を含みません。GitHub 版 0.7 が必要ですが、`requirements.txt` に `git+https://...` と書くと利用者の PC に Git が必要になってしまうため、ビルド済み wheel をこのリポジトリに置いています。

```shell
./scripts/build-pyogg-wheel.sh
```

PyOgg の `setup.py` はクロスビルドに対応しているため、Linux / macOS からでも Windows 向け wheel を生成できます。DLL の同梱と必要な API の有無はスクリプト内で検証しています。

### インストーラを編集するときの注意

- **UTF-8 BOM 付きで保存すること。** Windows PowerShell 5.1 は BOM の無い UTF-8 ファイルを環境の既定コードページ（日本語環境では cp932）として読むため、BOM が無いと日本語が壊れて構文エラーになります。
- **Windows PowerShell 5.1 の構文で書くこと。** 三項演算子や `??` など PowerShell 7 の構文は使えません。利用者の環境に PowerShell 7 があるとは限りません。
- 構文確認は Windows 上で次を実行します。

```powershell
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile("install.ps1", [ref]$null, [ref]$e)
$e
```
