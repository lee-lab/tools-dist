#!/bin/bash
#
# install.sh のテスト（macOS 上で実行する）。
#
# ネットワークには出ず、実際の HOME にも何も書かない。前半は install.sh を
# source して（main を走らせない「ライブラリモード」）関数を個別に検証し、後半は
# HOME を一時フォルダに向け、file:// の配布物で インストール → 更新 →
# チャネル切り替え → アンインストール を通しで走らせる。
#
# 実行方法:
#     bash tests/test-install.sh
#
# shellcheck が入っていればそれも通す（brew install shellcheck）。

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO/install.sh"
FIXTURES="$REPO/tests/fixtures"
SAMPLE_JSON="$FIXTURES/sample.json"
SAMPLE_ENC="$FIXTURES/sample.enc"
MAC_MANIFEST="$FIXTURES/mmdagent-ex-alpha-macos.json"
ALPHA_MANIFEST="$REPO/tools/mmdagent-ex-alpha.json"

PASS=0
FAIL=0

check() {
    local name="$1" cond="$2" detail="${3:-}"
    if [ "$cond" = 0 ]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$name"
        if [ -n "$detail" ]; then printf '%s\n' "$detail" | sed 's/^/        | /'; fi
        FAIL=$((FAIL + 1))
    fi
}

# check_cmd NAME COMMAND...: コマンドの成否で判定する。
check_cmd() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then check "$name" 0; else check "$name" 1; fi
}

# 出力に文字列が含まれるか。
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

