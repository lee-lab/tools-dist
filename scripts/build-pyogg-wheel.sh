#!/usr/bin/env bash
#
# PyOgg 0.7 の Windows (win_amd64) 向け wheel をビルドする。
#
# PyPI に公開されている PyOgg は 0.6.14a1 までで、OpusEncoder / OpusDecoder が
# 含まれていない。Valles はこの 2 つを使うため GitHub 版 0.7 が必須。
# しかし requirements.txt に git+https://... と書くと利用者の PC に Git が必要に
# なってしまうので、あらかじめ wheel をビルドして wheels/ に置いておく。
#
# PyOgg の setup.py は PYTHON_PYOGG_PLATFORM / PYTHON_PYOGG_ARCHITECTURE 環境変数で
# クロスビルドに対応しているため、Linux / macOS 上から Windows 向け wheel を作れる。
# 同梱される DLL (ogg / opus / opusenc / opusfile / vorbis / FLAC) は PyOgg の
# リポジトリに含まれているものがそのまま使われる。
#
# 使い方:
#   ./scripts/build-pyogg-wheel.sh
# 生成物:
#   wheels/PyOgg-0.7-py2.py3-none-win_amd64.whl

set -euo pipefail

PYOGG_REPO="https://github.com/TeamPyOgg/PyOgg.git"
PYOGG_REF="master"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHEELS_DIR="$REPO_ROOT/wheels"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> PyOgg を取得中 ($PYOGG_REF)"
git clone -q --depth 1 --branch "$PYOGG_REF" "$PYOGG_REPO" "$WORK_DIR/PyOgg"

VERSION="$(sed -n "s/^__version__ = '\(.*\)'/\1/p" "$WORK_DIR/PyOgg/pyogg/__init__.py")"
echo "==> PyOgg バージョン: $VERSION"
if [ "$VERSION" != "0.7" ]; then
    echo "警告: 想定していた 0.7 ではなく $VERSION です。マニフェストの更新が必要かもしれません。" >&2
fi

echo "==> ビルド用の仮想環境を作成中"
python3 -m venv "$WORK_DIR/venv"
# setuptools 70 以降 / wheel 0.44 以降は bdist_wheel の import 経路が変わり、
# PyOgg の setup.py が platform tag を付けられなくなる（-any の wheel が出来てしまう）ため
# 古いバージョンに固定する。
"$WORK_DIR/venv/bin/pip" -q install "setuptools<70" "wheel<0.44"

echo "==> win_amd64 向けにクロスビルド中"
(
    cd "$WORK_DIR/PyOgg"
    PYTHON_PYOGG_PLATFORM=Windows \
    PYTHON_PYOGG_ARCHITECTURE=64bit \
        "$WORK_DIR/venv/bin/python" setup.py -q bdist_wheel
)

WHEEL_PATH="$(ls "$WORK_DIR/PyOgg/dist/"*.whl)"
WHEEL_NAME="$(basename "$WHEEL_PATH")"

# platform tag が正しく付いたか検証する。-any になっていたらビルド環境の問題。
case "$WHEEL_NAME" in
    *win_amd64.whl) ;;
    *) echo "エラー: platform tag が win_amd64 ではありません: $WHEEL_NAME" >&2; exit 1 ;;
esac

# DLL が同梱されているか検証する。DLL が無いと Windows 上で import に失敗する。
echo "==> 同梱 DLL を検証中"
"$WORK_DIR/venv/bin/python" - "$WHEEL_PATH" <<'PY'
import sys, zipfile
required = [
    "libFLAC.dll", "libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll",
    "libvorbis.dll", "libvorbisfile.dll", "ogg.dll",
    "opus.dll", "opusenc.dll", "opusfile.dll",
]
names = zipfile.ZipFile(sys.argv[1]).namelist()
missing = [d for d in required if f"pyogg/libs/win_amd64/{d}" not in names]
if missing:
    sys.exit("エラー: DLL が不足しています: " + ", ".join(missing))
# Valles が使う API が含まれているか（0.6.x では OpusEncoder / OpusDecoder が無い）
src = zipfile.ZipFile(sys.argv[1]).read("pyogg/__init__.py").decode()
for api in ("OpusEncoder", "OpusDecoder", "VorbisFile"):
    if api not in src:
        sys.exit(f"エラー: {api} が見つかりません。PyOgg のバージョンを確認してください。")
print("    DLL 9 個・必要な API をすべて確認")
PY

mkdir -p "$WHEELS_DIR"
rm -f "$WHEELS_DIR"/PyOgg-*.whl
cp "$WHEEL_PATH" "$WHEELS_DIR/"

echo "==> 完了: wheels/$WHEEL_NAME"
echo "    sha256: $(sha256sum "$WHEELS_DIR/$WHEEL_NAME" | cut -d' ' -f1)"
