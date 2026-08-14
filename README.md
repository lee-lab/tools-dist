# Lee Lab Tools

Easy installation of Lee Lab tools on Windows 10 / 11 (64-bit).

**You do not need to install Python.** The installer sets up everything for you.

```powershell
irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

Open **Windows PowerShell** from the Start menu, paste the line above, and press Enter. Administrator rights are not required.

> **Full instructions — please read this first:**
> **[Installation Guide (English)](docs/user-guide.en.md)** ・ **[インストール手順（日本語）](docs/user-guide.ja.md)**

Tools that have not been released publicly yet are distributed in encrypted form. You will be asked for a password during installation — please use the one you received from your contact.

---

## Available tools

| Tool | Description |
|---|---|
| [Valles](https://github.com/lee-lab/valles) | Remote control application for MMDAgent-EX |
| [MMDAgent-EX](https://github.com/lee-lab/MMDAgent-EX) | Voice interaction platform with 3D CG characters |

---

## Documentation

| ドキュメント | 対象 | 言語 |
|---|---|---|
| [インストール手順](docs/user-guide.ja.md) / [Installation Guide](docs/user-guide.en.md) | 利用者 | 日本語 / English |
| [管理者マニュアル](docs/admin-guide.md) | リリース管理の担当者 | 日本語 |
| [開発記録](docs/development-notes.md) | 開発者（調査結果・設計判断の記録） | 日本語 |
| [CLAUDE.md](CLAUDE.md) | インストーラを編集する人への注意点 | 日本語 |

---

## リポジトリの構成（開発者向け）

```
tools-dist/
├── install.ps1        共通インストーラ（利用者はこれを実行する）
├── tools/
│   ├── index.json     配布中のツール一覧（インストーラのメニューの元）
│   └── <tool>.json    ツールごとのマニフェスト
├── wheels/            PyPI に無い wheel と、監査済み成果物のミラー
├── scripts/           wheel のビルド・ミラーなど、メンテナンス用スクリプト
├── tests/             インストーラのテスト（実行しても何もインストールされない）
└── docs/              各種ドキュメント
```

ツール本体の zip は、このリポジトリの **Releases** に置きます。タグ名は `<tool>-v<version>`（例: `valles-v1.0.0`）の形式でツールごとに名前空間を分けます。

> **配布中バージョンの唯一の情報源は `tools/<tool>.json` です。** GitHub の `/releases/latest` は全ツール横断で最新の 1 件を返すため使えません。リリース時のマニフェスト更新はワークフローが自動で行います。

リリース作業・ツールの追加・パスワードの変更などの手順は [管理者マニュアル](docs/admin-guide.md) を参照してください。

### インストーラを編集するときの必須事項

- **`install.ps1` は BOM 無し・純 ASCII で保存すること。コメントも英語で書きます。** `irm | iex` で実行する際、BOM があるとブロックコメントが認識されずスクリプト全体が壊れます（テストで強制しています）
- **利用者に表示するメッセージは英語で書くこと。** 利用者に英語母語話者が含まれるため
- **Windows PowerShell 5.1 の構文で書くこと。** 利用者の環境に PowerShell 7 があるとは限りません
- **変更したら Windows 実機でテストを通すこと。** 静的な構文チェックでは検出できない不具合が多数あります

```powershell
powershell -ExecutionPolicy Bypass -File tests\test-install.ps1
powershell -ExecutionPolicy Bypass -File tests\test-install-flow.ps1
```

詳細と、過去に踏んだ具体的な罠は [CLAUDE.md](CLAUDE.md) にまとめてあります。
