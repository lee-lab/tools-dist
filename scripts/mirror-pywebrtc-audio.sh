#!/usr/bin/env bash
#
# pywebrtc-audio 0.1.0 の PyPI 公開成果物を wheels/ にミラーする（再取得・照合）。
#
# Valles の音声処理コア（WebRTC NS / AGC2 / AEC3、lee-lab/valles#67）がこの
# パッケージに依存している。上流（strands-labs/pywebrtc-audio）は公開から浅く
# コミット数も少ない新興プロジェクトなので、消えても依存を維持できるように全成果物を
# 退避してある。ビルドはしない（PyPI の成果物そのものを置くことに意味がある）ため、
# このスクリプトが wheels/ の「再現できる手順」にあたる。
#
# 照合の基準は wheels/pywebrtc-audio-0.1.0/SHA256SUMS。ダイジェストは監査時
# (2026-08-13) に PyPI の公表値と Sigstore / PyPI attestation の両方と一致すること
# を確認した値で、valles 側の requirements-pywebrtc.txt に書かれた --hash と同じ
# ものである。したがってここでの不一致は「上流が差し替わった」ことを意味する。
#
# 使い方:
#   ./scripts/mirror-pywebrtc-audio.sh            # PyPI から再取得して照合・配置
#   ./scripts/mirror-pywebrtc-audio.sh --check     # ローカルのファイルだけを照合（通信なし）
#
# 版を上げるときは、先に docs/pywebrtc-audio-supply-chain.md（valles 側）の
# 再監査チェックリストを通し、SHA256SUMS を作り直してからこのスクリプトを回すこと。

set -euo pipefail

PKG="pywebrtc-audio"
VERSION="0.1.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$REPO_ROOT/wheels/$PKG-$VERSION"
SUMS_FILE="$DEST_DIR/SHA256SUMS"
EXPECTED_COUNT=29   # wheel 28 + sdist 1（cp310-cp313 x 7 プラットフォーム）

MODE="mirror"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
elif [ $# -gt 0 ]; then
    echo "使い方: $0 [--check]" >&2
    exit 2
fi

if [ ! -f "$SUMS_FILE" ]; then
    echo "エラー: $SUMS_FILE が見つかりません" >&2
    exit 1
fi

sums_count="$(grep -c . "$SUMS_FILE")"
if [ "$sums_count" -ne "$EXPECTED_COUNT" ]; then
    echo "エラー: SHA256SUMS の行数が $sums_count です（期待 $EXPECTED_COUNT）。" >&2
    echo "       成果物の増減は上流の再アップロードを意味します。監査をやり直すこと。" >&2
    exit 1
fi

# --check: ローカルのファイルだけを照合する（通信しない）
if [ "$MODE" = "check" ]; then
    echo "==> ローカルの成果物を SHA256SUMS と照合中 ($sums_count 件)"
    (cd "$DEST_DIR" && sha256sum -c --quiet SHA256SUMS)
    echo "==> 完了: すべて一致"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> PyPI のメタデータを取得中 ($PKG $VERSION)"
curl -fsSL "https://pypi.org/pypi/$PKG/$VERSION/json" -o "$WORK_DIR/pypi.json"

# PyPI が公表するダイジェストと SHA256SUMS を突き合わせ、ダウンロード対象の一覧
# （URL とファイル名）を書き出す。片方にしか無いファイルがあれば失敗させる:
# 不変であるはずのリリースの成果物が増減しているということなので、黙って追随して
# はいけない。
python3 - "$WORK_DIR/pypi.json" "$SUMS_FILE" "$WORK_DIR/urls.txt" <<'PY'
import json, sys

pypi_path, sums_path, out_path = sys.argv[1:4]

with open(pypi_path) as f:
    data = json.load(f)
remote = {}
for u in data["urls"]:
    remote[u["filename"]] = (u["digests"]["sha256"], u["url"])

expected = {}
with open(sums_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        digest, name = line.split(None, 1)
        expected[name.strip()] = digest

problems = []
for name in sorted(set(expected) | set(remote)):
    if name not in remote:
        problems.append("PyPI に無い: %s" % name)
    elif name not in expected:
        problems.append("SHA256SUMS に無い（上流が追加した）: %s" % name)
    elif remote[name][0] != expected[name]:
        problems.append("ダイジェスト不一致: %s\n    SHA256SUMS: %s\n    PyPI      : %s"
                        % (name, expected[name], remote[name][0]))
if problems:
    sys.exit("エラー: PyPI の内容が監査時と異なります。\n  " + "\n  ".join(problems))

with open(out_path, "w") as f:
    for name in sorted(expected):
        f.write("%s\t%s\n" % (remote[name][1], name))
print("    %d 件すべてのダイジェストが PyPI の公表値と一致" % len(expected))
PY

echo "==> 成果物を取得中"
while IFS=$'\t' read -r url name; do
    curl -fsSL "$url" -o "$WORK_DIR/$name"
done < "$WORK_DIR/urls.txt"

echo "==> 取得したファイルを SHA256SUMS と照合中"
cp "$SUMS_FILE" "$WORK_DIR/SHA256SUMS"
(cd "$WORK_DIR" && sha256sum -c --quiet SHA256SUMS)

echo "==> wheels/ に配置中"
mkdir -p "$DEST_DIR"
while IFS=$'\t' read -r url name; do
    cp "$WORK_DIR/$name" "$DEST_DIR/$name"
done < "$WORK_DIR/urls.txt"

echo "==> 完了: wheels/$PKG-$VERSION/ ($sums_count 件)"
echo "    以後の日常的な確認は --check（通信なし）で足りる"
