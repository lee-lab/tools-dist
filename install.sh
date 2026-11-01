#!/bin/bash
#
# Lee Lab shared tool installer for macOS (Apple Silicon)
#
# Usage (for end users): open Terminal and paste the single line below.
#
#     curl -fsSL https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.sh | bash
#
# Settings go on the RIGHT of the pipe, so that they reach bash (put on the
# left, they would only reach curl):
#
#     ... | LEELAB_CHANNEL=alpha bash        install from the alpha channel
#     ... | LEELAB_TOOL=mmdagent-ex bash     install that tool without a menu
#     ... | LEELAB_YES=1 bash                do not ask for confirmation
#
#     LEELAB_PASSWORD   the package password (automation and tests only)
#     LEELAB_BASE_URL   base URL of the distribution repository (forks, tests)
#
# Administrator rights are not needed. Everything goes under
#     ~/Library/Application Support/LeeLab/<tool>/   the app, install.json, uninstall.sh
#     ~/Applications/<Display Name>.app              a small launcher
#
# This is the macOS counterpart of install.ps1 and follows the same rules:
# the same manifests (tools/<tool>.json = beta, tools/<tool>-alpha.json =
# alpha), the same OpenSSL-compatible encryption, the same SHA-256 check of
# the decrypted zip, the same single-root-folder stripping, the same
# "preserve" list on update. The macOS package of a tool is described in the
# manifest under platforms["macos-arm64"]; the Windows fields stay as they are.
#
# NOTE: keep this file pure ASCII with LF line endings, written for the bash
# 3.2 that ships with macOS (no associative arrays, no ${var,,}, no mapfile).
# Everything shown to users is English. tests/test-install.sh enforces the
# encoding and runs the whole flow against a temporary HOME.
#
# Why "curl | bash" and a zip rather than a .dmg: we have no Apple Developer
# ID, so the app is only ad-hoc signed and cannot be notarized. A browser
# download (a .dmg or a zip) carries the com.apple.quarantine attribute, and
# Gatekeeper then refuses to open an ad-hoc signed app; since macOS 15 the old
# "right-click > Open" bypass is gone too. Files fetched by curl carry no
# quarantine attribute, and the launcher .app is generated on this Mac, so
# neither is ever assessed by Gatekeeper and the app opens without a prompt.
#
# Why everything is inside functions and main runs on the last line: bash
# reads a piped script as it goes. A download that is cut off half way would
# otherwise run half a script; this way nothing runs unless the whole file
# arrived. It also keeps any command from reading the rest of the script as
# its input, which is why prompts read from /dev/tty, never from stdin.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_BASE_URL='https://raw.githubusercontent.com/lee-lab/tools-dist/main'
USER_AGENT='leelab-tools-dist-installer'

# Release channels. The default one keeps the plain manifest path
# (tools/<tool>.json), so a run with no channel installs beta.
DEFAULT_CHANNEL='beta'
KNOWN_CHANNELS='alpha beta'

# The manifest key of this platform: platforms["macos-arm64"].
PLATFORM_KEY='macos-arm64'
PLATFORM_LABEL='macOS (Apple Silicon)'

# "plutil -extract ... raw", which reads the manifests, appeared in macOS 12.
# Each tool states its own minimum (min_macos), which is usually higher.
INSTALLER_MIN_MACOS=12

DEFAULT_KDF_ITERATIONS=200000
PASSWORD_ATTEMPTS=3
BUNDLE_ID_PREFIX='org.lee-lab.tools'

# VS Code's command line launcher, when it is not on PATH.
VSCODE_APP_CLI_SUFFIX='Applications/Visual Studio Code.app/Contents/Resources/app/bin/code'

# Filled in by init_globals (and by the tests).
BASE_URL=''
CHANNEL=''
REQUESTED_TOOL=''
ASSUME_YES=0
INSTALL_ROOT=''
APPS_DIR=''
WORK_DIR=''
PKG_WORK=''
OPENSSL_BIN=''

# ---------------------------------------------------------------------------
# Console output helpers
# ---------------------------------------------------------------------------

C_HEAD=''
C_OK=''
C_WARN=''
C_ERR=''
C_DIM=''
C_RESET=''
if [ -t 1 ]; then
    C_HEAD=$'\033[36m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
fi

