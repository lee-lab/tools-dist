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
    Write-Host '  Error: ' -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Red
    Write-Host ''
    Write-Host '  If this keeps happening, copy this screen and send it to the developer.' -ForegroundColor DarkGray
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
        Fail "64-bit Windows is required (detected: $arch). Windows on ARM is not supported."
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Fail "PowerShell 5.0 or later is required (detected: $($PSVersionTable.PSVersion))."
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
        Fail "Could not fetch the distribution info: $Url`n         Please check your internet connection. Details: $($_.Exception.Message)"
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }

    # BOM 付きで配信されている場合、先頭の文字が残ると ConvertFrom-Json が失敗する。
    if ($text.Length -gt 0 -and $text[0] -eq [char] 0xFEFF) { $text = $text.Substring(1) }

    try {
        return $text | ConvertFrom-Json
    } catch {
        Fail "The distribution info is malformed: $Url"
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
        Fail "Download failed: $Url`n         Details: $($_.Exception.Message)"
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }

    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $actual = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Remove-Item -Force $Destination -ErrorAction SilentlyContinue
            Fail "The downloaded file is corrupted (checksum mismatch).`n         Please wait a moment and run the command again."
        }
    }
}

function Test-FileHash([string] $Path, [string] $Expected) {
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $Expected.ToLowerInvariant())
}

# ---------------------------------------------------------------------------
# 配布物の復号
#
# 一般公開前のツールは、配布物を暗号化した状態で置いてある。中身を取り出すには
# 開発者から知らされたパスワードが必要になる。
#
# 形式は OpenSSL の `enc -aes-256-cbc -pbkdf2 -md sha256 -salt` と同じ:
#     "Salted__"(8 バイト) + salt(8 バイト) + 暗号文
# 鍵と IV は PBKDF2-HMAC-SHA256 で導出した 48 バイトの先頭 32 / 続く 16 を使う。
# ---------------------------------------------------------------------------

function Unprotect-OpenSslFile {
    param(
        [string] $InPath,
        [string] $OutPath,
        [string] $Password,
        [int] $Iterations
    )
    $inStream = [System.IO.File]::OpenRead($InPath)
    try {
        $header = New-Object byte[] 16
        if ($inStream.Read($header, 0, 16) -ne 16) { throw 'The package file is corrupted.' }
        if ([System.Text.Encoding]::ASCII.GetString($header, 0, 8) -ne 'Salted__') {
            throw 'The package is not in the expected format.'
        }
        $salt = $header[8..15]

        $pwBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
            [byte[]] $pwBytes, [byte[]] $salt, $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try { $keyIv = $kdf.GetBytes(48) } finally { $kdf.Dispose() }

        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $keyIv[0..31]
            $aes.IV  = $keyIv[32..47]

            $decryptor = $aes.CreateDecryptor()
            try {
                $outStream = [System.IO.File]::Create($OutPath)
                try {
                    # 大きな配布物でもメモリに載せずに済むよう、ストリームで処理する。
                    $cs = New-Object System.Security.Cryptography.CryptoStream(
                        $inStream, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read)
                    $cs.CopyTo($outStream)
                    $cs.Dispose()
                } finally {
                    $outStream.Dispose()
                }
            } finally {
                $decryptor.Dispose()
            }
        } finally {
            $aes.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }
}

