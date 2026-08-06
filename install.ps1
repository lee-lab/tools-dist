<#
    Lee Lab ツール共通インストーラ

    使い方（利用者向け）:
        PowerShell を開いて次の 1 行を貼り付けて実行してください。

        irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex

    インストールするツールを直接指定したい場合:
        $env:LEELAB_TOOL = "valles"
        irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex

    管理者権限は不要です。すべて %LOCALAPPDATA%\LeeLab\ の下にインストールされます。

    このスクリプトがやること:
        1. uv (Python の環境管理ツール) を導入する
        2. ツールが要求する Python を uv 経由で用意する（利用者が Python を入れる必要はない）
        3. ツール本体を GitHub Releases から取得し、SHA256 で検証して展開する
        4. 専用の仮想環境を作り、依存パッケージを導入する
        5. デスクトップとスタートメニューにショートカットを作る

    Windows PowerShell 5.1（Windows 10 / 11 の標準）で動作します。
#>

[CmdletBinding()]
param(
    # インストールするツール名。省略時はメニューから選択します。
    [string] $Tool = '',

    # 配布リポジトリのベース URL。フォーク時や検証時のみ変更してください。
    [string] $BaseUrl = '',

    # インストール先のルート。省略時は %LOCALAPPDATA%\LeeLab
    [string] $InstallRoot = '',

    # 確認を求めずに処理を進めます（更新の自動化用）。
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 古い .NET の既定では TLS 1.2 が無効なことがあり、GitHub への接続に失敗する。
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Invoke-WebRequest の進捗表示は 5.1 で極端に遅いため抑制する。
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------

$DefaultBaseUrl = 'https://raw.githubusercontent.com/lee-lab/tools-dist/main'
$UvInstallerUrl = 'https://astral.sh/uv/install.ps1'
$RegistryRoot   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$Publisher      = 'Lee Lab'

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    if ($env:LEELAB_BASE_URL) { $BaseUrl = $env:LEELAB_BASE_URL } else { $BaseUrl = $DefaultBaseUrl }
}
$BaseUrl = $BaseUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($Tool) -and $env:LEELAB_TOOL) { $Tool = $env:LEELAB_TOOL }

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'LeeLab'
}

# ---------------------------------------------------------------------------
# 表示ヘルパ
# ---------------------------------------------------------------------------

function Write-Head([string] $Text) {
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step([string] $Text) {
    Write-Host '  - ' -ForegroundColor DarkGray -NoNewline
    Write-Host $Text
}

function Write-Ok([string] $Text) {
    Write-Host '  * ' -ForegroundColor Green -NoNewline
    Write-Host $Text
}

function Write-Warn([string] $Text) {
    Write-Host '  ! ' -ForegroundColor Yellow -NoNewline
    Write-Host $Text -ForegroundColor Yellow
}

function Fail([string] $Text) {
    Write-Host ''
    Write-Host '  エラー: ' -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Red
    Write-Host ''
    Write-Host '  解決しない場合は、この画面をそのままコピーして開発者に連絡してください。' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

# StrictMode 下では存在しないプロパティへのアクセスが例外になるため、
# マニフェストの任意項目はこのヘルパ経由で読む。
function Get-Prop($Object, [string] $Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

# ---------------------------------------------------------------------------
# 実行環境の確認
# ---------------------------------------------------------------------------

function Test-Environment {
    # 配布している wheel と PyTorch は 64bit x86 Windows 用のみ。
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -ne 'AMD64') {
        Fail "64bit 版の Windows が必要です (検出: $arch)。ARM 版 Windows には対応していません。"
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Fail "PowerShell 5.0 以降が必要です (検出: $($PSVersionTable.PSVersion))。"
    }
}

# ---------------------------------------------------------------------------
# ダウンロード
# ---------------------------------------------------------------------------

function Get-RemoteJson([string] $Url) {
    # 配信側が Content-Type に charset を付けてくるとは限らない。付いていないと
    # Invoke-WebRequest は既定の文字コードで復号してしまい、マニフェスト中の
    # 日本語が化ける。UTF-8 と明示して読む。
    $client = $null
    try {
        $client = New-Object System.Net.WebClient
        $client.Encoding = [System.Text.Encoding]::UTF8
        $client.Headers.Add('User-Agent', 'leelab-tools-dist-installer')
        $text = $client.DownloadString($Url)
    } catch {
        Fail "配布情報を取得できませんでした: $Url`n         インターネット接続を確認してください。詳細: $($_.Exception.Message)"
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }

    # BOM 付きで配信されている場合、先頭の文字が残ると ConvertFrom-Json が失敗する。
    if ($text.Length -gt 0 -and $text[0] -eq [char] 0xFEFF) { $text = $text.Substring(1) }

    try {
        return $text | ConvertFrom-Json
    } catch {
        Fail "配布情報の形式が不正です: $Url"
    }
}

function Save-RemoteFile([string] $Url, [string] $Destination, [string] $Sha256 = '') {
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $client = $null
    try {
        # WebClient は Invoke-WebRequest と違いストリーミングで保存するため、
        # 数百 MB のファイルでもメモリを消費しない。リダイレクトも追跡する。
        $client = New-Object System.Net.WebClient
        $client.Headers.Add('User-Agent', 'leelab-tools-dist-installer')
        $client.DownloadFile($Url, $Destination)
    } catch {
        Fail "ダウンロードに失敗しました: $Url`n         詳細: $($_.Exception.Message)"
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }

    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $actual = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Remove-Item -Force $Destination -ErrorAction SilentlyContinue
            Fail "ダウンロードしたファイルが壊れています（ハッシュ不一致）。`n         時間をおいて再実行してください。"
        }
    }
}