say() { printf '%s\n' "$*"; }
say_head() { printf '\n  %s%s%s\n\n' "$C_HEAD" "$*" "$C_RESET"; }
say_step() { printf '  %s-%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
say_ok() { printf '  %s*%s %s\n' "$C_OK" "$C_RESET" "$*"; }
say_dim() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
say_warn() { printf '  %s! %s%s\n' "$C_WARN" "$*" "$C_RESET" >&2; }

# Prints the message and stops. Messages go to stderr so that they are seen
# even when fail runs inside a $(...) capture.
fail() {
    printf '\n  %sError: %b%s\n\n' "$C_ERR" "$*" "$C_RESET" >&2
    printf '  %sIf this keeps happening, copy this screen and send it to the developer.%s\n\n' "$C_DIM" "$C_RESET" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_true() {
    case "$(to_lower "$(trim "${1:-}")")" in
        1|true|yes|y|on) return 0 ;;
    esac
    return 1
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# A relative path that stays inside its base folder: not empty, not absolute,
# no ".." component.
is_safe_relpath() {
    case "$1" in
        ''|/*|..|../*|*/..|*/../*) return 1 ;;
    esac
    return 0
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Deletes a path, but only one this installer owns: something under the
# LeeLab folder, a launcher in ~/Applications, or our own temporary folder.
# Anything else -- including an empty variable -- is refused.
safe_rm_rf() {
    local p="${1:-}"
    local ok=0
    if [ -z "$p" ]; then
        return 1
    fi
    case "/$p/" in
        */../*|*/./*) return 1 ;;
    esac
    if [ -n "$INSTALL_ROOT" ]; then
        case "$p" in "$INSTALL_ROOT"/?*) ok=1 ;; esac
    fi
    if [ -n "$APPS_DIR" ]; then
        case "$p" in "$APPS_DIR"/?*.app) ok=1 ;; esac
    fi
    if [ -n "$WORK_DIR" ]; then
        case "$p" in "$WORK_DIR"|"$WORK_DIR"/?*) ok=1 ;; esac
    fi
    if [ "$ok" -ne 1 ]; then
        say_warn "Refusing to delete $p (outside the installer's folders)."
        return 1
    fi
    rm -rf -- "$p"
}

# ---------------------------------------------------------------------------
# Reading answers from the user
#
# Under "curl | bash" the script itself is stdin, so every answer is read
# from /dev/tty. When there is no terminal at all, say how to run unattended.
# ---------------------------------------------------------------------------

have_tty() { { : </dev/tty; } 2>/dev/null; }

# ask PROMPT -> sets ANSWER. End of input counts as cancelling.
ANSWER=''
ask() {
    ANSWER=''
    if ! have_tty; then
        fail "This installer needs to ask a question, but no terminal is available.\n         Run it from Terminal, or add LEELAB_YES=1 (and LEELAB_TOOL=<name>) to run without questions."
    fi
    printf '%s' "$1"
    if ! IFS= read -r ANSWER </dev/tty; then
        printf '\n\n  Cancelled.\n\n'
        exit 0
    fi
}

# confirm PROMPT: yes unless the answer is n / N. LEELAB_YES skips it.
confirm_or_exit() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    say ''
    ask "$1 "
    case "$ANSWER" in
        n|N|no|No|NO)
            printf '\n  Cancelled.\n\n'
            exit 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Manifest (JSON) access
#
# plutil, which ships with every macOS, reads JSON and extracts a value by key
# path: "plutil -extract package.url raw". python3 is not used because on a
# fresh Mac the /usr/bin/python3 stub opens the "install the command line
# developer tools" dialog instead of running. A key path is split at dots and
# a number indexes an array (vscode_extensions.0.file); a key containing a
# dot cannot be addressed, so manifests must not use one.
# ---------------------------------------------------------------------------

# Type of the value at KEYPATH (string, integer, bool, array, dictionary...),
# or nothing when it is missing.
json_type() {
    plutil -type "$2" "$1" 2>/dev/null || true
}

json_has() {
    [ -n "$(json_type "$1" "$2")" ]
}

# json_get FILE KEYPATH [DEFAULT]: a string, number or boolean ("true" /
# "false"). Missing values, null and containers give DEFAULT.
json_get() {
    local t v
    t="$(json_type "$1" "$2")"
    case "$t" in
        string|integer|float|bool) ;;
        *) printf '%s\n' "${3-}"; return 0 ;;
    esac
    if v="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)"; then
        printf '%s\n' "$v"
    else
        printf '%s\n' "${3-}"
    fi
}

# Number of elements of the array at KEYPATH (0 when missing / not an array).
json_count() {
    if [ "$(json_type "$1" "$2")" != 'array' ]; then
        printf '0\n'
        return 0
    fi
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || printf '0\n'
}

# A field that the platform block may override: platforms.macos-arm64.NAME
# when it is there, otherwise the top-level NAME.
platform_key() {
    local pk="platforms.$PLATFORM_KEY.$2"
    if json_has "$1" "$pk"; then
        printf '%s\n' "$pk"
    else
        printf '%s\n' "$2"
    fi
}

# ---------------------------------------------------------------------------
# Release channels
# ---------------------------------------------------------------------------

# Turns whatever the user gave us into a known channel name. An empty value
# means the default channel, so a plain one-liner keeps installing beta.
resolve_channel() {
    local v c
    v="$(to_lower "$(trim "${1:-}")")"
    if [ -z "$v" ]; then
        printf '%s\n' "$DEFAULT_CHANNEL"
        return 0
    fi
    for c in $KNOWN_CHANNELS; do
        if [ "$c" = "$v" ]; then
            printf '%s\n' "$v"
            return 0
        fi
    done
    fail "There is no release channel named '$1'. Available channels: ${KNOWN_CHANNELS// /, }"
}

# Where a channel keeps its manifest. The default channel uses the path as it
# stands (tools/valles.json); any other channel has its name inserted before
# the extension (tools/valles-alpha.json). Same rule as Get-ManifestPath.
manifest_path() {
    local path="$1" channel="${2:-}" file
    if [ -z "$channel" ] || [ "$channel" = "$DEFAULT_CHANNEL" ]; then
        printf '%s\n' "$path"
        return 0
    fi
    file="${path##*/}"
    # Only an extension on the file name itself counts, not a dot in a folder.
    case "$file" in
        *.*) printf '%s\n' "${path%.*}-$channel.${path##*.}" ;;
        *) printf '%s\n' "$path-$channel" ;;
    esac
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

# Separate functions so that the tests can stand in for other machines.
get_os_name() { uname -s; }
# uname -m says x86_64 in a Terminal running under Rosetta, so ask the
# hardware instead: the key exists (= 1) only on Apple Silicon.
get_hw_arm64() { sysctl -n hw.optional.arm64 2>/dev/null || printf '0\n'; }
get_macos_version() { sw_vers -productVersion 2>/dev/null || printf '0\n'; }

macos_major() {
    local v
    v="$(get_macos_version)"
    v="${v%%.*}"
    if is_uint "$v"; then printf '%s\n' "$v"; else printf '0\n'; fi
}

check_environment() {
    local cmd major
    if [ "$(get_os_name)" != 'Darwin' ]; then
        fail "This installer is for macOS. On Windows, please use the PowerShell command in the installation guide."
    fi
    if [ "$(trim "$(get_hw_arm64)")" != '1' ]; then
        fail "A Mac with Apple Silicon (M1 or later) is required. Intel Macs are not supported."
    fi
    major="$(macos_major)"
    if [ "$major" -lt "$INSTALLER_MIN_MACOS" ]; then
        fail "macOS $INSTALLER_MIN_MACOS or later is required (this Mac has macOS $(get_macos_version)).\n         Please update macOS in System Settings > General > Software Update."
    fi
    for cmd in curl shasum plutil ditto unzip codesign xattr awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "A standard macOS command is missing: $cmd"
        fi
    done
    if [ -x /usr/bin/openssl ]; then
        OPENSSL_BIN=/usr/bin/openssl
    elif command -v openssl >/dev/null 2>&1; then
        OPENSSL_BIN="$(command -v openssl)"
    else
        fail "A standard macOS command is missing: openssl"
    fi
    # plutil reads the manifests; make sure this one can.
    if [ "$(printf '{"k":"v"}' | plutil -extract k raw -o - - 2>/dev/null)" != 'v' ]; then
        fail "This version of macOS cannot read the distribution info (plutil). Please update macOS."
    fi
}