section() { printf '\n%s\n' "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/leelab-test.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"

# ライブラリモードで install.sh を読み込んだ新しい bash の中でスニペットを実行する。
# install.sh の set -euo pipefail はそのまま効かせる（本番と同じ条件で動かすため）。
# HOME はテスト用に差し替え、init_globals で派生パスを作り直す。
lib() {
    local home="$1" snippet="$2"
    HOME="$home" bash -c 'source "$1" || exit 99; init_globals; eval "$2"' _ "$INSTALLER" "$snippet"
}

FIXTURE_PASSWORD="$(plutil -extract password raw -o - "$SAMPLE_JSON")"
FIXTURE_ITER="$(plutil -extract kdf_iterations raw -o - "$SAMPLE_JSON")"
FIXTURE_SHA="$(plutil -extract plaintext_sha256 raw -o - "$SAMPLE_JSON")"

# ---------------------------------------------------------------------------
section 'install.sh のファイル形式'
# ---------------------------------------------------------------------------

check_cmd 'bash -n (syntax)' bash -n "$INSTALLER"
if command -v shellcheck >/dev/null 2>&1; then
    out="$(shellcheck "$INSTALLER" 2>&1)"; rc=$?
    check 'shellcheck' "$rc" "$out"
else
    printf '  SKIP  shellcheck (not installed)\n'
fi
n="$(LC_ALL=C tr -d '\n\040-\176' <"$INSTALLER" | wc -c | tr -d ' ')"
check 'pure ASCII (no tabs, no control characters)' "$([ "$n" = 0 ] && echo 0 || echo 1)" "($n byte(s))"
n="$(LC_ALL=C tr -cd '\r' <"$INSTALLER" | wc -c | tr -d ' ')"
check 'LF line endings' "$([ "$n" = 0 ] && echo 0 || echo 1)" "($n CR)"
check 'starts with #!/bin/bash' "$([ "$(head -n 1 "$INSTALLER")" = '#!/bin/bash' ] && echo 0 || echo 1)"
check 'ends with a newline' "$([ "$(tail -c 1 "$INSTALLER" | od -An -c | tr -d ' ')" = '\n' ] && echo 0 || echo 1)"
# 途中で切れたダウンロードが半端に実行されないよう、main を呼ぶのは末尾だけ。
last="$(grep -v '^[[:space:]]*$' "$INSTALLER" | tail -n 3 | tr -d '\n')"
check 'main is called only at the very end' "$([ "$last" = 'if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then    main "$@"fi' ] && echo 0 || echo 1)" "($last)"

# ---------------------------------------------------------------------------
section 'エントリポイント（curl | bash / ファイル実行 / source）'
# ---------------------------------------------------------------------------

GUARD_HOME="$SANDBOX/guard-home"
mkdir -p "$GUARD_HOME"
# 存在しない file:// を指すので、main が走れば index.json の取得で止まる。
out="$(cat "$INSTALLER" | HOME="$GUARD_HOME" LEELAB_BASE_URL="file://$SANDBOX/nowhere" bash 2>&1)"; rc=$?
check 'curl | bash path runs main' "$( (contains "$out" 'Lee Lab Tool Installer' && contains "$out" 'Could not fetch the distribution info') && echo 0 || echo 1)" "(rc=$rc)"
check 'curl | bash path exits 1 on a fetch error' "$([ "$rc" = 1 ] && echo 0 || echo 1)" "(rc=$rc)"
out="$(HOME="$GUARD_HOME" LEELAB_BASE_URL="file://$SANDBOX/nowhere" bash "$INSTALLER" 2>&1)"; rc=$?
check 'file path runs main' "$( (contains "$out" 'Lee Lab Tool Installer' && [ "$rc" = 1 ]) && echo 0 || echo 1)" "(rc=$rc)"
out="$(HOME="$GUARD_HOME" bash -c 'source "$1"; echo sourced-ok' _ "$INSTALLER" 2>&1)"
check 'source does not run main' "$( (contains "$out" 'sourced-ok' && ! contains "$out" 'Lee Lab Tool Installer') && echo 0 || echo 1)" "($out)"
check 'nothing was written to the guard HOME' "$([ -z "$(ls -A "$GUARD_HOME")" ] && echo 0 || echo 1)"

H="$SANDBOX/unit-home"
mkdir -p "$H"

# ---------------------------------------------------------------------------
section 'チャネルとマニフェストのパス'
# ---------------------------------------------------------------------------

check "resolve_channel '' = beta" "$([ "$(lib "$H" 'resolve_channel ""')" = beta ] && echo 0 || echo 1)"
check "resolve_channel 'Alpha' = alpha" "$([ "$(lib "$H" 'resolve_channel Alpha')" = alpha ] && echo 0 || echo 1)"
check "resolve_channel ' BETA ' = beta" "$([ "$(lib "$H" 'resolve_channel " BETA "')" = beta ] && echo 0 || echo 1)"
out="$(lib "$H" 'resolve_channel gamma' 2>&1)"; rc=$?
check 'resolve_channel rejects an unknown channel' "$( ([ "$rc" = 1 ] && contains "$out" "no release channel named 'gamma'") && echo 0 || echo 1)" "(rc=$rc)"

mp() { lib "$H" "manifest_path '$1' '$2'"; }
check 'manifest_path beta keeps the path' "$([ "$(mp tools/valles.json beta)" = tools/valles.json ] && echo 0 || echo 1)"
check 'manifest_path empty channel keeps the path' "$([ "$(mp tools/valles.json '')" = tools/valles.json ] && echo 0 || echo 1)"
check 'manifest_path alpha inserts the channel' "$([ "$(mp tools/valles.json alpha)" = tools/valles-alpha.json ] && echo 0 || echo 1)"
check 'manifest_path without an extension appends' "$([ "$(mp tools/valles alpha)" = tools/valles-alpha ] && echo 0 || echo 1)"
check 'manifest_path ignores a dot in a folder' "$([ "$(mp my.tools/valles alpha)" = my.tools/valles-alpha ] && echo 0 || echo 1)"
r="$(mp tools/index.json alpha)"
check 'index.json default path maps to the alpha file' "$([ "$r" = tools/index-alpha.json ] && echo 0 || echo 1)" "($r)"

# ---------------------------------------------------------------------------
section 'マニフェストの読み取り（plutil）'
# ---------------------------------------------------------------------------

jg() { lib "$H" "json_get '$1' '$2' '${3:-}'"; }
check 'json_get string (sample.json password)' "$([ "$(jg "$SAMPLE_JSON" password)" = "$FIXTURE_PASSWORD" ] && echo 0 || echo 1)"
check 'json_get integer (kdf_iterations)' "$([ "$(jg "$SAMPLE_JSON" kdf_iterations)" = 200000 ] && echo 0 || echo 1)"
check 'json_get missing key gives the default' "$([ "$(jg "$SAMPLE_JSON" nosuch fallback)" = fallback ] && echo 0 || echo 1)"
check 'json_get on an array gives the default' "$([ "$(jg "$MAC_MANIFEST" notes dflt)" = dflt ] && echo 0 || echo 1)"
check 'json_get nested key with a hyphen (platforms.macos-arm64.exe)' "$([ "$(jg "$MAC_MANIFEST" platforms.macos-arm64.exe)" = MMDAgent-EX ] && echo 0 || echo 1)"
r="$(jg "$MAC_MANIFEST" platforms.macos-arm64.package.url)"
check 'json_get platforms package url' "$([ "$r" = 'https://github.com/lee-lab/tools-dist/releases/download/mmdagent-ex-v3.20.0/MMDAgent-EX-3.20.0-macos-arm64.zip.enc' ] && echo 0 || echo 1)" "($r)"
check 'json_get bool (encrypted)' "$([ "$(jg "$MAC_MANIFEST" platforms.macos-arm64.package.encrypted)" = true ] && echo 0 || echo 1)"
check 'json_get min_macos' "$([ "$(jg "$MAC_MANIFEST" platforms.macos-arm64.min_macos)" = 15 ] && echo 0 || echo 1)"
check 'json_get array element (vscode_extensions.0.id)' "$([ "$(jg "$MAC_MANIFEST" vscode_extensions.0.id)" = MMDAgent-EX.mmdagent-ex-lua ] && echo 0 || echo 1)"
check 'json_count notes = 5' "$([ "$(lib "$H" "json_count '$MAC_MANIFEST' notes")" = 5 ] && echo 0 || echo 1)"
check 'json_count preserve (missing) = 0' "$([ "$(lib "$H" "json_count '$MAC_MANIFEST' preserve")" = 0 ] && echo 0 || echo 1)"
check 'json_count on a string = 0' "$([ "$(lib "$H" "json_count '$MAC_MANIFEST' version")" = 0 ] && echo 0 || echo 1)"
check 'platforms block is a dictionary' "$([ "$(lib "$H" "json_type '$MAC_MANIFEST' platforms.macos-arm64")" = dictionary ] && echo 0 || echo 1)"
check 'current alpha manifest has no platforms block' "$([ -z "$(lib "$H" "json_type '$ALPHA_MANIFEST' platforms.macos-arm64")" ] && echo 0 || echo 1)"
check 'platform_key falls back to the top level' "$([ "$(lib "$H" "platform_key '$MAC_MANIFEST' notes")" = notes ] && echo 0 || echo 1)"
OVR="$SANDBOX/override.json"
sed 's/"min_macos": "15"/"min_macos": "15", "notes": ["Mac note"], "preserve": ["prefs"]/' "$MAC_MANIFEST" >"$OVR"
check 'platform_key prefers the platform block' "$([ "$(lib "$H" "platform_key '$OVR' notes")" = platforms.macos-arm64.notes ] && echo 0 || echo 1)"
out="$(lib "$H" "show_notes '$MAC_MANIFEST'")"
check 'show_notes prints the shared notes' "$(contains "$out" 'About 700 MB of free disk space' && echo 0 || echo 1)"
check 'show_notes drops notes about Windows' "$( ! contains "$out" 'Smart App Control' && echo 0 || echo 1)"
out="$(lib "$H" "show_notes '$OVR'")"
check 'show_notes uses the platform notes when present' "$( (contains "$out" 'Mac note' && ! contains "$out" '700 MB') && echo 0 || echo 1)"
NUL="$SANDBOX/null.json"
printf '{"a": null, "b": "x", "n": "\\u65e5\\u672c"}\n' >"$NUL"
check 'json_get null gives the default' "$([ "$(jg "$NUL" a dflt)" = dflt ] && echo 0 || echo 1)"
check 'json_get next to a null still works' "$([ "$(jg "$NUL" b)" = x ] && echo 0 || echo 1)"
check 'json_get decodes non-ASCII' "$([ "$(jg "$NUL" n)" = "$(printf '\346\227\245\346\234\254')" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
section '復号（OpenSSL 互換の固定データ）'
# ---------------------------------------------------------------------------

D="$SANDBOX/decrypt"
mkdir -p "$D"
lib "$H" "check_environment >/dev/null; decrypt_file '$SAMPLE_ENC' '$D/ok.bin' '$FIXTURE_PASSWORD' $FIXTURE_ITER"; rc=$?
check 'decrypt with the fixture password' "$rc"
check 'decrypted plaintext matches the recorded sha256' "$([ "$(shasum -a 256 "$D/ok.bin" 2>/dev/null | awk '{print $1}')" = "$FIXTURE_SHA" ] && echo 0 || echo 1)"
check 'decrypted size matches' "$([ "$(wc -c <"$D/ok.bin" | tr -d ' ')" = "$(plutil -extract plaintext_size raw -o - "$SAMPLE_JSON")" ] && echo 0 || echo 1)"
lib "$H" "check_environment >/dev/null; decrypt_file '$SAMPLE_ENC' '$D/bad.bin' 'wrong-password' $FIXTURE_ITER"; rc=$?
check 'wrong password fails' "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check 'wrong password leaves no output' "$([ ! -e "$D/bad.bin" ] && echo 0 || echo 1)"
lib "$H" "check_environment >/dev/null; decrypt_file '$SAMPLE_ENC' '$D/iter.bin' '$FIXTURE_PASSWORD' 100000"; rc=$?
ok=1
if [ "$rc" != 0 ] || [ "$(shasum -a 256 "$D/iter.bin" | awk '{print $1}')" != "$FIXTURE_SHA" ]; then ok=0; fi
check 'wrong iteration count does not give the plaintext' "$ok"
lib "$H" "check_environment >/dev/null; decrypt_file '$SAMPLE_JSON' '$D/notenc.bin' x 1000"; rc=$?
check 'a file without the Salted__ header is refused' "$([ "$rc" != 0 ] && echo 0 || echo 1)"

out="$(LEELAB_PASSWORD="$FIXTURE_PASSWORD" lib "$H" "check_environment >/dev/null; unlock_package '$SAMPLE_ENC' '$D/u.bin' '$FIXTURE_SHA' $FIXTURE_ITER Sample" 2>&1)"; rc=$?
check 'unlock_package accepts the right password' "$( ([ "$rc" = 0 ] && contains "$out" 'Password accepted') && echo 0 || echo 1)" "(rc=$rc)"
out="$(LEELAB_PASSWORD="wrong" lib "$H" "check_environment >/dev/null; unlock_package '$SAMPLE_ENC' '$D/u2.bin' '$FIXTURE_SHA' $FIXTURE_ITER Sample" 2>&1)"; rc=$?
check 'unlock_package stops on a wrong password' "$( ([ "$rc" = 1 ] && contains "$out" 'password was not correct') && echo 0 || echo 1)" "(rc=$rc)"
n="$(printf '%s\n' "$out" | grep -c 'Incorrect password' || true)"
check 'a wrong LEELAB_PASSWORD is tried only once' "$([ "$n" = 1 ] && echo 0 || echo 1)" "($n)"
out="$(LEELAB_PASSWORD="$FIXTURE_PASSWORD" lib "$H" "check_environment >/dev/null; unlock_package '$SAMPLE_ENC' '$D/u3.bin' '$(printf '0%.0s' $(seq 64))' $FIXTURE_ITER Sample" 2>&1)"; rc=$?
check 'unlock_package rejects a hash mismatch' "$([ "$rc" = 1 ] && [ ! -e "$D/u3.bin" ] && echo 0 || echo 1)" "(rc=$rc)"

# ---------------------------------------------------------------------------
section 'SHA-256 の照合'
# ---------------------------------------------------------------------------

check_cmd 'sha256_matches (right hash)' lib "$H" "sha256_matches '$D/ok.bin' '$FIXTURE_SHA'"
UPPER="$(printf '%s' "$FIXTURE_SHA" | tr '[:lower:]' '[:upper:]')"
check_cmd 'sha256_matches (upper case)' lib "$H" "sha256_matches '$D/ok.bin' '$UPPER'"
lib "$H" "sha256_matches '$D/ok.bin' deadbeef"; rc=$?
check 'sha256_matches (wrong hash) fails' "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check_cmd 'sha256_matches (empty = not checked)' lib "$H" "sha256_matches '$D/ok.bin' ''"

# ---------------------------------------------------------------------------
section '展開（ルートフォルダ 1 段の除去）'
# ---------------------------------------------------------------------------

Z="$SANDBOX/zip"
mkdir -p "$Z/src1/Tool-1.0.0/sub" "$Z/src2/a" "$Z/src3/Tool-2.0.0" "$Z/src3/__MACOSX/Tool-2.0.0"
printf 'x\n' >"$Z/src1/Tool-1.0.0/sub/f.txt"
printf '#!/bin/sh\n' >"$Z/src1/Tool-1.0.0/tool"
chmod 755 "$Z/src1/Tool-1.0.0/tool"
ln -s sub/f.txt "$Z/src1/Tool-1.0.0/link"
printf '.\n' >"$Z/src1/Tool-1.0.0/.hidden"
(cd "$Z/src1" && zip -qry "$Z/one.zip" Tool-1.0.0)
printf 'a\n' >"$Z/src2/a/f"
printf 'b\n' >"$Z/src2/b"
(cd "$Z/src2" && zip -qry "$Z/two.zip" a b)
printf 'c\n' >"$Z/src3/Tool-2.0.0/c"
printf 'junk\n' >"$Z/src3/__MACOSX/Tool-2.0.0/._c"
(cd "$Z/src3" && zip -qry "$Z/mac.zip" Tool-2.0.0 __MACOSX)

r="$(lib "$H" "extract_package '$Z/one.zip' '$Z/st1'")"
check 'single root folder is stripped' "$([ "$r" = "$Z/st1/Tool-1.0.0" ] && echo 0 || echo 1)" "($r)"
check 'files are extracted' "$([ "$(cat "$r/sub/f.txt" 2>/dev/null)" = x ] && echo 0 || echo 1)"
check 'executable bit survives' "$([ -x "$r/tool" ] && echo 0 || echo 1)"
check 'symlink survives' "$([ -L "$r/link" ] && [ "$(cat "$r/link")" = x ] && echo 0 || echo 1)"
check 'dot files are kept' "$([ -f "$r/.hidden" ] && echo 0 || echo 1)"
r="$(lib "$H" "extract_package '$Z/two.zip' '$Z/st2'")"
check 'several top-level entries are kept as they are' "$( ([ "$r" = "$Z/st2" ] && [ -f "$r/b" ] && [ -f "$r/a/f" ]) && echo 0 || echo 1)" "($r)"
r="$(lib "$H" "extract_package '$Z/mac.zip' '$Z/st3'")"
check '__MACOSX does not count as a root folder (unzip fallback)' "$( ([ "$r" = "$Z/st3/Tool-2.0.0" ] && [ ! -e "$Z/st3/__MACOSX" ]) && echo 0 || echo 1)" "($r)"
# Finder / ditto で作った zip（拡張属性を __MACOSX に退避したもの）
mkdir -p "$Z/src5/Tool-3.0.0"
printf 'e\n' >"$Z/src5/Tool-3.0.0/e"
xattr -w org.lee-lab.test 1 "$Z/src5/Tool-3.0.0/e"
ditto -c -k --sequesterRsrc --keepParent "$Z/src5/Tool-3.0.0" "$Z/ditto.zip"
check 'the ditto-made zip really has __MACOSX' "$(unzip -l "$Z/ditto.zip" | grep -q __MACOSX && echo 0 || echo 1)"
r="$(lib "$H" "extract_package '$Z/ditto.zip' '$Z/st5'")"
check 'a ditto-made zip with __MACOSX strips its root folder' "$( ([ "$r" = "$Z/st5/Tool-3.0.0" ] && [ -f "$r/e" ]) && echo 0 || echo 1)" "($r)"
printf 'not a zip' >"$Z/bad.zip"
out="$(lib "$H" "extract_package '$Z/bad.zip' '$Z/st4'" 2>&1)"; rc=$?
check 'a damaged zip fails with a message' "$( ([ "$rc" != 0 ] && contains "$out" 'could not be extracted') && echo 0 || echo 1)" "(rc=$rc)"

# ---------------------------------------------------------------------------
section 'preserve（更新時のユーザデータ引き継ぎ）'
# ---------------------------------------------------------------------------

P="$SANDBOX/preserve"
mkdir -p "$P/old/data/deep" "$P/new/data" "$P/outside"
printf 'user\n' >"$P/old/settings.json"
printf 'mine\n' >"$P/old/data/a.txt"
printf 'deep\n' >"$P/old/data/deep/d.txt"
printf 'default\n' >"$P/new/settings.json"
printf 'shipped\n' >"$P/new/data/b.txt"
printf 'secret\n' >"$P/outside/evil"
cat >"$P/m.json" <<'EOF'
{ "preserve": ["settings.json", "data/", "missing.txt", "../outside/evil", "/etc/hosts", ""] }
EOF
out="$(lib "$H" "carry_user_data '$P/old' '$P/new' '$P/m.json' preserve" 2>"$P/err")"; rc=$?
check 'carry_user_data succeeds' "$rc"
check 'carry_user_data counts 2 items' "$([ "$out" = 2 ] && echo 0 || echo 1)" "($out)"
check "user's settings.json wins" "$([ "$(cat "$P/new/settings.json")" = user ] && echo 0 || echo 1)"
check 'folders are merged (user file kept)' "$([ "$(cat "$P/new/data/a.txt" 2>/dev/null)" = mine ] && echo 0 || echo 1)"
check 'folders are merged (nested user file kept)' "$([ "$(cat "$P/new/data/deep/d.txt" 2>/dev/null)" = deep ] && echo 0 || echo 1)"
check 'folders are merged (shipped file kept)' "$([ "$(cat "$P/new/data/b.txt" 2>/dev/null)" = shipped ] && echo 0 || echo 1)"
n="$(grep -c 'Ignoring a preserve entry' "$P/err" || true)"
check 'unsafe preserve entries (.., absolute, empty) are ignored' "$([ "$n" = 3 ] && echo 0 || echo 1)" "($n)"
check 'nothing was written outside the new app' "$( ([ ! -e "$P/new/etc" ] && [ ! -e "$P/new/hosts" ] && [ "$(ls "$P/outside")" = evil ]) && echo 0 || echo 1)"
check 'the old app is left untouched' "$([ "$(cat "$P/old/settings.json")" = user ] && [ -f "$P/old/data/a.txt" ] && echo 0 || echo 1)"
out="$(lib "$H" "carry_user_data '$P/nothing' '$P/new' '$P/m.json' preserve")"
check 'first install (no old app) carries nothing' "$([ "$out" = 0 ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
section 'safe_rm_rf（削除してよい場所の制限）'
# ---------------------------------------------------------------------------

S="$SANDBOX/rm-home"
mkdir -p "$S/Library/Application Support/LeeLab/t/app" "$S/Applications/T.app" "$S/keep"
lib "$S" 'safe_rm_rf ""' 2>/dev/null; rc=$?
check 'refuses an empty path' "$([ "$rc" != 0 ] && echo 0 || echo 1)"
lib "$S" 'safe_rm_rf "$HOME/keep"' 2>/dev/null; rc=$?
check 'refuses a folder outside LeeLab' "$( ([ "$rc" != 0 ] && [ -d "$S/keep" ]) && echo 0 || echo 1)"
lib "$S" 'safe_rm_rf "$INSTALL_ROOT"' 2>/dev/null; rc=$?
check 'refuses the LeeLab folder itself' "$( ([ "$rc" != 0 ] && [ -d "$S/Library/Application Support/LeeLab" ]) && echo 0 || echo 1)"
lib "$S" 'safe_rm_rf "$INSTALL_ROOT/t/../../../../keep"' 2>/dev/null; rc=$?
check 'refuses a path with ..' "$( ([ "$rc" != 0 ] && [ -d "$S/keep" ]) && echo 0 || echo 1)"
lib "$S" 'safe_rm_rf "$APPS_DIR"' 2>/dev/null; rc=$?
check 'refuses ~/Applications itself' "$( ([ "$rc" != 0 ] && [ -d "$S/Applications" ]) && echo 0 || echo 1)"
check_cmd 'removes a folder under LeeLab' lib "$S" 'safe_rm_rf "$INSTALL_ROOT/t/app"'
check 'it is gone' "$([ ! -e "$S/Library/Application Support/LeeLab/t/app" ] && echo 0 || echo 1)"
check_cmd 'removes a launcher in ~/Applications' lib "$S" 'safe_rm_rf "$APPS_DIR/T.app"'

# ---------------------------------------------------------------------------
section '環境チェック'
# ---------------------------------------------------------------------------

check_cmd 'check_environment passes on this Mac' lib "$H" 'check_environment'
out="$(lib "$H" 'get_hw_arm64() { echo 0; }; check_environment' 2>&1)"; rc=$?
check 'Intel (hw.optional.arm64 = 0) is refused' "$( ([ "$rc" = 1 ] && contains "$out" 'Apple Silicon') && echo 0 || echo 1)"
out="$(lib "$H" 'get_hw_arm64() { echo ""; }; check_environment' 2>&1)"; rc=$?
check 'missing hw.optional.arm64 is refused' "$([ "$rc" = 1 ] && echo 0 || echo 1)"
out="$(lib "$H" 'get_os_name() { echo Linux; }; check_environment' 2>&1)"; rc=$?
check 'non-macOS is refused' "$( ([ "$rc" = 1 ] && contains "$out" 'for macOS') && echo 0 || echo 1)"
out="$(lib "$H" 'get_macos_version() { echo 11.7.10; }; check_environment' 2>&1)"; rc=$?
check 'macOS 11 is refused by the installer itself' "$( ([ "$rc" = 1 ] && contains "$out" 'macOS 12 or later') && echo 0 || echo 1)"
out="$(lib "$H" 'get_macos_version() { echo 14.6.1; }; check_min_macos 15 Demo' 2>&1)"; rc=$?
check 'min_macos 15 refuses macOS 14.6.1' "$( ([ "$rc" = 1 ] && contains "$out" 'Demo needs macOS 15 or later') && echo 0 || echo 1)"
check_cmd 'min_macos 15 accepts macOS 15.0' lib "$H" 'get_macos_version() { echo 15.0; }; check_min_macos 15 Demo'
check_cmd 'min_macos 15 accepts macOS 26.1' lib "$H" 'get_macos_version() { echo 26.1; }; check_min_macos 15 Demo'
check_cmd 'empty min_macos is not checked' lib "$H" 'get_macos_version() { echo 13.0; }; check_min_macos "" Demo'

# ---------------------------------------------------------------------------
section 'ランチャー (.app) の生成'
# ---------------------------------------------------------------------------

L="$SANDBOX/launch-home"
mkdir -p "$L/Library/Application Support/LeeLab/demo/app"
LAPP="$L/Library/Application Support/LeeLab/demo/app"
cat >"$LAPP/demo-bin" <<'EOF'
#!/bin/sh
printf 'cwd=%s\n' "$(pwd)"
printf 'args=%s\n' "$*"
EOF
chmod 755 "$LAPP/demo-bin"
lib "$L" "PKG_WORK=\$(mktemp -d \"\$INSTALL_ROOT/demo/.install.XXXXXX\"); create_launcher \"\$APPS_DIR/Demo Tool.app\" 'Demo Tool' demo 1.2.3 15 demo-bin '$LAPP'"; rc=$?
B="$L/Applications/Demo Tool.app"
check 'create_launcher succeeds (creates ~/Applications)' "$( ([ "$rc" = 0 ] && [ -d "$B" ]) && echo 0 || echo 1)" "(rc=$rc)"
pv() { plutil -extract "$1" raw -o - "$B/Contents/Info.plist" 2>/dev/null; }
check 'Info.plist CFBundleIdentifier' "$([ "$(pv CFBundleIdentifier)" = org.lee-lab.tools.demo ] && echo 0 || echo 1)"
check 'Info.plist CFBundleName / DisplayName' "$([ "$(pv CFBundleName)" = 'Demo Tool' ] && [ "$(pv CFBundleDisplayName)" = 'Demo Tool' ] && echo 0 || echo 1)"
check 'Info.plist CFBundleExecutable' "$([ "$(pv CFBundleExecutable)" = demo-bin ] && echo 0 || echo 1)"
check 'Info.plist CFBundleVersion' "$([ "$(pv CFBundleVersion)" = 1.2.3 ] && echo 0 || echo 1)"
check 'Info.plist LSMinimumSystemVersion' "$([ "$(pv LSMinimumSystemVersion)" = 15 ] && echo 0 || echo 1)"
check 'Info.plist NSHighResolutionCapable' "$([ "$(pv NSHighResolutionCapable)" = true ] && echo 0 || echo 1)"
check_cmd 'Info.plist is valid' plutil -lint "$B/Contents/Info.plist"
check_cmd 'the bundle is signed (codesign --verify)' codesign --verify --deep "$B"
check 'no quarantine attribute on the bundle' "$( ! xattr -r "$B" 2>/dev/null | grep -q com.apple.quarantine && echo 0 || echo 1)"
out="$("$B/Contents/MacOS/demo-bin" one -psn_0_12345 'two words' 2>&1)"
check 'launcher starts the tool in the app folder' "$(contains "$out" "cwd=$LAPP" && echo 0 || echo 1)" "($out)"
check 'launcher passes arguments and drops -psn_' "$(contains "$out" 'args=one two words' && echo 0 || echo 1)" "($out)"
check_cmd 'launcher_is_ours (our bundle)' lib "$L" "launcher_is_ours '$B' demo"
mkdir -p "$L/Applications/Other.app/Contents"
cp "$B/Contents/Info.plist" "$L/Applications/Other.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.example.other "$L/Applications/Other.app/Contents/Info.plist"
lib "$L" "launcher_is_ours '$L/Applications/Other.app' demo"; rc=$?
check 'launcher_is_ours refuses a foreign app' "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check_cmd 'launcher_is_ours accepts a missing bundle' lib "$L" "launcher_is_ours '$L/Applications/None.app' demo"
check 'launcher_name replaces / and :' "$([ "$(lib "$L" "launcher_name 'A/B:C'")" = 'A-B-C' ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
section 'VS Code CLI の検出'
# ---------------------------------------------------------------------------

STUB="$SANDBOX/stub-bin"
mkdir -p "$STUB"
cat >"$STUB/code" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/code.log"
exit 0
EOF
chmod 755 "$STUB/code"
r="$(PATH="$STUB:$PATH" lib "$H" 'find_code_cli')"
check 'find_code_cli prefers PATH' "$([ "$r" = "$STUB/code" ] && echo 0 || echo 1)" "($r)"

# ---------------------------------------------------------------------------
section '通しの流れ（インストール → 更新 → チャネル切り替え → アンインストール）'
# ---------------------------------------------------------------------------

E="$SANDBOX/e2e"
EH="$E/home"
DIST="$E/dist"
mkdir -p "$EH/MMDAgent-Contents" "$DIST/tools" "$DIST/pkg"
printf 'user content\n' >"$EH/MMDAgent-Contents/keep.txt"
E2E_ITER=1000

# make_package VERSION [MISSING_EXE]: zip -> 暗号化。sha256 は復号後の zip のもの。
make_package() {
    local v="$1" root="$E/build/Demo-Tool-$1"
    rm -rf "$E/build"
    mkdir -p "$root/extensions"
    if [ "${2:-}" != missing-exe ]; then
        cat >"$root/demo-bin" <<EOF
#!/bin/sh
printf 'demo $v cwd=%s args=%s\n' "\$(pwd)" "\$*"
EOF
        chmod 755 "$root/demo-bin"
    fi
    printf 'default settings %s\n' "$v" >"$root/settings.json"
    printf 'vsix\n' >"$root/extensions/demo.vsix"
    printf '%s\n' "$v" >"$root/only-$v.txt"
    (cd "$E/build" && zip -qry "$DIST/pkg/Demo-Tool-$v-macos-arm64.zip" "Demo-Tool-$v")
    PKG_SHA="$(shasum -a 256 "$DIST/pkg/Demo-Tool-$v-macos-arm64.zip" | awk '{print $1}')"
    /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -iter "$E2E_ITER" -md sha256 -salt \
        -in "$DIST/pkg/Demo-Tool-$v-macos-arm64.zip" \
        -out "$DIST/pkg/Demo-Tool-$v-macos-arm64.zip.enc" -pass "pass:$FIXTURE_PASSWORD"
}

# write_manifest FILE VERSION SHA [ENCRYPTED]
write_manifest() {
    local f="$1" v="$2" sha="$3" encrypted="${4:-true}" url
    url="file://$DIST/pkg/Demo-Tool-$v-macos-arm64.zip"
    if [ "$encrypted" = true ]; then url="$url.enc"; fi
    cat >"$f" <<EOF
{
  "schema": 1,
  "name": "demo-tool",
  "display_name": "Demo Tool",
  "description": "A synthetic tool for the installer tests",
  "kind": "native",
  "version": "$v",
  "package": { "url": "https://example.invalid/windows.zip.enc", "sha256": "00", "encrypted": true, "kdf_iterations": 200000 },
  "exe": "Demo.exe",
  "platforms": {
    "macos-arm64": {
      "package": { "url": "$url", "sha256": "$sha", "encrypted": $encrypted, "kdf_iterations": $E2E_ITER },
      "exe": "demo-bin",
      "min_macos": "15"
    }
  },
  "vscode_extensions": [ { "file": "extensions/demo.vsix", "id": "lee-lab.demo" } ],
  "preserve": ["settings.json", "cache"],
  "notes": ["About 1 MB of free disk space is needed.", "On Windows, this note must not be shown on macOS."]
}
EOF
}

cat >"$DIST/tools/index.json" <<'EOF'
{
  "schema": 1,
  "tools": [
    { "name": "winonly", "display_name": "Windows Only", "description": "No macOS build", "manifest": "tools/winonly.json" },
    { "name": "demo-tool", "display_name": "Demo Tool", "description": "Synthetic", "manifest": "tools/demo-tool.json" }
  ]
}
EOF
cat >"$DIST/tools/winonly.json" <<'EOF'
{ "schema": 1, "name": "winonly", "display_name": "Windows Only", "kind": "native", "version": "9.9.9",
  "package": { "url": "https://example.invalid/w.zip", "sha256": "00" }, "exe": "W.exe" }
EOF

run_installer() {
    # $1 = pipe | file。残りは env に渡す変数。
    local mode="$1"
    shift
    if [ "$mode" = pipe ]; then
        cat "$INSTALLER" | env HOME="$EH" PATH="$STUB:$PATH" LEELAB_BASE_URL="file://$DIST" "$@" bash
    else
        env HOME="$EH" PATH="$STUB:$PATH" LEELAB_BASE_URL="file://$DIST" "$@" bash "$INSTALLER"
    fi
}

TOOL_ROOT="$EH/Library/Application Support/LeeLab/demo-tool"
APP="$TOOL_ROOT/app"
BUNDLE="$EH/Applications/Demo Tool.app"
st() { plutil -extract "$1" raw -o - "$TOOL_ROOT/install.json" 2>/dev/null; }

# 1. 新規インストール（curl | bash の経路、メニュー無し: macOS 版があるのは 1 つだけ）
make_package 1.0.0
write_manifest "$DIST/tools/demo-tool.json" 1.0.0 "$PKG_SHA"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_PASSWORD="$FIXTURE_PASSWORD" 2>&1)"; rc=$?
check 'install: exit 0' "$rc" "$out"
check 'install: the only macOS tool is picked without a menu' "$( (contains "$out" 'Installing Demo Tool 1.0.0' && ! contains "$out" 'Select the tool') && echo 0 || echo 1)"
check 'install: notes are shown, Windows notes are not' "$( (contains "$out" 'About 1 MB of free disk space' && ! contains "$out" 'must not be shown') && echo 0 || echo 1)"
check 'install: app extracted with the root folder stripped' "$( ([ -x "$APP/demo-bin" ] && [ -f "$APP/only-1.0.0.txt" ]) && echo 0 || echo 1)"
check 'install: install.json records version and channel' "$( ([ "$(st version)" = 1.0.0 ] && [ "$(st channel)" = beta ] && [ "$(st name)" = demo-tool ]) && echo 0 || echo 1)"
check 'install: install.json records the launcher' "$([ "$(st app_bundle)" = "$BUNDLE" ] && echo 0 || echo 1)"
check 'install: installed_at is set' "$([ -n "$(st installed_at)" ] && echo 0 || echo 1)"
check 'install: launcher created' "$([ -x "$BUNDLE/Contents/MacOS/demo-bin" ] && echo 0 || echo 1)"
out2="$("$BUNDLE/Contents/MacOS/demo-bin" hello 2>&1)"
check 'install: launcher runs the tool from app/' "$(contains "$out2" "demo 1.0.0 cwd=$APP args=hello" && echo 0 || echo 1)" "($out2)"
check 'install: uninstall.sh is executable' "$([ -x "$TOOL_ROOT/uninstall.sh" ] && echo 0 || echo 1)"
check_cmd 'install: uninstall.sh parses' bash -n "$TOOL_ROOT/uninstall.sh"
check 'install: VS Code extension installed through the code CLI' "$(grep -q -- "--install-extension $APP/extensions/demo.vsix --force" "$EH/code.log" 2>/dev/null && echo 0 || echo 1)"
check 'install: no work folder left behind' "$([ -z "$(ls -A "$TOOL_ROOT" | grep '^\.install\.' || true)" ] && echo 0 || echo 1)"
check 'install: no quarantine attribute in app/' "$( ! xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine && echo 0 || echo 1)"

