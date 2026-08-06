# Lee Lab Tools

Easy installation of Lee Lab tools on Windows.

**You do not need to install Python.** The installer sets up everything for you.

---

## Installing

1. Type `PowerShell` into the Start menu and open **Windows PowerShell**. Administrator rights are not required.
2. Copy the line below, paste it in, and press Enter.

```powershell
irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

3. Follow the on-screen prompts to pick a tool.
4. **If you are asked for a password**, enter the one you received from the developer (see below).
5. When it finishes, a shortcut is placed on your desktop.

Installation takes a few minutes. Please leave the window open until it completes.

### About the password

Tools that have not been released publicly yet are distributed in encrypted form. You will be asked for a password once during installation. Enter the password you received from the developer.

- The password is **required every time you update**, so keep a note of it.
- If it will not accept your password, it may be incorrect, or it may have changed with a newer release. Please check with the developer.
- Do not share the password with anyone outside the project.

### Disk space

Valles needs roughly **4.5 GB**:

| What | Size | Notes |
|---|---|---|
| The app and its runtime | ~2.2 GB | Needed per tool |
| Cached downloads | ~2.2 GB | **Shared by all tools.** Kept so that updates are fast |

Installing a second tool needs much less space, because the shared part is reused. The cache is also why updates finish in a few seconds.

If you are short on disk space, you can delete the cache. This only makes the next update slower; nothing stops working.

```powershell
& "$env:USERPROFILE\.local\bin\uv.exe" cache clean
```

### Updating

**Run the same command again.** If a newer version exists, it is installed. Your settings and any downloaded model files are carried over.

### Uninstalling

Open Windows **Settings > Apps > Installed apps**, find the tool by name, and uninstall it.

---

## Available tools

| Tool | Description |
|---|---|
| [Valles](https://github.com/lee-lab/valles) | Remote control application for MMDAgent-EX |

---

## Troubleshooting

**"running scripts is disabled on this system"**

The command above uses the `irm ... | iex` form, which is normally not affected by this restriction. If you still see it, run the following and then try again:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**The app does not start, or the window disappears immediately**

Start it from **"(tool name) (Diagnostic Mode)"** in the `Lee Lab` folder of your Start menu. A console window will show the error message. Please send that message to the developer.

**Installation stops partway through**

A proxy on your network or antivirus software may be blocking the connection. Please copy the error message and send it to the developer.

**"64-bit Windows is required"**

These tools run only on 64-bit Windows 10 / 11. Windows on ARM is not supported.

---

## 開発者向け（日本語）

> 以下は開発・運用担当者向けの記述です。利用者向けの案内は上記の英語部分を参照してください。
> インストーラが利用者に表示するメッセージは、英語話者の利用者がいるため**すべて英語**にしています。追加・変更するときも英語で書いてください。

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

### 配布物の暗号化（一般公開前のツール）

一般公開前のツールは、配布物を暗号化した状態で Releases に置きます。このリポジトリは公開されているため、暗号化しないと誰でも取得できてしまうためです。

- 形式は OpenSSL の `enc -aes-256-cbc -pbkdf2 -md sha256 -salt` と同じ
- 暗号化はリリースワークフローが行い、パスワードはツール側リポジトリの `PAYLOAD_PASSWORD` シークレットから読む
- マニフェストの `sha256` は**復号後**の zip のもの。インストーラは復号結果をこれと照合するため、パスワード誤りを確実に検出できる
- 反復回数はマニフェストの `kdf_iterations` に記録される。将来引き上げても、既にインストール済みの利用者に影響はない

```shell
gh secret set PAYLOAD_PASSWORD --repo lee-lab/<tool>
```

> **この暗号化が守るもの・守らないもの**
>
> 守るのは「配布物を偶然拾った第三者が中身を取り出すこと」です。パスワードを知る利用者による再配布は防げませんし、インストール後はソースが平文でディスク上に置かれます。access control ではなく、意図しない取得を防ぐための措置と理解してください。

#### 一般公開に切り替えるとき

ツール側リポジトリの `PAYLOAD_PASSWORD` シークレットを**削除**し、次のリリースを行うだけです。ワークフローは暗号化を行わず、マニフェストからも `encrypted` が外れます。インストーラはパスワードを尋ねなくなります。

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