# ---------------------------------------------------------------------------
# uv の導入
# ---------------------------------------------------------------------------

function Install-Uv {
    # すでに PATH にあればそれを使う。
    $existing = Get-Command uv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "uv は導入済み ($($existing.Source))"
        return $existing.Source
    }

    # 公式インストーラの既定の配置先。PATH 未反映でもここを直接見る。
    $uvHome = Join-Path $env:USERPROFILE '.local\bin'
    $uvExe  = Join-Path $uvHome 'uv.exe'
    if (Test-Path $uvExe) {
        $env:Path = "$uvHome;$env:Path"
        Write-Ok 'uv は導入済み'
        return $uvExe
    }

    Write-Step 'uv (Python 環境管理ツール) を導入中...'
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) 'leelab-uv-install.ps1'
    try {
        $content = (Invoke-WebRequest -Uri $UvInstallerUrl -UseBasicParsing).Content
        # astral.sh はスクリプトをテキストとして宣言しないことがあり、その場合
        # Invoke-WebRequest は文字列ではなくバイト列を返す。
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }

        # 公式インストーラは自前のエラーハンドリングを持つため、こちらの
        # StrictMode / ErrorActionPreference の影響を受けないよう別プロセスで走らせる。
        # (Invoke-Expression でこのスコープに読み込むと誤動作する)
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($scriptPath, $content, $utf8Bom)

        $log = Invoke-Native 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
        if ($LASTEXITCODE -ne 0) {
            $log | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Fail 'uv の導入に失敗しました。'
        }
    } catch {
        Fail "uv の導入に失敗しました。`n         詳細: $($_.Exception.Message)"
    } finally {
        Remove-Item -Force $scriptPath -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $uvExe)) {
        Fail 'uv の導入に失敗しました（実行ファイルが見つかりません）。'
    }
    $env:Path = "$uvHome;$env:Path"
    Write-Ok 'uv を導入しました'
    return $uvExe
}

# 外部コマンドを実行し、標準出力と標準エラーをまとめて返す。
#
# uv をはじめ多くのコマンドは進捗表示を標準エラーに書く。$ErrorActionPreference が
# 'Stop' のままだと、PowerShell はそれを NativeCommandError という終了エラーとして
# 扱ってしまい、正常に動いているコマンドの途中でスクリプトが止まる。
# そのため、この呼び出しの間だけ設定を緩め、成否は終了コードで判断する。
function Invoke-Native([string] $Exe, [string[]] $NativeArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @NativeArgs 2>&1
    } finally {
        $ErrorActionPreference = $previous
    }
    return $output
}