# Refuses when this Mac is older than the tool's min_macos (a major version).
check_min_macos() {
    local min="$1" display="$2" major
    min="${min%%.*}"
    if ! is_uint "$min"; then
        return 0
    fi
    major="$(macos_major)"
    if [ "$major" -lt "$min" ]; then
        fail "$display needs macOS $min or later (this Mac has macOS $(get_macos_version)).\n         Please update macOS in System Settings > General > Software Update."
    fi
}

# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

# fetch_file URL DEST: 0 = fetched, 2 = not there (HTTP 404 or a missing
# file:// path, which the tests use), 1 = anything else (network, server).
fetch_file() {
    local url="$1" dest="$2" code rc=0
    code="$(curl -sS -L --retry 2 --connect-timeout 20 -A "$USER_AGENT" \
        -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 37 ]; then
        return 2
    fi
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    case "$code" in
        2??|000) return 0 ;;
        404) return 2 ;;
    esac
    return 1
}

# fetch_json URL DEST [NOT_FOUND_MESSAGE]: fetches and checks it is JSON.
fetch_json() {
    local url="$1" dest="$2" notfound="${3:-}" rc=0
    fetch_file "$url" "$dest" || rc=$?
    if [ "$rc" -eq 2 ] && [ -n "$notfound" ]; then
        fail "$notfound"
    fi
    if [ "$rc" -ne 0 ]; then
        fail "Could not fetch the distribution info: $url\n         Please check your internet connection."
    fi
    # (plutil -lint does not accept JSON; a conversion does.)
    if ! plutil -convert json -o /dev/null "$dest" >/dev/null 2>&1; then
        fail "The distribution info is malformed: $url"
    fi
}

# Downloads a package with a progress bar (when there is a terminal).
download_package() {
    local url="$1" dest="$2" progress='-sS'
    if [ -t 2 ]; then
        progress='--progress-bar'
    fi
    if ! curl -f -L --retry 3 --connect-timeout 20 -A "$USER_AGENT" "$progress" \
        -o "$dest" "$url" </dev/null; then
        rm -f -- "$dest"
        fail "Download failed: $url\n         Please check your internet connection and run the command again."
    fi
}