# 利用者のデータ（preserve 対象）を作る
printf 'user settings\n' >"$APP/settings.json"
mkdir -p "$APP/cache"
printf 'cached\n' >"$APP/cache/c.bin"

# 端末から答える経路。expect(1)（macOS に標準で入っている）で疑似端末を用意し、
# curl | bash と同じくスクリプト本体はパイプで渡す。質問とパスワードが stdin
# （= スクリプト）ではなく /dev/tty から読まれていることの確認になる。
# プロンプトが出るのを待ち、さらに 0.3 秒置いてから答える。bash 3.2 の read -s
# はプロンプトを出してから端末をエコー無しに切り替え、そのとき先打ちの入力を
# 捨てる（TCSAFLUSH）ので、プロンプト直後に即答すると取りこぼして固まる。人の
# 入力では起きない競合で、パスワードの先打ちが捨てられるのはむしろ安全側。
# run_tty BASE_URL 'w "<prompt>"; send "<answer>\r"; ...' VAR=VALUE...
run_tty() {
    local base="$1" body="$2"
    shift 2
    env HOME="$EH" PATH="$STUB:$PATH" LEELAB_BASE_URL="$base" T_INSTALLER="$INSTALLER" \
        T_PASSWORD="$FIXTURE_PASSWORD" "$@" expect -c "
set timeout 60
proc w {p} {
    expect {
        -exact \$p { after 300 }
        timeout { puts \"\nTIMEOUT waiting for: \$p\"; exit 98 }
        eof { puts \"\nEOF waiting for: \$p\"; exit 97 }
    }
}
spawn bash -c {cat \"\$T_INSTALLER\" | bash}
$body
expect eof
catch wait result
exit [lindex \$result 3]
"
}

# 2a. 更新の確認に n と答える: 何も変わらない
make_package 1.1.0
write_manifest "$DIST/tools/demo-tool.json" 1.1.0 "$PKG_SHA"
out="$(run_tty "file://$DIST" 'w "(Y/n)"; send "n\r"' LEELAB_PASSWORD="$FIXTURE_PASSWORD" 2>&1)"; rc=$?
check 'tty: the update question is asked' "$(contains "$out" 'Reinstall / update now? (Y/n)' && echo 0 || echo 1)" "$out"
check 'tty: answering n cancels with exit 0' "$( ([ "$rc" = 0 ] && contains "$out" 'Cancelled.') && echo 0 || echo 1)" "(rc=$rc)"
check 'tty: nothing changed after n' "$( ([ "$(st version)" = 1.0.0 ] && [ "$(cat "$APP/settings.json")" = 'user settings' ]) && echo 0 || echo 1)"

# 2. 更新（ファイルとして実行する経路）
out="$(run_installer file LEELAB_YES=1 LEELAB_PASSWORD="$FIXTURE_PASSWORD" LEELAB_TOOL=demo-tool 2>&1)"; rc=$?
check 'update: exit 0' "$rc" "$out"
check 'update: reports the installed version' "$(contains "$out" 'already installed (version 1.0.0, beta channel)' && echo 0 || echo 1)"
check 'update: announces the newer version' "$(contains "$out" 'A newer version, 1.1.0, is available' && echo 0 || echo 1)"
check 'update: install.json says 1.1.0' "$([ "$(st version)" = 1.1.0 ] && echo 0 || echo 1)"
check 'update: new files are in place' "$([ -f "$APP/only-1.1.0.txt" ] && echo 0 || echo 1)"
check 'update: files of the old version are gone' "$([ ! -e "$APP/only-1.0.0.txt" ] && echo 0 || echo 1)"
check 'update: preserved file kept' "$([ "$(cat "$APP/settings.json")" = 'user settings' ] && echo 0 || echo 1)"
check 'update: preserved folder kept' "$([ "$(cat "$APP/cache/c.bin" 2>/dev/null)" = cached ] && echo 0 || echo 1)"
check 'update: launcher points at the new version' "$(contains "$("$BUNDLE/Contents/MacOS/demo-bin")" 'demo 1.1.0' && echo 0 || echo 1)"
check 'update: launcher CFBundleVersion updated' "$([ "$(plutil -extract CFBundleVersion raw -o - "$BUNDLE/Contents/Info.plist")" = 1.1.0 ] && echo 0 || echo 1)"
check 'update: no work folder left behind' "$([ -z "$(ls -A "$TOOL_ROOT" | grep '^\.install\.' || true)" ] && echo 0 || echo 1)"

# 3. 同じ版をもう一度（再インストール）。パスワードは端末から入力し、1 回目は誤り。
out="$(run_tty "file://$DIST" 'w "Password: "; send "wrong-password\r"; w "Password: "; send "$env(T_PASSWORD)\r"' LEELAB_YES=1 2>&1)"; rc=$?
check 'reinstall: exit 0 and says it is the same version' "$( ([ "$rc" = 0 ] && contains "$out" 'same as the latest available version') && echo 0 || echo 1)" "$out"
check 'tty: a wrong password can be retried' "$(contains "$out" 'Incorrect password. Please try again. (2 attempt(s) left)' && echo 0 || echo 1)"
check 'tty: the second password is accepted' "$( (contains "$out" 'Password accepted' && [ "$(st version)" = 1.1.0 ]) && echo 0 || echo 1)"
check 'tty: the password is not echoed' "$( ! contains "$out" 'wrong-password' && ! contains "$out" "$FIXTURE_PASSWORD" && echo 0 || echo 1)"
check 'tty: preserved data kept on reinstall' "$([ "$(cat "$APP/settings.json")" = 'user settings' ] && echo 0 || echo 1)"

# 3b. macOS 版のあるツールが 2 つ以上ならメニューを出す
DIST2="$E/dist2"
mkdir -p "$DIST2/tools"
cp "$DIST/tools/demo-tool.json" "$DIST2/tools/demo-a.json"
cp "$DIST/tools/demo-tool.json" "$DIST2/tools/demo-b.json"
cat >"$DIST2/tools/index.json" <<'EOF'
{ "schema": 1, "tools": [
  { "name": "demo-a", "display_name": "Demo A", "description": "First", "manifest": "tools/demo-a.json" },
  { "name": "demo-b", "display_name": "Demo B", "description": "Second", "manifest": "tools/demo-b.json" } ] }
EOF
out="$(run_tty "file://$DIST2" 'w "or q to quit): "; send "5\r"; w "or q to quit): "; send "q\r"' 2>&1)"; rc=$?
check 'menu: shown for two macOS tools' "$( (contains "$out" 'Select the tool you want to install' && contains "$out" '[1] Demo A' && contains "$out" '[2] Demo B') && echo 0 || echo 1)" "$out"
check 'menu: an out-of-range number is rejected' "$(contains "$out" 'Please enter a number between 1 and 2.' && echo 0 || echo 1)"
check 'menu: q cancels with exit 0' "$( ([ "$rc" = 0 ] && contains "$out" 'Cancelled.') && echo 0 || echo 1)" "(rc=$rc)"
check 'menu: nothing installed for demo-a' "$([ ! -e "$EH/Library/Application Support/LeeLab/demo-a" ] && echo 0 || echo 1)"

# 4. 誤ったパスワード: インストール済みの版は壊れない
make_package 1.2.0
write_manifest "$DIST/tools/demo-tool-alpha.json" 1.2.0 "$PKG_SHA"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_PASSWORD=wrong LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'wrong password: exit 1' "$( ([ "$rc" = 1 ] && contains "$out" 'password was not correct') && echo 0 || echo 1)" "(rc=$rc)"
check 'wrong password: installed version untouched' "$( ([ "$(st version)" = 1.1.0 ] && [ -f "$APP/only-1.1.0.txt" ] && [ "$(cat "$APP/settings.json")" = 'user settings' ]) && echo 0 || echo 1)"
check 'wrong password: no work folder left behind' "$([ -z "$(ls -A "$TOOL_ROOT" | grep '^\.install\.' || true)" ] && echo 0 || echo 1)"

# 5. チャネル切り替え（beta -> alpha）
out="$(run_installer pipe LEELAB_YES=1 LEELAB_PASSWORD="$FIXTURE_PASSWORD" LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'switch: exit 0' "$rc" "$out"
check 'switch: asks about the channel switch' "$(contains "$out" 'Switch to the alpha channel now?' || contains "$out" 'You asked for the alpha channel' && echo 0 || echo 1)"
check 'switch: headline names the channel' "$(contains "$out" 'Installing Demo Tool 1.2.0 (alpha channel)' && echo 0 || echo 1)"
check 'switch: install.json says alpha 1.2.0' "$( ([ "$(st version)" = 1.2.0 ] && [ "$(st channel)" = alpha ]) && echo 0 || echo 1)"
check 'switch: preserved data kept' "$([ "$(cat "$APP/settings.json")" = 'user settings' ] && echo 0 || echo 1)"

# 6. 配布物に exe が無い: 失敗し、インストール済みの版は壊れない
make_package 1.3.0 missing-exe
write_manifest "$DIST/tools/demo-tool-alpha.json" 1.3.0 "$PKG_SHA"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_PASSWORD="$FIXTURE_PASSWORD" LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'missing exe: exit 1 with a message' "$( ([ "$rc" = 1 ] && contains "$out" 'demo-bin is missing from the package') && echo 0 || echo 1)" "(rc=$rc)"
check 'missing exe: installed version untouched' "$( ([ "$(st version)" = 1.2.0 ] && [ -x "$APP/demo-bin" ]) && echo 0 || echo 1)"

# 7. 暗号化なしの配布物（sha256 はダウンロードしたものに対して照合）
make_package 1.4.0
write_manifest "$DIST/tools/demo-tool-alpha.json" 1.4.0 "$PKG_SHA" false
out="$(run_installer pipe LEELAB_YES=1 LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'plain package: exit 0 without a password' "$( ([ "$rc" = 0 ] && ! contains "$out" 'password') && echo 0 || echo 1)" "(rc=$rc)"
check 'plain package: installed' "$([ "$(st version)" = 1.4.0 ] && echo 0 || echo 1)"
write_manifest "$DIST/tools/demo-tool-alpha.json" 1.4.0 "$(printf '1%.0s' $(seq 64))" false
out="$(run_installer pipe LEELAB_YES=1 LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'plain package: checksum mismatch fails' "$( ([ "$rc" = 1 ] && contains "$out" 'checksum mismatch') && echo 0 || echo 1)" "(rc=$rc)"

# 8. macOS 版の無いツール / 無い版: エラーではなく案内して 0 で終わる
out="$(run_installer pipe LEELAB_YES=1 LEELAB_TOOL=winonly 2>&1)"; rc=$?
check 'no macOS build: exit 0 with a message' "$( ([ "$rc" = 0 ] && contains "$out" 'Windows Only 9.9.9 does not have a macOS (Apple Silicon) version on the beta channel') && echo 0 || echo 1)" "(rc=$rc)"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_TOOL=winonly LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'no alpha manifest: exit 1 with the channel message' "$( ([ "$rc" = 1 ] && contains "$out" 'has not been released on the alpha channel yet') && echo 0 || echo 1)" "(rc=$rc)"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_TOOL=nosuch 2>&1)"; rc=$?
check 'unknown tool: exit 1 listing the tools' "$( ([ "$rc" = 1 ] && contains "$out" "no tool named 'nosuch'" && contains "$out" 'winonly, demo-tool') && echo 0 || echo 1)" "(rc=$rc)"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_CHANNEL=gamma 2>&1)"; rc=$?
check 'unknown channel: exit 1' "$( ([ "$rc" = 1 ] && contains "$out" "no release channel named 'gamma'") && echo 0 || echo 1)" "(rc=$rc)"

# 9. 外部の同名 .app は上書きしない
mv "$BUNDLE" "$E/our-bundle.app"
mkdir -p "$BUNDLE/Contents"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.someone</string></dict></plist>' >"$BUNDLE/Contents/Info.plist"
write_manifest "$DIST/tools/demo-tool-alpha.json" 1.4.0 "$(shasum -a 256 "$DIST/pkg/Demo-Tool-1.4.0-macos-arm64.zip" | awk '{print $1}')" false
out="$(run_installer pipe LEELAB_YES=1 LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'foreign .app: install still succeeds' "$rc" "$out"
check 'foreign .app: left alone' "$( ([ "$(plutil -extract CFBundleIdentifier raw -o - "$BUNDLE/Contents/Info.plist")" = com.example.someone ] && contains "$out" 'was not made by this installer') && echo 0 || echo 1)"
check 'foreign .app: not recorded for the uninstaller' "$([ -z "$(st app_bundle)" ] && echo 0 || echo 1)"
rm -rf "$BUNDLE"
mv "$E/our-bundle.app" "$BUNDLE"
out="$(run_installer pipe LEELAB_YES=1 LEELAB_CHANNEL=alpha 2>&1)"; rc=$?
check 'launcher re-created on the next run' "$( ([ "$rc" = 0 ] && [ "$(st app_bundle)" = "$BUNDLE" ]) && echo 0 || echo 1)"

# 10a. アンインストールの確認に n と答える: 何も消えない
out="$(env HOME="$EH" PATH="$STUB:$PATH" T_UNINSTALL="$TOOL_ROOT/uninstall.sh" expect -c '
set timeout 30
spawn $env(T_UNINSTALL)
expect {
    -exact "(y/N) " { after 300 }
    timeout { exit 98 }
}
send "n\r"
expect eof
catch wait result
exit [lindex $result 3]
' 2>&1)"; rc=$?
check 'uninstall: answering n keeps everything' "$( ([ "$rc" = 0 ] && contains "$out" 'Cancelled.' && [ -d "$APP" ] && [ -d "$BUNDLE" ]) && echo 0 || echo 1)" "(rc=$rc)"

# 10. アンインストール
: >"$EH/code.log"
out="$(HOME="$EH" PATH="$STUB:$PATH" "$TOOL_ROOT/uninstall.sh" --yes 2>&1)"; rc=$?
check 'uninstall: exit 0' "$rc" "$out"
check 'uninstall: tool folder removed' "$([ ! -e "$TOOL_ROOT" ] && echo 0 || echo 1)"
check 'uninstall: empty LeeLab folder removed' "$([ ! -e "$EH/Library/Application Support/LeeLab" ] && echo 0 || echo 1)"
check 'uninstall: launcher removed' "$([ ! -e "$BUNDLE" ] && echo 0 || echo 1)"
check 'uninstall: ~/Applications itself kept' "$([ -d "$EH/Applications" ] && echo 0 || echo 1)"
check 'uninstall: VS Code extension removed' "$(grep -q -- '--uninstall-extension lee-lab.demo' "$EH/code.log" && echo 0 || echo 1)"
check 'uninstall: ~/MMDAgent-Contents untouched' "$([ "$(cat "$EH/MMDAgent-Contents/keep.txt" 2>/dev/null)" = 'user content' ] && echo 0 || echo 1)"
check 'uninstall: Library/Application Support kept' "$([ -d "$EH/Library/Application Support" ] && echo 0 || echo 1)"

# 11. 生成された uninstall.sh は想定外の場所を消さない
mkdir -p "$E/fake/victim"
make_package 1.0.0
write_manifest "$DIST/tools/demo-tool.json" 1.0.0 "$PKG_SHA"
run_installer pipe LEELAB_YES=1 LEELAB_PASSWORD="$FIXTURE_PASSWORD" >/dev/null 2>&1
sed -e "s|^TOOL_ROOT=.*|TOOL_ROOT=$E/fake/victim|" "$TOOL_ROOT/uninstall.sh" >"$E/evil-uninstall.sh"
out="$(HOME="$EH" PATH="$STUB:$PATH" bash "$E/evil-uninstall.sh" --yes 2>&1)"; rc=$?
check 'uninstall.sh refuses a location outside LeeLab' "$( ([ "$rc" != 0 ] && [ -d "$E/fake/victim" ]) && echo 0 || echo 1)" "(rc=$rc)"
HOME="$EH" PATH="$STUB:$PATH" "$TOOL_ROOT/uninstall.sh" --yes >/dev/null 2>&1

# 実際の HOME に何も作っていないこと
check 'nothing was created in the real ~/Applications' "$([ ! -e "$HOME/Applications/Demo Tool.app" ] && echo 0 || echo 1)"
check 'nothing was created in the real LeeLab folder' "$([ ! -e "$HOME/Library/Application Support/LeeLab/demo-tool" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
exit 0