function Invoke-Uv([string] $UvExe, [string[]] $UvArgs, [string] $FailMessage) {
    # 標準エラーもまとめて拾い、失敗時だけ表示する（成功時のログは冗長なので出さない）。
    $output = Invoke-Native $UvExe $UvArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Fail $FailMessage
    }
}

# ---------------------------------------------------------------------------
# ショートカット
# ---------------------------------------------------------------------------

function New-Shortcut {
    param(
        [string] $Path,
        [string] $Target,
        [string] $Arguments,
        [string] $WorkingDirectory,
        [string] $IconPath,
        [string] $Description
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    # settings.json やコンテンツキャッシュはカレントディレクトリ相対で保存されるため、
    # 作業ディレクトリの指定は必須。ここを誤ると設定が別の場所に書かれる。
    $lnk.WorkingDirectory = $WorkingDirectory
    if ($IconPath -and (Test-Path $IconPath)) { $lnk.IconLocation = $IconPath }
    $lnk.Description = $Description
    $lnk.Save()
}

# ---------------------------------------------------------------------------
# ツール選択
# ---------------------------------------------------------------------------

function Select-Tool($Index) {
    $tools = @(Get-Prop $Index 'tools' @())
    if ($tools.Count -eq 0) { Fail '配布可能なツールがありません。' }

    if (-not [string]::IsNullOrWhiteSpace($Tool)) {
        $match = $tools | Where-Object { $_.name -eq $Tool }
        if (-not $match) {
            $names = ($tools | ForEach-Object { $_.name }) -join ', '
            Fail "'$Tool' というツールはありません。利用できるのは: $names"
        }
        return @($match)[0]
    }

    if ($tools.Count -eq 1) { return $tools[0] }

    Write-Head 'インストールするツールを選んでください'
    for ($i = 0; $i -lt $tools.Count; $i++) {
        $t = $tools[$i]
        Write-Host ("    [{0}] {1}" -f ($i + 1), $t.display_name) -ForegroundColor White
        Write-Host ("        {0}" -f (Get-Prop $t 'description' '')) -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $answer = Read-Host '  番号を入力して Enter (中止する場合は q)'
        if ($answer -eq 'q') { Write-Host ''; Write-Host '  中止しました。'; exit 0 }
        $n = 0
        if ([int]::TryParse($answer, [ref] $n) -and $n -ge 1 -and $n -le $tools.Count) {
            return $tools[$n - 1]
        }
        Write-Warn ('1 から {0} の番号を入力してください。' -f $tools.Count)
    }
}

# ---------------------------------------------------------------------------
# 展開（zip 内の単一ルートフォルダを取り除く）
# ---------------------------------------------------------------------------

function Expand-Package([string] $ZipPath, [string] $Destination) {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $staging -Force

        # zip が単一のフォルダで包まれている場合（valles-1.0.0/ など）は
        # そのフォルダの中身を展開先に置く。
        $entries = @(Get-ChildItem -Force $staging)
        $source = $staging
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $source = $entries[0].FullName
        }

        if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Get-ChildItem -Force $source | ForEach-Object {
            Move-Item -Force -Path $_.FullName -Destination $Destination
        }
    } finally {
        Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 更新時のユーザデータ退避
# ---------------------------------------------------------------------------

function Save-UserData([string] $AppDir, [string[]] $Paths) {
    if (-not (Test-Path $AppDir)) { return $null }
    if ($null -eq $Paths -or $Paths.Count -eq 0) { return $null }

    $backup = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $backup | Out-Null

    $saved = 0
    foreach ($rel in $Paths) {
        $src = Join-Path $AppDir $rel
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $backup $rel
        $dstParent = Split-Path -Parent $dst
        if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }
        Copy-Item -Recurse -Force -Path $src -Destination $dst
        $saved++
    }
    if ($saved -eq 0) {
        Remove-Item -Recurse -Force $backup -ErrorAction SilentlyContinue
        return $null
    }
    Write-Ok "設定とキャッシュを退避しました ($saved 件)"
    return $backup
}