# True when FILE has the SHA-256 EXPECTED. An empty EXPECTED is not checked.
sha256_matches() {
    local expected
    expected="$(to_lower "$(trim "${2:-}")")"
    if [ -z "$expected" ]; then
        return 0
    fi
    [ "$(sha256_of "$1")" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Decrypting the package
#
# Tools that have not been released publicly are stored encrypted, in the
# format of OpenSSL's `enc -aes-256-cbc -pbkdf2 -iter N -md sha256 -salt`:
#     "Salted__" (8 bytes) + salt (8 bytes) + ciphertext
# The macOS openssl (LibreSSL) reads that format directly. CI encrypts with
# OpenSSL and install.ps1 decrypts with .NET, so tests/fixtures/sample.enc
# checks that all three agree.
# ---------------------------------------------------------------------------

# decrypt_file IN OUT PASSWORD ITERATIONS: 0 on success. The password reaches
# openssl through its environment, never on a command line others can see.
decrypt_file() {
    local in="$1" out="$2" pw="$3" iter="$4" magic
    magic="$(head -c 8 "$in" 2>/dev/null || true)"
    if [ "$magic" != 'Salted__' ]; then
        return 1
    fi
    if LEELAB_DECRYPT_PASS="$pw" "$OPENSSL_BIN" enc -d -aes-256-cbc -pbkdf2 \
        -iter "$iter" -md sha256 -in "$in" -out "$out" \
        -pass env:LEELAB_DECRYPT_PASS </dev/null >/dev/null 2>&1; then
        return 0
    fi
    rm -f -- "$out"
    return 1
}

# Sets PASSWORD.
PASSWORD=''
read_password() {
    PASSWORD=''
    # Escape hatch for automation and testing. Real users type it in.
    if [ -n "${LEELAB_PASSWORD:-}" ]; then
        PASSWORD="$LEELAB_PASSWORD"
        return 0
    fi
    if ! have_tty; then
        fail "The password cannot be asked for because no terminal is available.\n         Please run the command in Terminal."
    fi
    # -s keeps the typed password off the screen; read restores the
    # terminal itself, also on Ctrl-C.
    if ! IFS= read -r -s -p '  Password: ' PASSWORD </dev/tty; then
        printf '\n\n  Cancelled.\n\n'
        exit 0
    fi
    printf '\n'
}

# unlock_package ENC ZIP SHA256 ITERATIONS DISPLAY_NAME
unlock_package() {
    local enc="$1" zip="$2" sha="$3" iter="$4" display="$5" attempt=1 ok
    say ''
    say "  $display has not been released publicly yet."
    say '  Please enter the password you received from the developer.'
    say_dim '(Nothing appears on screen while you type. This is normal.)'
    say ''
    while [ "$attempt" -le "$PASSWORD_ATTEMPTS" ]; do
        read_password
        ok=0
        # A wrong password normally fails the padding check, but it can
        # occasionally produce garbage instead. Confirm with the hash.
        if decrypt_file "$enc" "$zip" "$PASSWORD" "$iter" && sha256_matches "$zip" "$sha"; then
            ok=1
        fi
        PASSWORD=''
        if [ "$ok" -eq 1 ]; then
            say_ok 'Password accepted'
            return 0
        fi
        rm -f -- "$zip"
        if [ "$attempt" -lt "$PASSWORD_ATTEMPTS" ]; then
            say_warn "Incorrect password. Please try again. ($((PASSWORD_ATTEMPTS - attempt)) attempt(s) left)"
            if [ -n "${LEELAB_PASSWORD:-}" ]; then
                # A wrong value passed via the environment will not change on retry.
                break
            fi
        fi
        attempt=$((attempt + 1))
    done
    fail "Installation cancelled because the password was not correct.\n         If you do not know the password, please contact the developer."
}

# ---------------------------------------------------------------------------
# Extraction (strips a single root folder inside the zip)
# ---------------------------------------------------------------------------

# extract_package ZIP STAGE -> prints the folder that holds the app: the one
# root folder of the zip when there is exactly one, otherwise STAGE itself.
# Same rule as install.ps1. A __MACOSX folder (resource forks written by
# some zip tools) is not counted.
extract_package() {
    local zip="$1" stage="$2" e count=0 only=''
    mkdir -p -- "$stage"
    # ditto is the macOS archiver; unzip is the fallback for an archive that
    # ditto refuses (a malformed __MACOSX resource fork, for instance).
    if ! ditto -x -k "$zip" "$stage" </dev/null >/dev/null 2>&1; then
        rm -rf -- "${stage:?}"
        mkdir -p -- "$stage"
        if ! unzip -q -o "$zip" -d "$stage" </dev/null >/dev/null 2>&1; then
            fail "The package could not be extracted (it may be damaged).\n         Please run the command again. If it keeps failing, contact the developer."
        fi
    fi
    rm -rf -- "${stage:?}/__MACOSX"
    shopt -s nullglob dotglob
    for e in "$stage"/*; do
        count=$((count + 1))
        only="$e"
    done
    shopt -u nullglob dotglob
    if [ "$count" -eq 1 ] && [ -d "$only" ] && [ ! -L "$only" ]; then
        printf '%s\n' "$only"
    else
        printf '%s\n' "$stage"
    fi
}

# ---------------------------------------------------------------------------
# Preserving user data across updates
#
# The update builds the new app folder next to the old one and copies the
# "preserve" paths (relative to app/) from the old folder into it BEFORE the
# swap. If anything fails, the installed app is still untouched. Folders are
# merged (the user's files win), as Copy-Item does in install.ps1.
# ---------------------------------------------------------------------------

# carry_user_data OLD_APP NEW_APP MANIFEST KEYPATH -> prints how many items.
carry_user_data() {
    local old="$1" new="$2" manifest="$3" key="$4" n i rel parent saved=0
    if [ ! -d "$old" ]; then
        printf '0\n'
        return 0
    fi
    n="$(json_count "$manifest" "$key")"
    i=0
    while [ "$i" -lt "$n" ]; do
        rel="$(json_get "$manifest" "$key.$i" '')"
        i=$((i + 1))
        # "settings/" and "settings" are the same thing.
        while [ "${rel%/}" != "$rel" ]; do rel="${rel%/}"; done
        if ! is_safe_relpath "$rel"; then
            say_warn "Ignoring a preserve entry outside the app folder: '$rel'" >&2
            continue
        fi
        if [ ! -e "$old/$rel" ] && [ ! -L "$old/$rel" ]; then
            continue
        fi
        parent="$(dirname -- "$new/$rel")"
        mkdir -p -- "$parent"
        if ! cp -Rp -- "$old/$rel" "$parent/" >/dev/null 2>&1; then
            fail "Could not keep your data ($rel) for the update. Nothing was changed.\n         Please contact the developer."
        fi
        saved=$((saved + 1))
    done
    printf '%s\n' "$saved"
}

# ---------------------------------------------------------------------------
# VS Code extensions shipped inside the package (optional manifest field)
# ---------------------------------------------------------------------------

# Path of VS Code's "code" command, or nothing.
find_code_cli() {
    local p
    p="$(type -P code 2>/dev/null || true)"
    if [ -n "$p" ]; then
        printf '%s\n' "$p"
        return 0
    fi
    for p in "/$VSCODE_APP_CLI_SUFFIX" "$HOME/$VSCODE_APP_CLI_SUFFIX"; do
        if [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 0
}

# install_vscode_extensions MANIFEST APP_DIR CODE_CLI
# Sets VSCODE_IDS (every declared id, one per line, for the uninstaller --
# also for a file this version does not ship, so an extension installed by
# an earlier version is still removed) and VSCODE_MANUAL (commands the user
# still has to run). Never fails the installation.
VSCODE_IDS=''
VSCODE_MANUAL=''
install_vscode_extensions() {
    local manifest="$1" app="$2" cli="${3:-}" key n i file id path label cmd
    VSCODE_IDS=''
    VSCODE_MANUAL=''
    key="$(platform_key "$manifest" vscode_extensions)"
    n="$(json_count "$manifest" "$key")"
    i=0
    while [ "$i" -lt "$n" ]; do
        file="$(json_get "$manifest" "$key.$i.file" '')"
        id="$(json_get "$manifest" "$key.$i.id" '')"
        i=$((i + 1))
        if [ -z "$file" ]; then
            continue
        fi
        if [ -n "$id" ]; then
            VSCODE_IDS="$VSCODE_IDS$id"$'\n'
        fi
        label="$id"
        if [ -z "$label" ]; then label="${file##*/}"; fi
        path="$app/$file"
        if ! is_safe_relpath "$file" || [ ! -f "$path" ]; then
            say_dim "This version does not include the VS Code extension $label (skipped)."
            continue
        fi
        cmd="code --install-extension \"$path\""
        if [ -z "$cli" ]; then
            say_dim 'To get editor support for scripts, install Visual Studio Code and run:'
            say_dim "    $cmd"
            VSCODE_MANUAL="$VSCODE_MANUAL$cmd"$'\n'
            continue
        fi
        say_step "Installing the VS Code extension $label"
        if "$cli" --install-extension "$path" --force </dev/null >/dev/null 2>&1; then
            say_ok "Installed the VS Code extension $label"
        else
            say_warn "Could not install the VS Code extension $label. You can install it later by running: $cmd"
            VSCODE_MANUAL="$VSCODE_MANUAL$cmd"$'\n'
        fi
    done
}

# ---------------------------------------------------------------------------
# The launcher in ~/Applications
#
# A minimal bundle whose executable is a short bash script that changes into
# the app folder (the tool reads files relative to it) and starts the real
# program. It is written on this Mac, so it has no quarantine attribute and
# Gatekeeper never looks at it; the ad-hoc signature only keeps macOS from
# treating the bundle as damaged.
# ---------------------------------------------------------------------------

# A file name for the launcher: no "/" or ":" in it.
launcher_name() {
    local n="$1"
    n="${n//\//-}"
    n="${n//:/-}"
    printf '%s\n' "$n"
}

# True when BUNDLE is missing or is a launcher this installer made for TOOL,
# i.e. it may be replaced.
launcher_is_ours() {
    local bundle="$1" tool="$2" id
    if [ ! -e "$bundle" ] && [ ! -L "$bundle" ]; then
        return 0
    fi
    id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    [ "$id" = "$BUNDLE_ID_PREFIX.$tool" ]
}

# create_launcher BUNDLE DISPLAY TOOL VERSION MIN_MACOS EXE APP_DIR
create_launcher() {
    local bundle="$1" display="$2" tool="$3" version="$4" min="$5" exe="$6" app="$7"
    local exe_name build plist script
    exe_name="${exe##*/}"
    build="$PKG_WORK/launcher/${bundle##*/}"
    plist="$build/Contents/Info.plist"
    script="$build/Contents/MacOS/$exe_name"
    mkdir -p -- "$build/Contents/MacOS"

    # Values go in through plutil, which takes care of XML escaping.
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0">' '<dict/>' '</plist>' >"$plist"
    plutil -insert CFBundleName -string "$display" "$plist"
    plutil -insert CFBundleDisplayName -string "$display" "$plist"
    plutil -insert CFBundleIdentifier -string "$BUNDLE_ID_PREFIX.$tool" "$plist"
    plutil -insert CFBundleExecutable -string "$exe_name" "$plist"
    plutil -insert CFBundlePackageType -string 'APPL' "$plist"
    plutil -insert CFBundleVersion -string "$version" "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    if [ -n "$min" ]; then
        plutil -insert LSMinimumSystemVersion -string "$min" "$plist"
    fi
    plutil -insert NSHighResolutionCapable -bool YES "$plist"

    {
        printf '#!/bin/bash\n'
        printf '# Starts %s. Generated by the Lee Lab installer; it is replaced on update.\n' "$tool"
        printf 'APP_DIR=%q\n' "$app"
        printf 'EXE=%q\n' "$exe"
        cat <<'EOS'
cd "$APP_DIR" || exit 1
# Older macOS versions pass a -psn_ argument to apps opened from Finder.
args=()
for a in "$@"; do
    case "$a" in -psn_*) ;; *) args+=("$a") ;; esac
done
exec "./$EXE" ${args[@]+"${args[@]}"}
EOS
    } >"$script"
    chmod 755 "$script"

    if ! codesign --force -s - --deep "$build" </dev/null >/dev/null 2>&1; then
        say_warn 'Could not sign the launcher. It should still work.'
    fi

    if ! mkdir -p -- "$APPS_DIR" 2>/dev/null; then
        return 1
    fi
    if [ -e "$bundle" ] || [ -L "$bundle" ]; then
        safe_rm_rf "$bundle" || return 1
    fi
    mv -- "$build" "$bundle" 2>/dev/null || return 1
    return 0
}