function Read-InstallPassword {
    # 自動化・検証用の抜け道。通常の利用者は対話入力になる。
    if (-not [string]::IsNullOrEmpty($env:LEELAB_PASSWORD)) { return $env:LEELAB_PASSWORD }

    $secure = Read-Host '  Password' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Unlock-Package {
    param(
        [string] $EncPath,
        [string] $ZipPath,
        [string] $ExpectedSha256,
        [int] $Iterations,
        [string] $DisplayName
    )
    Write-Host ''
    Write-Host "  $DisplayName has not been released publicly yet." -ForegroundColor White
    Write-Host '  Please enter the password you received from the developer.' -ForegroundColor White
    Write-Host ''

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $password = Read-InstallPassword
        $ok = $false
        try {
            Unprotect-OpenSslFile -InPath $EncPath -OutPath $ZipPath `
                -Password $password -Iterations $Iterations
            # パスワードが違うとパディング検証で例外になるのが通常だが、
            # まれに例外にならずに壊れたデータが出てくる。ハッシュで最終確認する。
            $ok = Test-FileHash $ZipPath $ExpectedSha256
        } catch {
            $ok = $false
        } finally {
            $password = $null
        }

        if ($ok) {
            Write-Ok 'Password accepted'
            return
        }

        Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
        if ($attempt -lt 3) {
            Write-Warn "Incorrect password. Please try again. ($(3 - $attempt) attempt(s) left)"
            if (-not [string]::IsNullOrEmpty($env:LEELAB_PASSWORD)) {
                # 環境変数で渡された値が誤っている場合、繰り返しても結果は変わらない。
                break
            }
        }
    }
    Fail "Installation cancelled because the password was not correct.`n         If you do not know the password, please contact the developer."
}

# ---------------------------------------------------------------------------
# uv の導入
# ---------------------------------------------------------------------------

function Install-Uv {
    # すでに PATH にあればそれを使う。
    $existing = Get-Command uv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "uv is already installed ($($existing.Source))"
        return $existing.Source
    }

    # 公式インストーラの既定の配置先。PATH 未反映でもここを直接見る。
    $uvHome = Join-Path $env:USERPROFILE '.local\bin'
    $uvExe  = Join-Path $uvHome 'uv.exe'
    if (Test-Path $uvExe) {
        $env:Path = "$uvHome;$env:Path"
        Write-Ok 'uv is already installed'
        return $uvExe
    }

    Write-Step 'Installing uv (a Python environment manager)...'
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
            Fail 'Failed to install uv.'
        }
    } catch {
        Fail "Failed to install uv.`n         Details: $($_.Exception.Message)"
    } finally {
        Remove-Item -Force $scriptPath -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $uvExe)) {
        Fail 'Failed to install uv (the executable was not found).'
    }
    $env:Path = "$uvHome;$env:Path"
    Write-Ok 'Installed uv'
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
    if ($tools.Count -eq 0) { Fail 'No tools are available for installation.' }

    if (-not [string]::IsNullOrWhiteSpace($Tool)) {
        $match = $tools | Where-Object { $_.name -eq $Tool }
        if (-not $match) {
            $names = ($tools | ForEach-Object { $_.name }) -join ', '
            Fail "There is no tool named '$Tool'. Available tools: $names"
        }
        return @($match)[0]
    }

    if ($tools.Count -eq 1) { return $tools[0] }

    Write-Head 'Select the tool you want to install'
    for ($i = 0; $i -lt $tools.Count; $i++) {
        $t = $tools[$i]
        Write-Host ("    [{0}] {1}" -f ($i + 1), $t.display_name) -ForegroundColor White
        Write-Host ("        {0}" -f (Get-Prop $t 'description' '')) -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $answer = Read-Host '  Enter a number and press Enter (or q to quit)'
        if ($answer -eq 'q') { Write-Host ''; Write-Host '  Cancelled.'; exit 0 }
        $n = 0
        if ([int]::TryParse($answer, [ref] $n) -and $n -ge 1 -and $n -le $tools.Count) {
            return $tools[$n - 1]
        }
        Write-Warn ('Please enter a number between 1 and {0}.' -f $tools.Count)
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
    Write-Ok "Saved your settings and cached data ($saved item(s))"
    return $backup
}