function Restore-UserData([string] $Backup, [string] $AppDir) {
    if ([string]::IsNullOrWhiteSpace($Backup)) { return }
    if (-not (Test-Path $Backup)) { return }
    try {
        Get-ChildItem -Force $Backup | ForEach-Object {
            Copy-Item -Recurse -Force -Path $_.FullName -Destination $AppDir
        }
        Write-Ok '設定とキャッシュを復元しました'
    } finally {
        Remove-Item -Recurse -Force $Backup -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# アンインストール情報の登録（Windows の「アプリと機能」に表示させる）
# ---------------------------------------------------------------------------

function Register-Uninstall {
    param(
        [string] $Name,
        [string] $DisplayName,
        [string] $Version,
        [string] $ToolRoot,
        [string] $IconPath
    )
    $uninstallScript = Join-Path $ToolRoot 'uninstall.ps1'
    $key = Join-Path $RegistryRoot "LeeLab-$Name"

    $sizeKb = 0
    try {
        $sizeKb = [int]((Get-ChildItem -Recurse -Force -File $ToolRoot |
            Measure-Object -Property Length -Sum).Sum / 1KB)
    } catch { }

    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'DisplayName'     -Value $DisplayName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'DisplayVersion'  -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'Publisher'       -Value $Publisher -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'InstallLocation' -Value $ToolRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name 'NoModify'        -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'NoRepair'        -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'EstimatedSize'   -Value $sizeKb -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'UninstallString' `
        -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`"" `
        -PropertyType String -Force | Out-Null
    if ($IconPath -and (Test-Path $IconPath)) {
        New-ItemProperty -Path $key -Name 'DisplayIcon' -Value $IconPath -PropertyType String -Force | Out-Null
    }
}

function Write-UninstallScript {
    param(
        [string] $Name,
        [string] $DisplayName,
        [string] $ToolRoot,
        [string[]] $ShortcutPaths
    )
    $shortcutList = ($ShortcutPaths | ForEach-Object { "    '" + $_.Replace("'", "''") + "'" }) -join ",`n"
    $content = @"
# $DisplayName をアンインストールします。
# このファイルはインストーラが自動生成しました。
#
# Windows の「設定 > アプリ」から実行されるほか、確認を省いて実行することもできます。
#     powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Yes
param([switch] `$Yes)

`$ErrorActionPreference = 'SilentlyContinue'

`$toolRoot = '$($ToolRoot.Replace("'", "''"))'
`$shortcuts = @(
$shortcutList
)

Write-Host ''
Write-Host '  $DisplayName をアンインストールします。'
Write-Host "  削除先: `$toolRoot"
Write-Host ''
if (-not `$Yes) {
    `$answer = Read-Host '  よろしいですか? (y/N)'
    if (`$answer -ne 'y' -and `$answer -ne 'Y') {
        Write-Host '  中止しました。'
        exit 0
    }
}

foreach (`$s in `$shortcuts) {
    if (`$s -and (Test-Path `$s)) { Remove-Item -Force `$s }
}
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LeeLab-$Name' -Recurse -Force

# 自分自身がツールフォルダの中にあるため、削除は別プロセスに任せる。
Start-Process -WindowStyle Hidden powershell.exe -ArgumentList @(
    '-NoProfile', '-Command',
    "Start-Sleep -Seconds 2; Remove-Item -Recurse -Force '`$toolRoot'"
)

Write-Host ''
Write-Host '  アンインストールしました。'
Write-Host ''
"@
    $path = Join-Path $ToolRoot 'uninstall.ps1'
    # Windows PowerShell 5.1 が確実に読めるよう BOM 付き UTF-8 で書く。
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $content, $utf8Bom)
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

function Install-Tool($Entry) {
    $name = $Entry.name
    $manifestUrl = "$BaseUrl/$(Get-Prop $Entry 'manifest' "tools/$name.json")"
    $m = Get-RemoteJson $manifestUrl

    $displayName = Get-Prop $m 'display_name' $name
    $version     = Get-Prop $m 'version' '0.0.0'
    $pkg         = Get-Prop $m 'package'
    if ($null -eq $pkg) { Fail "$displayName の配布情報が未整備です（package が未設定）。" }
    $pkgUrl = Get-Prop $pkg 'url' ''
    if ([string]::IsNullOrWhiteSpace($pkgUrl)) {
        Fail "$displayName はまだリリースされていません。開発者に連絡してください。"
    }

    $toolRoot = Join-Path $InstallRoot $name
    $appDir   = Join-Path $toolRoot 'app'
    $venvDir  = Join-Path $toolRoot '.venv'
    $stateFile = Join-Path $toolRoot 'install.json'

    # --- 既存インストールの確認 -------------------------------------------
    $installed = $null
    if (Test-Path $stateFile) {
        try { $installed = Get-Content -Raw $stateFile | ConvertFrom-Json } catch { $installed = $null }
    }
    if ($null -ne $installed) {
        $installedVersion = Get-Prop $installed 'version' '不明'
        Write-Head "$displayName は既にインストールされています (バージョン $installedVersion)"
        if ($installedVersion -eq $version) {
            Write-Host "  配布中の最新版と同じバージョンです。" -ForegroundColor DarkGray
        } else {
            Write-Host "  新しいバージョン $version が利用できます。" -ForegroundColor White
        }
        if (-not $Quiet) {
            Write-Host ''
            $answer = Read-Host '  再インストール / 更新しますか? (Y/n)'
            if ($answer -eq 'n' -or $answer -eq 'N') {
                Write-Host ''; Write-Host '  中止しました。'; exit 0
            }
        }
    }

    Write-Head "$displayName $version をインストールします"
    Write-Host "  インストール先: $toolRoot" -ForegroundColor DarkGray
    Write-Host ''

    # --- uv と Python ------------------------------------------------------
    $uv = Install-Uv

    $python = Get-Prop $m 'python' '3.12'
    Write-Step "Python $python を用意中..."
    Invoke-Uv $uv @('python', 'install', $python) `
        "Python $python の導入に失敗しました。"
    Write-Ok "Python $python を用意しました"

    # --- 本体の取得 --------------------------------------------------------
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        Write-Step "$displayName 本体をダウンロード中..."
        $zipPath = Join-Path $work 'package.zip'
        Save-RemoteFile $pkgUrl $zipPath (Get-Prop $pkg 'sha256' '')
        Write-Ok '本体を取得しました'

        # 更新の場合、設定・キャッシュを退避してから展開する。
        $preserve = @(Get-Prop $m 'preserve' @())
        $backup = Save-UserData $appDir $preserve

        Write-Step 'ファイルを展開中...'
        Expand-Package $zipPath $appDir
        Restore-UserData $backup $appDir
        Write-Ok '展開しました'

        # --- 依存パッケージ -------------------------------------------------
        # PyPI に無い wheel（PyOgg 0.7 など）を先に取得し、--find-links で参照させる。
        $wheelDir = Join-Path $work 'wheels'
        New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null
        $wheels = @(Get-Prop $m 'wheels' @())
        foreach ($w in $wheels) {
            $fileName = Split-Path -Leaf $w
            Save-RemoteFile "$BaseUrl/$w" (Join-Path $wheelDir $fileName)
        }
        if ($wheels.Count -gt 0) { Write-Ok "同梱 wheel を取得しました ($($wheels.Count) 件)" }

        Write-Step '仮想環境を作成中...'
        # --clear が無いと、更新時に「既に存在する」で失敗する。
        # 作り直すことで、旧バージョンで使っていて今は不要になったパッケージが
        # 残り続けるのも防げる。uv はダウンロード済みの wheel をキャッシュから
        # 再利用するため、再作成でも通信は発生しない。
        Invoke-Uv $uv @('venv', '--clear', '--python', $python, $venvDir) '仮想環境の作成に失敗しました。'

        $venvPython = Join-Path $venvDir 'Scripts\python.exe'
        if (-not (Test-Path $venvPython)) { Fail '仮想環境の作成に失敗しました。' }

        $reqName = Get-Prop $m 'requirements' 'requirements.txt'
        $reqPath = Join-Path $appDir $reqName
        if (-not (Test-Path $reqPath)) { Fail "$reqName が配布物に含まれていません。" }

        Write-Step '依存パッケージを導入中... (数分かかります。そのままお待ちください)'
        Invoke-Uv $uv @(
            'pip', 'install',
            '--python', $venvPython,
            '-r', $reqPath,
            '--find-links', $wheelDir
        ) '依存パッケージの導入に失敗しました。'
        Write-Ok '依存パッケージを導入しました'

    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    # --- ショートカット ----------------------------------------------------
    $entryScript = Get-Prop $m 'entry' 'main.py'
    $iconName = Get-Prop $m 'icon' ''
    $iconPath = ''
    if ($iconName) {
        $candidate = Join-Path $appDir $iconName
        if (Test-Path $candidate) { $iconPath = $candidate }
    }

    $pythonw = Join-Path $venvDir 'Scripts\pythonw.exe'
    if (-not (Test-Path $pythonw)) { $pythonw = $venvPython }

    $shortcutOpts = Get-Prop $m 'shortcuts'
    $wantDesktop  = [bool] (Get-Prop $shortcutOpts 'desktop' $true)
    $wantStart    = [bool] (Get-Prop $shortcutOpts 'start_menu' $true)
    $wantConsole  = [bool] (Get-Prop $shortcutOpts 'console_variant' $false)

    $startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$Publisher"
    $createdShortcuts = New-Object System.Collections.ArrayList

    if ($wantDesktop) {
        $p = Join-Path ([Environment]::GetFolderPath('Desktop')) "$displayName.lnk"
        New-Shortcut -Path $p -Target $pythonw -Arguments $entryScript `
            -WorkingDirectory $appDir -IconPath $iconPath -Description $displayName
        [void] $createdShortcuts.Add($p)
    }
    if ($wantStart) {
        $p = Join-Path $startMenuDir "$displayName.lnk"
        New-Shortcut -Path $p -Target $pythonw -Arguments $entryScript `
            -WorkingDirectory $appDir -IconPath $iconPath -Description $displayName
        [void] $createdShortcuts.Add($p)
    }
    if ($wantConsole) {
        # 不具合調査用。コンソールを表示したまま起動し、エラーメッセージを読めるようにする。
        $p = Join-Path $startMenuDir "$displayName (診断モード).lnk"
        New-Shortcut -Path $p -Target $venvPython -Arguments $entryScript `
            -WorkingDirectory $appDir -IconPath $iconPath `
            -Description "$displayName をコンソール表示付きで起動します（不具合調査用）"
        [void] $createdShortcuts.Add($p)
    }
    Write-Ok "ショートカットを作成しました ($($createdShortcuts.Count) 件)"

    # --- 状態の記録 --------------------------------------------------------
    $state = [ordered] @{
        name         = $name
        display_name = $displayName
        version      = $version
        python       = $python
        app_dir      = $appDir
        venv_dir     = $venvDir
        shortcuts    = @($createdShortcuts)
        base_url     = $BaseUrl
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8

    Write-UninstallScript -Name $name -DisplayName $displayName -ToolRoot $toolRoot `
        -ShortcutPaths @($createdShortcuts)
    Register-Uninstall -Name $name -DisplayName $displayName -Version $version `
        -ToolRoot $toolRoot -IconPath $iconPath

    # --- 完了 --------------------------------------------------------------
    Write-Host ''
    Write-Host "  $displayName $version のインストールが完了しました。" -ForegroundColor Green
    Write-Host ''
    if ($wantDesktop) {
        Write-Host "  デスクトップの「$displayName」アイコンから起動できます。" -ForegroundColor White
    } else {
        Write-Host "  スタートメニューの $Publisher > $displayName から起動できます。" -ForegroundColor White
    }

    $notes = @(Get-Prop $m 'notes' @())
    if ($notes.Count -gt 0) {
        Write-Host ''
        foreach ($n in $notes) { Write-Host "  ・$n" -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host '  更新するときは、同じコマンドをもう一度実行してください。' -ForegroundColor DarkGray
    Write-Host '  アンインストールは Windows の「設定 > アプリ」から行えます。' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Lee Lab ツールインストーラ' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan

Test-Environment

$index = Get-RemoteJson "$BaseUrl/tools/index.json"
$entry = Select-Tool $index
Install-Tool $entry