# ---------------------------------------------------------------------------
# State and uninstaller
# ---------------------------------------------------------------------------

# write_state FILE NAME DISPLAY VERSION CHANNEL APP_DIR BUNDLE
write_state() {
    local file="$1" tmp="$1.tmp.plist"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0">' '<dict/>' '</plist>' >"$tmp"
    plutil -insert name -string "$2" "$tmp"
    plutil -insert display_name -string "$3" "$tmp"
    plutil -insert version -string "$4" "$tmp"
    plutil -insert channel -string "$5" "$tmp"
    plutil -insert kind -string 'native' "$tmp"
    plutil -insert platform -string "$PLATFORM_KEY" "$tmp"
    plutil -insert app_dir -string "$6" "$tmp"
    plutil -insert app_bundle -string "$7" "$tmp"
    plutil -insert installed_at -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$tmp"
    plutil -insert base_url -string "$BASE_URL" "$tmp"
    plutil -convert json -r -o "$file" "$tmp"
    rm -f -- "$tmp"
}

# write_uninstaller TOOL_ROOT TOOL DISPLAY BUNDLE IDS(one per line)
write_uninstaller() {
    local root="$1" tool="$2" display="$3" bundle="$4" ids="$5" path id list=''
    path="$root/uninstall.sh"
    while IFS= read -r id; do
        if [ -n "$id" ]; then list="$list $(printf '%q' "$id")"; fi
    done <<EOF
$ids
EOF
    {
        printf '#!/bin/bash\n'
        printf '# Uninstalls %s.\n' "$tool"
        printf '# This file was generated automatically by the Lee Lab installer.\n'
        printf '#\n'
        printf '# Run it in Terminal. Add --yes to skip the confirmation.\n'
        printf '# It removes the launcher in ~/Applications, the VS Code extensions the\n'
        printf '# installer added, and the folder this file is in. Nothing else.\n'
        printf 'set -u\n'
        printf 'TOOL=%q\n' "$tool"
        printf 'DISPLAY_NAME=%q\n' "$display"
        printf 'TOOL_ROOT=%q\n' "$root"
        printf 'APP_BUNDLE=%q\n' "$bundle"
        printf 'BUNDLE_ID=%q\n' "$BUNDLE_ID_PREFIX.$tool"
        printf 'VSCODE_EXTENSIONS=(%s)\n' "$list"
        cat <<'EOS'

find_code() {
    local p
    p="$(type -P code 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
    for p in "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
             "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
        if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
    done
}

main() {
    local yes=0 a answer code x id
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
        esac
    done

    # Only ever delete the installer's own folders.
    case "$TOOL_ROOT" in
        */"Library/Application Support/LeeLab/"?*) ;;
        *) printf '  Error: unexpected install location: %s\n' "$TOOL_ROOT" >&2; return 1 ;;
    esac
    case "/$TOOL_ROOT/" in
        */../*) printf '  Error: unexpected install location: %s\n' "$TOOL_ROOT" >&2; return 1 ;;
    esac

    printf '\n  Uninstalling %s.\n' "$DISPLAY_NAME"
    printf '  Location: %s\n' "$TOOL_ROOT"
    if [ -n "$APP_BUNDLE" ]; then printf '  Launcher: %s\n' "$APP_BUNDLE"; fi
    printf '  (Your content in ~/MMDAgent-Contents and other folders is not touched.)\n\n'
    if [ "$yes" -ne 1 ]; then
        printf '  Are you sure? (y/N) '
        answer=''
        IFS= read -r answer </dev/tty 2>/dev/null || IFS= read -r answer || true
        case "$answer" in
            y|Y|yes|Yes|YES) ;;
            *) printf '  Cancelled.\n\n'; return 0 ;;
        esac
    fi

    cd "$HOME" 2>/dev/null || cd /

    if [ -n "$APP_BUNDLE" ] && [ -d "$APP_BUNDLE" ]; then
        case "$APP_BUNDLE" in
            */Applications/?*.app)
                id="$(plutil -extract CFBundleIdentifier raw -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
                if [ "$id" = "$BUNDLE_ID" ]; then
                    rm -rf -- "$APP_BUNDLE"
                else
                    printf '  %s was not made by the installer; leaving it alone.\n' "$APP_BUNDLE"
                fi
                ;;
        esac
    fi

    if [ "${#VSCODE_EXTENSIONS[@]}" -gt 0 ]; then
        code="$(find_code)"
        if [ -n "$code" ]; then
            for x in "${VSCODE_EXTENSIONS[@]}"; do
                "$code" --uninstall-extension "$x" </dev/null >/dev/null 2>&1 || true
            done
        fi
    fi

    rm -rf -- "$TOOL_ROOT"
    # Remove the LeeLab folder too once nothing else is in it.
    rmdir -- "${TOOL_ROOT%/*}" 2>/dev/null || true

    printf '\n  Uninstalled.\n\n'
}

