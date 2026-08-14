# pywebrtc-audio 0.1.0 ミラー

PyPI の [pywebrtc-audio](https://pypi.org/project/pywebrtc-audio/) 0.1.0 の全公開成果物
（wheel 28 + sdist 1）のミラー。Valles の音声処理コア（WebRTC NS / AGC2 / AEC3、
lee-lab/valles#67）が依存しており、上流（strands-labs/pywebrtc-audio、公開 3 ヶ月・
コミット 2 件の新興プロジェクト）が消えても依存を維持できるように退避している。

- 取得日: 2026-08-13。全ファイルの sha256 は PyPI の公表ダイジェストおよび
  Sigstore/PyPI attestation（公開 GitHub Actions run 26075351130、コミット 9c1c2a2、
  タグ v0.1.0 に紐付く）と一致することを検証済み。検証手順と監査の全文は
  lee-lab/valles#67 を参照
- `SHA256SUMS` で照合できる: `sha256sum -c SHA256SUMS`
- sdist はタグ付きソースツリーとバイト一致で、ネットワーク取得なしでビルド可能
  （自前ビルドの最終フォールバック）。要 C++17（MSVC は C++20）+ CMake + pybind11
- PyPI には無署名の手動アップロード版 0.0.1（空スタブ）も存在する。**絶対に
  0.1.0 以外を使わないこと**（Valles 側は `==0.1.0` 固定）
- ライセンス: Apache-2.0（各 wheel 内に LICENSE / NOTICE を同梱）