function Restore-UserData([string] $Backup, [string] $AppDir) {
    if ([string]::IsNullOrWhiteSpace($Backup)) { return }
    if (-not (Test-Path $Backup)) { return }
    try {
        Get-ChildItem -Force $Backup | ForEach-Object {
            Copy-Item -Recurse -Force -Path $_.FullName -Destination $AppDir
        }
        Write-Ok 'Restored your settings and cached data'
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
# Uninstalls $DisplayName.
# This file was generated automatically by the installer.
#
# It is run from Windows "Settings > Apps", and can also be run without a
# confirmation prompt:
#     powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Yes
param([switch] `$Yes)

`$ErrorActionPreference = 'SilentlyContinue'

`$toolRoot = '$($ToolRoot.Replace("'", "''"))'
`$shortcuts = @(
$shortcutList
)

Write-Host ''
Write-Host '  Uninstalling $DisplayName.'
Write-Host "  Location: `$toolRoot"
Write-Host ''
if (-not `$Yes) {
    `$answer = Read-Host '  Are you sure? (y/N)'
    if (`$answer -ne 'y' -and `$answer -ne 'Y') {
        Write-Host '  Cancelled.'
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
Write-Host '  Uninstalled.'
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
    if ($null -eq $pkg) { Fail "The distribution info for $displayName is incomplete (no package section)." }
    $pkgUrl = Get-Prop $pkg 'url' ''
    if ([string]::IsNullOrWhiteSpace($pkgUrl)) {
        Fail "$displayName has not been released yet. Please contact the developer."
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
        $installedVersion = Get-Prop $installed 'version' 'unknown'
        Write-Head "$displayName is already installed (version $installedVersion)"
        if ($installedVersion -eq $version) {
            Write-Host "  This is the same as the latest available version." -ForegroundColor DarkGray
        } else {
            Write-Host "  A newer version, $version, is available." -ForegroundColor White
        }
        if (-not $Quiet) {
            Write-Host ''
            $answer = Read-Host '  Reinstall / update now? (Y/n)'
            if ($answer -eq 'n' -or $answer -eq 'N') {
                Write-Host ''; Write-Host '  Cancelled.'; exit 0
            }
        }
    }

    Write-Head "Installing $displayName $version"
    Write-Host "  Install location: $toolRoot" -ForegroundColor DarkGray
    Write-Host ''

    # --- uv と Python ------------------------------------------------------
    $uv = Install-Uv

    $python = Get-Prop $m 'python' '3.12'
    Write-Step "Preparing Python $python..."
    Invoke-Uv $uv @('python', 'install', $python) `
        "Failed to install Python $python."
    Write-Ok "Python $python is ready"

    # --- 本体の取得 --------------------------------------------------------
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        Write-Step "Downloading $displayName..."
        $expectedSha = Get-Prop $pkg 'sha256' ''
        $isEncrypted = [bool] (Get-Prop $pkg 'encrypted' $false)
        $zipPath = Join-Path $work 'package.zip'

        if ($isEncrypted) {
            # 暗号化されている場合、マニフェストのハッシュは復号後の zip のもの。
            # ダウンロード直後には照合できないため、復号のあとで検証する。
            $encPath = Join-Path $work 'package.enc'
            Save-RemoteFile $pkgUrl $encPath
            Write-Ok 'Download complete'
            Unlock-Package -EncPath $encPath -ZipPath $zipPath -ExpectedSha256 $expectedSha `
                -Iterations ([int] (Get-Prop $pkg 'kdf_iterations' 200000)) -DisplayName $displayName
            Remove-Item -Force $encPath -ErrorAction SilentlyContinue
        } else {
            Save-RemoteFile $pkgUrl $zipPath $expectedSha
            Write-Ok 'Download complete'
        }

        # 更新の場合、設定・キャッシュを退避してから展開する。
        $preserve = @(Get-Prop $m 'preserve' @())
        $backup = Save-UserData $appDir $preserve

        Write-Step 'Extracting files...'
        Expand-Package $zipPath $appDir
        Restore-UserData $backup $appDir
        Write-Ok 'Extracted'

        # --- 依存パッケージ -------------------------------------------------
        # PyPI に無い wheel（PyOgg 0.7 など）を先に取得し、--find-links で参照させる。
        $wheelDir = Join-Path $work 'wheels'
        New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null
        $wheels = @(Get-Prop $m 'wheels' @())
        foreach ($w in $wheels) {
            $fileName = Split-Path -Leaf $w
            Save-RemoteFile "$BaseUrl/$w" (Join-Path $wheelDir $fileName)
        }
        if ($wheels.Count -gt 0) { Write-Ok "Fetched bundled components ($($wheels.Count) item(s))" }

        Write-Step 'Creating an isolated Python environment...'
        # --clear が無いと、更新時に「既に存在する」で失敗する。
        # 作り直すことで、旧バージョンで使っていて今は不要になったパッケージが
        # 残り続けるのも防げる。uv はダウンロード済みの wheel をキャッシュから
        # 再利用するため、再作成でも通信は発生しない。
        Invoke-Uv $uv @('venv', '--clear', '--python', $python, $venvDir) 'Failed to create the Python environment.'

        $venvPython = Join-Path $venvDir 'Scripts\python.exe'
        if (-not (Test-Path $venvPython)) { Fail 'Failed to create the Python environment.' }

        $reqName = Get-Prop $m 'requirements' 'requirements.txt'
        $reqPath = Join-Path $appDir $reqName
        if (-not (Test-Path $reqPath)) { Fail "$reqName is missing from the package." }

        Write-Step 'Installing required components... (this takes a few minutes, please wait)'
        Invoke-Uv $uv @(
            'pip', 'install',
            '--python', $venvPython,
            '-r', $reqPath,
            '--find-links', $wheelDir
        ) 'Failed to install the required components.'
        Write-Ok 'Required components installed'

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
        $p = Join-Path $startMenuDir "$displayName (Diagnostic Mode).lnk"
        New-Shortcut -Path $p -Target $venvPython -Arguments $entryScript `
            -WorkingDirectory $appDir -IconPath $iconPath `
            -Description "Starts $displayName with a console window so error messages are visible"
        [void] $createdShortcuts.Add($p)
    }
    Write-Ok "Created shortcuts ($($createdShortcuts.Count) item(s))"

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
    Write-Host "  $displayName $version was installed successfully." -ForegroundColor Green
    Write-Host ''
    if ($wantDesktop) {
        Write-Host "  You can start it from the `"$displayName`" icon on your desktop." -ForegroundColor White
    } else {
        Write-Host "  You can start it from the Start menu: $Publisher > $displayName." -ForegroundColor White
    }

    $notes = @(Get-Prop $m 'notes' @())
    if ($notes.Count -gt 0) {
        Write-Host ''
        foreach ($n in $notes) { Write-Host "  - $n" -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host '  To update later, just run the same command again.' -ForegroundColor DarkGray
    Write-Host '  To uninstall, use Windows Settings > Apps.' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Lee Lab Tool Installer' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan

Test-Environment

$index = Get-RemoteJson "$BaseUrl/tools/index.json"
$entry = Select-Tool $index
Install-Tool $entry