# Everything above is read before anything runs, so deleting this file's
# folder while it runs is safe.
main "$@"
exit $?
EOS
    } >"$path"
    chmod 755 "$path"
}

# ---------------------------------------------------------------------------
# Tool selection
# ---------------------------------------------------------------------------

# Sets SEL_NAME, SEL_DISPLAY and SEL_MANIFEST (the default channel's path).
SEL_NAME=''
SEL_DISPLAY=''
SEL_MANIFEST=''
select_tool() {
    local index="$1" n i name display desc mpath names='' rc
    local cand_names=() cand_displays=() cand_descs=() cand_manifests=()
    local count=0
    n="$(json_count "$index" tools)"
    if [ "$n" -eq 0 ]; then
        fail 'No tools are available for installation.'
    fi

    i=0
    while [ "$i" -lt "$n" ]; do
        name="$(json_get "$index" "tools.$i.name" '')"
        display="$(json_get "$index" "tools.$i.display_name" "$name")"
        desc="$(json_get "$index" "tools.$i.description" '')"
        mpath="$(json_get "$index" "tools.$i.manifest" "tools/$name.json")"
        i=$((i + 1))
        if [ -z "$name" ]; then continue; fi
        names="$names${names:+, }$name"
        if [ -n "$REQUESTED_TOOL" ]; then
            if [ "$name" = "$REQUESTED_TOOL" ]; then
                SEL_NAME="$name"
                SEL_DISPLAY="$display"
                SEL_MANIFEST="$mpath"
                return 0
            fi
            continue
        fi
        # The menu lists only the tools that have a build for this Mac on the
        # chosen channel, so a Mac user is never offered a Windows-only tool.
        rc=0
        fetch_file "$BASE_URL/$(manifest_path "$mpath" "$CHANNEL")" "$WORK_DIR/probe.json" || rc=$?
        if [ "$rc" -eq 1 ]; then
            fail "Could not fetch the distribution info from $BASE_URL\n         Please check your internet connection."
        fi
        if [ "$rc" -ne 0 ] || [ "$(json_type "$WORK_DIR/probe.json" "platforms.$PLATFORM_KEY")" != 'dictionary' ]; then
            continue
        fi
        cand_names[count]="$name"
        cand_displays[count]="$display"
        cand_descs[count]="$desc"
        cand_manifests[count]="$mpath"
        count=$((count + 1))
    done

    if [ -n "$REQUESTED_TOOL" ]; then
        fail "There is no tool named '$REQUESTED_TOOL'. Available tools: $names"
    fi
    if [ "$count" -eq 0 ]; then
        say ''
        say "  None of the tools has a $PLATFORM_LABEL version on the $CHANNEL channel yet."
        say '  There is nothing to install. If you expected one, please contact the developer.'
        say ''
        exit 0
    fi
    if [ "$count" -eq 1 ]; then
        SEL_NAME="${cand_names[0]}"
        SEL_DISPLAY="${cand_displays[0]}"
        SEL_MANIFEST="${cand_manifests[0]}"
        return 0
    fi

    say_head 'Select the tool you want to install'
    i=0
    while [ "$i" -lt "$count" ]; do
        say "    [$((i + 1))] ${cand_displays[$i]}"
        say_dim "      ${cand_descs[$i]}"
        i=$((i + 1))
    done
    say ''
    while :; do
        ask '  Enter a number and press Enter (or q to quit): '
        ANSWER="$(trim "$ANSWER")"
        if [ "$ANSWER" = 'q' ] || [ "$ANSWER" = 'Q' ]; then
            printf '\n  Cancelled.\n\n'
            exit 0
        fi
        if is_uint "$ANSWER" && [ "$ANSWER" -ge 1 ] && [ "$ANSWER" -le "$count" ]; then
            i=$((ANSWER - 1))
            SEL_NAME="${cand_names[$i]}"
            SEL_DISPLAY="${cand_displays[$i]}"
            SEL_MANIFEST="${cand_manifests[$i]}"
            return 0
        fi
        say_warn "Please enter a number between 1 and $count."
    done
}

# ---------------------------------------------------------------------------
# Notes from the manifest
# ---------------------------------------------------------------------------

# Prints the manifest's notes. The macOS block may carry its own; otherwise
# the shared ones are shown, except those about Windows.
show_notes() {
    local manifest="$1" key n i note shown=0
    key="$(platform_key "$manifest" notes)"
    n="$(json_count "$manifest" "$key")"
    i=0
    while [ "$i" -lt "$n" ]; do
        note="$(json_get "$manifest" "$key.$i" '')"
        i=$((i + 1))
        if [ -z "$note" ]; then continue; fi
        if [ "$key" = 'notes' ]; then
            case "$note" in *[Ww]indows*) continue ;; esac
        fi
        if [ "$shown" -eq 0 ]; then
            say '  Please note:'
            shown=1
        fi
        say_dim "- $note"
    done
    if [ "$shown" -eq 1 ]; then say ''; fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

install_tool() {
    local name="$SEL_NAME" entry_display="$SEL_DISPLAY" mpath manifest notfound
    local display version kind pk pkg_url sha encrypted iter exe min_macos
    local tool_root app_dir state_file uninstall bundle old_bundle
    local installed_version installed_channel question
    local zip enc stage new_app carried preserve_key code_cli
    local launcher_ok=0

    mpath="$(manifest_path "$SEL_MANIFEST" "$CHANNEL")"
    manifest="$WORK_DIR/manifest.json"
    if [ "$CHANNEL" = "$DEFAULT_CHANNEL" ]; then
        notfound="$entry_display has not been released yet. Please contact the developer."
    else
        notfound="$entry_display has not been released on the $CHANNEL channel yet.\n         Please run the command again without setting a channel, or contact the developer."
    fi
    fetch_json "$BASE_URL/$mpath" "$manifest" "$notfound"

    display="$(json_get "$manifest" display_name "$name")"
    version="$(json_get "$manifest" version '0.0.0')"
    pk="platforms.$PLATFORM_KEY"

    # A manifest without the macOS block means this version has no macOS
    # build (the release workflow drops a stale one). Not an error.
    if [ "$(json_type "$manifest" "$pk")" != 'dictionary' ]; then
        say ''
        say "  $display $version does not have a $PLATFORM_LABEL version on the $CHANNEL channel."
        say '  There is nothing to install. If you expected one, please contact the developer.'
        say ''
        exit 0
    fi

    # 'python' is the default kind, as in install.ps1. Only prebuilt
    # packages can be installed on macOS.
    kind="$(json_get "$manifest" kind 'python')"
    if [ "$kind" != 'native' ]; then
        fail "This installer does not understand how to install $display on macOS (kind: $kind). Please contact the developer."
    fi

    pkg_url="$(json_get "$manifest" "$pk.package.url" '')"
    sha="$(json_get "$manifest" "$pk.package.sha256" '')"
    encrypted="$(json_get "$manifest" "$pk.package.encrypted" 'false')"
    iter="$(json_get "$manifest" "$pk.package.kdf_iterations" "$DEFAULT_KDF_ITERATIONS")"
    exe="$(json_get "$manifest" "$pk.exe" '')"
    min_macos="$(json_get "$manifest" "$pk.min_macos" '')"
    if [ -z "$pkg_url" ]; then
        fail "$display has not been released for macOS yet. Please contact the developer."
    fi
    if [ -z "$exe" ] || ! is_safe_relpath "$exe"; then
        fail "The distribution info for $display is incomplete (no exe entry). Please contact the developer."
    fi
    if ! is_uint "$iter"; then
        fail "The distribution info for $display is malformed (kdf_iterations). Please contact the developer."
    fi
    check_min_macos "$min_macos" "$display"

    # The name becomes a folder name; never let it point anywhere else.
    case "$name" in
        ''|.|..|*/*) fail "The distribution info names an invalid tool ('$name'). Please contact the developer." ;;
    esac
    tool_root="$INSTALL_ROOT/$name"
    app_dir="$tool_root/app"
    state_file="$tool_root/install.json"
    uninstall="$tool_root/uninstall.sh"
    bundle="$APPS_DIR/$(launcher_name "$display").app"

    # --- Check for an existing installation --------------------------------
    old_bundle=''
    if [ -f "$state_file" ]; then
        installed_version="$(json_get "$state_file" version 'unknown')"
        # Anything recorded without a channel came from the default one.
        installed_channel="$(json_get "$state_file" channel "$DEFAULT_CHANNEL")"
        old_bundle="$(json_get "$state_file" app_bundle '')"
        say_head "$display is already installed (version $installed_version, $installed_channel channel)"
        if [ "$installed_channel" != "$CHANNEL" ]; then
            say "  You asked for the $CHANNEL channel, where the current version is $version."
            say "  Going on replaces the installed $installed_channel version with it."
            question="  Switch to the $CHANNEL channel now? (Y/n)"
        elif [ "$installed_version" = "$version" ]; then
            say_dim 'This is the same as the latest available version.'
            question='  Reinstall / update now? (Y/n)'
        else
            say "  A newer version, $version, is available."
            question='  Reinstall / update now? (Y/n)'
        fi
        confirm_or_exit "$question"
    fi

    if [ "$CHANNEL" = "$DEFAULT_CHANNEL" ]; then
        say_head "Installing $display $version"
    else
        say_head "Installing $display $version ($CHANNEL channel)"
    fi
    say_dim "Install location: $tool_root"
    say ''
    show_notes "$manifest"

    mkdir -p -- "$tool_root"
    # Leftovers of an earlier run that was interrupted.
    remove_stale_work "$tool_root"
    # Work next to the app folder, so that the final swap is a rename on the
    # same disk rather than a copy of hundreds of megabytes.
    PKG_WORK="$(mktemp -d "$tool_root/.install.XXXXXX")"

    # --- Fetch the package -------------------------------------------------
    say_step "Downloading $display..."
    zip="$PKG_WORK/package.zip"
    if is_true "$encrypted"; then
        # The manifest hash is that of the decrypted zip, so it is checked
        # after decryption (it also catches a wrong password).
        enc="$PKG_WORK/package.enc"
        download_package "$pkg_url" "$enc"
        say_ok 'Download complete'
        unlock_package "$enc" "$zip" "$sha" "$iter" "$display"
        rm -f -- "$enc"
    else
        download_package "$pkg_url" "$zip"
        if ! sha256_matches "$zip" "$sha"; then
            rm -f -- "$zip"
            fail "The downloaded file is corrupted (checksum mismatch).\n         Please wait a moment and run the command again."
        fi
        say_ok 'Download complete'
    fi

    # --- Extract next to the installed app, then swap ------------------------
    say_step 'Extracting files...'
    stage="$PKG_WORK/stage"
    new_app="$(extract_package "$zip" "$stage")"
    rm -f -- "$zip"
    if [ ! -f "$new_app/$exe" ]; then
        fail "$exe is missing from the package. Nothing was changed.\n         Please contact the developer."
    fi
    chmod +x "$new_app/$exe"
    # curl adds no quarantine attribute, but make sure nothing in the app
    # carries one, or Gatekeeper would block it.
    xattr -dr com.apple.quarantine "$new_app" 2>/dev/null || true

    preserve_key="$(platform_key "$manifest" preserve)"
    carried="$(carry_user_data "$app_dir" "$new_app" "$manifest" "$preserve_key")"
    if [ "$carried" -gt 0 ]; then
        say_ok "Kept your settings and cached data ($carried item(s))"
    fi

    if [ -e "$app_dir" ]; then
        mv -- "$app_dir" "$PKG_WORK/old-app"
    fi
    if ! mv -- "$new_app" "$app_dir"; then
        if [ -e "$PKG_WORK/old-app" ]; then mv -- "$PKG_WORK/old-app" "$app_dir" || true; fi
        fail 'Could not put the new files in place. Nothing was changed.'
    fi
    say_ok 'Extracted'

    # --- Launcher --------------------------------------------------------
    if [ -n "$old_bundle" ] && [ "$old_bundle" != "$bundle" ] && launcher_is_ours "$old_bundle" "$name"; then
        # The display name changed; take the old launcher away.
        safe_rm_rf "$old_bundle" || true
    fi
    if ! launcher_is_ours "$bundle" "$name"; then
        say_warn "$bundle already exists and was not made by this installer; it was left alone."
    elif create_launcher "$bundle" "$display" "$name" "$version" "$min_macos" "$exe" "$app_dir"; then
        launcher_ok=1
        say_ok "Created the launcher $bundle"
    else
        say_warn "Could not create the launcher in $APPS_DIR."
    fi
    if [ "$launcher_ok" -ne 1 ]; then
        bundle=''
    fi

    # --- VS Code extensions (optional) -----------------------------------------
    code_cli="$(find_code_cli)"
    install_vscode_extensions "$manifest" "$app_dir" "$code_cli"

    # --- Record the state ------------------------------------------------
    write_state "$state_file" "$name" "$display" "$version" "$CHANNEL" "$app_dir" "$bundle"
    write_uninstaller "$tool_root" "$name" "$display" "$bundle" "$VSCODE_IDS"

    # --- Done ------------------------------------------------------------
    say ''
    say "  ${C_OK}$display $version was installed successfully.${C_RESET}"
    say ''
    if [ "$launcher_ok" -eq 1 ]; then
        say "  Start it from \"$display\" in the Applications folder of your home folder"
        say '  (in Finder: Go > Home, then Applications), or find it with Spotlight (Command + Space).'
    else
        say '  Start it from Terminal with:'
        say "      cd $(printf '%q' "$app_dir") && ./$(printf '%q' "$exe")"
    fi
    if [ -n "$VSCODE_MANUAL" ]; then
        say ''
        say '  For editor support in Visual Studio Code, run:'
        while IFS= read -r question; do
            if [ -n "$question" ]; then say "      $question"; fi
        done <<EOF
$VSCODE_MANUAL
EOF
    fi
    say ''
    say_dim 'To update later, just run the same command again.'
    say_dim 'To uninstall, run this in Terminal:'
    say_dim "    $(printf '%q' "$uninstall")"
    say ''
}

remove_stale_work() {
    local d
    shopt -s nullglob dotglob
    for d in "$1"/.install.*; do
        safe_rm_rf "$d" || true
    done
    shopt -u nullglob dotglob
}

init_globals() {
    if [ -z "${HOME:-}" ] || [ "${HOME#/}" = "$HOME" ]; then
        fail 'The HOME folder is not set.'
    fi
    BASE_URL="${LEELAB_BASE_URL:-$DEFAULT_BASE_URL}"
    while [ "${BASE_URL%/}" != "$BASE_URL" ]; do BASE_URL="${BASE_URL%/}"; done
    REQUESTED_TOOL="$(trim "${LEELAB_TOOL:-}")"
    ASSUME_YES=0
    if is_true "${LEELAB_YES:-}"; then ASSUME_YES=1; fi
    INSTALL_ROOT="${HOME%/}/Library/Application Support/LeeLab"
    APPS_DIR="${HOME%/}/Applications"
}

cleanup() {
    if [ -n "$PKG_WORK" ] && [ -d "$PKG_WORK" ]; then
        safe_rm_rf "$PKG_WORK" || true
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
    fi
}

main() {
    local tmp
    init_globals

    say ''
    say "  ${C_HEAD}============================================${C_RESET}"
    say "  ${C_HEAD} Lee Lab Tool Installer (macOS)${C_RESET}"
    say "  ${C_HEAD}============================================${C_RESET}"

    check_environment
    CHANNEL="$(resolve_channel "${LEELAB_CHANNEL:-}")"

    tmp="${TMPDIR:-/tmp}"
    WORK_DIR="$(mktemp -d "${tmp%/}/leelab-install.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    fetch_json "$BASE_URL/tools/index.json" "$WORK_DIR/index.json"
    select_tool "$WORK_DIR/index.json"
    install_tool
}

# Run main when executed (as a file or through "curl | bash", where
# BASH_SOURCE is empty), but not when sourced by tests/test-install.sh.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
