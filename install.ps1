<#
    Lee Lab shared tool installer

    Usage (for end users):
        Open PowerShell and paste the single line below.

        irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex

    To install a specific tool without the menu:
        $env:LEELAB_TOOL = "valles"
        irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex

    Administrator rights are not needed. Everything goes under %LOCALAPPDATA%\LeeLab\.

    What this script does:
        1. Fetch the tool from GitHub Releases, verify its SHA256, and extract it
        2. For a Python tool, install uv (a Python environment manager), let it
           provide the Python the tool needs (the user never installs Python),
           and build a dedicated virtual environment with the dependencies
        3. Create shortcuts on the desktop and in the Start menu

    Tools come in two kinds, chosen by "kind" in the tool manifest:
        python   (the default) started by the interpreter in its own venv
        native   a prebuilt Windows executable, started directly

    Runs on Windows PowerShell 5.1 (the default on Windows 10 / 11).
#>

# NOTE: This file must stay pure ASCII with NO byte order mark.
#
# It is executed both as a file and, more importantly, through
# `irm <url> | iex`. Invoke-RestMethod keeps a leading BOM in the string it
# returns, and a BOM in front of `<#` stops PowerShell from recognising the
# block comment, so every comment line is then parsed as code and the whole
# script fails. (System.Net.WebClient strips the BOM, so testing through that
# class hides the problem -- test with Invoke-RestMethod.)
#
# Dropping the BOM is only safe while the file has no non-ASCII bytes at all:
# without a BOM, Windows PowerShell 5.1 decodes the file using the system code
# page (cp932 on Japanese Windows), which would corrupt any non-ASCII text.
# Keeping the file ASCII-only makes both paths work. Write comments in English.
#
# tests/test-install.ps1 enforces this.

[CmdletBinding()]
param(
    # Name of the tool to install. When omitted, a menu is shown.
    [string] $Tool = '',

    # Base URL of the distribution repository. Change only for forks or testing.
    [string] $BaseUrl = '',

    # Root install location. Defaults to %LOCALAPPDATA%\LeeLab
    [string] $InstallRoot = '',

    # Proceed without asking for confirmation (for automated updates).
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Older .NET defaults leave TLS 1.2 disabled, which breaks connections to GitHub.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# The Invoke-WebRequest progress bar is extremely slow on 5.1, so suppress it.
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Constants
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
# Console output helpers
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

# Under StrictMode, reading a property that does not exist throws, so optional
# manifest fields must be read through this helper.
function Get-Prop($Object, [string] $Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

function Test-Environment {
    # The wheels we ship and PyTorch are for 64-bit x86 Windows only.
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
# Downloading
# ---------------------------------------------------------------------------

function Get-RemoteJson([string] $Url) {
    # The server does not necessarily send a charset in Content-Type. Without one,
    # Invoke-WebRequest decodes using the default code page and any non-ASCII text
    # in the manifest is mangled. Read it as UTF-8 explicitly.
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

    # If the file is served with a BOM, a leading U+FEFF makes ConvertFrom-Json fail.
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
        # Unlike Invoke-WebRequest, WebClient streams straight to disk, so it does
        # not hold hundreds of megabytes in memory. It also follows redirects.
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
# Decrypting the package
#
# Tools that have not been released publicly are stored encrypted. Extracting them
# requires the password the developer gave to the user.
#
# The format matches OpenSSL's `enc -aes-256-cbc -pbkdf2 -md sha256 -salt`:
#     "Salted__" (8 bytes) + salt (8 bytes) + ciphertext
# The key and IV are the first 32 and next 16 bytes of a 48-byte PBKDF2-HMAC-SHA256
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
                    # Stream it so that large packages never sit in memory.
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
    # Escape hatch for automation and testing. Real users type it in.
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
            # A wrong password normally fails PKCS7 padding validation, but it can
            # occasionally produce garbage instead. Confirm with the hash.
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
                # A wrong value passed via the environment will not change on retry.
                break
            }
        }
    }
    Fail "Installation cancelled because the password was not correct.`n         If you do not know the password, please contact the developer."
}

# ---------------------------------------------------------------------------
# Installing uv
# ---------------------------------------------------------------------------

function Install-Uv {
    # Use it if it is already on PATH.
    $existing = Get-Command uv -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "uv is already installed ($($existing.Source))"
        return $existing.Source
    }

    # Default location used by the official installer. Look here even if PATH is stale.
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
        # astral.sh does not always declare the script as text, in which case
        # Invoke-WebRequest returns a byte array rather than a string.
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }

        # The official installer has its own error handling, so run it in a separate
        # process to keep it clear of our StrictMode / ErrorActionPreference.
        # (Loading it into this scope with Invoke-Expression misbehaves.)
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

# Runs an external command and returns stdout and stderr together.
#
# uv, like many commands, writes progress to stderr. With $ErrorActionPreference
# left at 'Stop', PowerShell treats that as a terminating NativeCommandError and
# aborts the script in the middle of a command that is working fine.
# So relax the setting just for the call and judge success by the exit code.
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
    # Capture stderr too, and show it only on failure (success logs are noise).
    $output = Invoke-Native $UvExe $UvArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Fail $FailMessage
    }
}

# ---------------------------------------------------------------------------
# Shortcuts
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
    # settings.json and the content caches are saved relative to the current
    # directory, so the working directory must be set. Getting this wrong writes
    # the user's settings somewhere else.
    $lnk.WorkingDirectory = $WorkingDirectory
    if ($IconPath -and (Test-Path $IconPath)) { $lnk.IconLocation = $IconPath }
    $lnk.Description = $Description
    $lnk.Save()
}

# ---------------------------------------------------------------------------
# Tool selection
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
# Extraction (strips a single root folder inside the zip)
# ---------------------------------------------------------------------------

function Expand-Package([string] $ZipPath, [string] $Destination) {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        # Expand-Archive drives the extraction from PowerShell one entry at a
        # time, which a native tool's package (hundreds of megabytes, thousands
        # of files) makes unbearably slow. The .NET call below does the same
        # work in one step. Both paths must be absolute: the .NET API resolves a
        # relative path against the process working directory, which is not
        # necessarily the one PowerShell shows.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory(
            [System.IO.Path]::GetFullPath($ZipPath),
            [System.IO.Path]::GetFullPath($staging))

        # When the zip is wrapped in one folder (valles-1.0.0/ and the like),
        # place the contents of that folder into the destination.
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
# Preserving user data across updates
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
# Registering uninstall info (so it appears in Windows "Apps & features")
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

# This script lives inside the tool folder, so hand the deletion to another process.
Start-Process -WindowStyle Hidden powershell.exe -ArgumentList @(
    '-NoProfile', '-Command',
    "Start-Sleep -Seconds 2; Remove-Item -Recurse -Force '`$toolRoot'"
)

Write-Host ''
Write-Host '  Uninstalled.'
Write-Host ''
"@
    $path = Join-Path $ToolRoot 'uninstall.ps1'
    # Write UTF-8 with a BOM so Windows PowerShell 5.1 reads it reliably.
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $content, $utf8Bom)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Install-Tool($Entry) {
    $name = $Entry.name
    $manifestUrl = "$BaseUrl/$(Get-Prop $Entry 'manifest' "tools/$name.json")"
    $m = Get-RemoteJson $manifestUrl

    $displayName = Get-Prop $m 'display_name' $name
    $version     = Get-Prop $m 'version' '0.0.0'
    # 'python' is the default so that manifests written before native tools
    # existed keep working untouched.
    $kind        = Get-Prop $m 'kind' 'python'
    if ($kind -ne 'python' -and $kind -ne 'native') {
        Fail "This installer does not understand how to install $displayName (unknown kind: $kind). Please contact the developer."
    }
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

    # --- Check for an existing installation --------------------------------
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

    # --- uv and Python (Python tools only) ---------------------------------
    # A native tool ships its own runtime, so none of this applies to it.
    $uv = $null
    $python = ''
    if ($kind -eq 'python') {
        $uv = Install-Uv

        $python = Get-Prop $m 'python' '3.12'
        Write-Step "Preparing Python $python..."
        Invoke-Uv $uv @('python', 'install', $python) `
            "Failed to install Python $python."
        Write-Ok "Python $python is ready"
    }

    # --- Fetch the package -------------------------------------------------
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        Write-Step "Downloading $displayName..."
        $expectedSha = Get-Prop $pkg 'sha256' ''
        $isEncrypted = [bool] (Get-Prop $pkg 'encrypted' $false)
        $zipPath = Join-Path $work 'package.zip'

        if ($isEncrypted) {
            # When encrypted, the manifest hash is that of the decrypted zip, so it
            # cannot be checked on download. Verify it after decryption instead.
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

        # On update, move the settings and caches aside before extracting.
        $preserve = @(Get-Prop $m 'preserve' @())
        $backup = Save-UserData $appDir $preserve

        Write-Step 'Extracting files...'
        Expand-Package $zipPath $appDir
        Restore-UserData $backup $appDir
        Write-Ok 'Extracted'

        # --- Dependencies ---------------------------------------------------
        # Only a Python tool has any. A native package already carries every
        # library it needs, so there is nothing to do for one here.
        if ($kind -eq 'python') {
            # Fetch the wheels this repository supplies and point pip at them. Two
            # kinds live there: packages PyPI does not carry at all (PyOgg 0.7), and
            # mirrors of audited artifacts, so that a hash-pinned install below can
            # be satisfied even if the upstream project disappears.
            $wheelDir = Join-Path $work 'wheels'
            New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null
            $wheels = @(Get-Prop $m 'wheels' @())
            foreach ($w in $wheels) {
                $fileName = Split-Path -Leaf $w
                Save-RemoteFile "$BaseUrl/$w" (Join-Path $wheelDir $fileName)
            }
            if ($wheels.Count -gt 0) { Write-Ok "Fetched bundled components ($($wheels.Count) item(s))" }

            Write-Step 'Creating an isolated Python environment...'
            # Without --clear this fails on update because the environment exists.
            # Recreating it also stops packages that an older version needed, and that
            # are no longer required, from lingering. uv reuses already-downloaded
            # wheels from its cache, so recreating costs no network traffic.
            Invoke-Uv $uv @('venv', '--clear', '--python', $python, $venvDir) 'Failed to create the Python environment.'

            $venvPython = Join-Path $venvDir 'Scripts\python.exe'
            if (-not (Test-Path $venvPython)) { Fail 'Failed to create the Python environment.' }

            $reqName = Get-Prop $m 'requirements' 'requirements.txt'
            $reqPath = Join-Path $appDir $reqName
            if (-not (Test-Path $reqPath)) { Fail "$reqName is missing from the package." }

            # Hash-pinned requirement files, installed BEFORE the main one. A tool
            # ships one for a dependency whose exact artifact was audited (Valles
            # does for pywebrtc-audio, lee-lab/valles#67): both pip and uv verify
            # hashes per FILE and all-or-nothing, so an audited pin cannot just be
            # annotated inside requirements.txt -- everything else there would then
            # need a hash too, and some of it cannot supply one (PyOgg comes from
            # the wheel link below). It has to live in a file of its own.
            #
            # The ORDER is what makes the verification real. The same pin is
            # repeated in the main requirements.txt so that a plain developer
            # install works without this step, and a requirement that is already
            # satisfied is never verified again -- run the main file first and the
            # hash check silently passes over an unverified package.
            #
            # --no-deps because hash mode demands a hash for every package it would
            # install, dependencies included; those belong to the main file.
            $hashedReqs = @(Get-Prop $m 'requirements_hashed' @())
            foreach ($hashedReq in $hashedReqs) {
                $hashedPath = Join-Path $appDir $hashedReq
                if (-not (Test-Path $hashedPath)) {
                    Fail "$hashedReq is missing from the package. Please contact the developer."
                }
                Write-Step "Checking a verified component ($hashedReq)..."
                Invoke-Uv $uv @(
                    'pip', 'install',
                    '--python', $venvPython,
                    '--no-deps',
                    '--require-hashes',
                    '-r', $hashedPath,
                    '--find-links', $wheelDir
                ) "A component did not match its expected contents ($hashedReq). Please contact the developer."
                Write-Ok "Verified $hashedReq"
            }

            Write-Step 'Installing required components... (this takes a few minutes, please wait)'
            Invoke-Uv $uv @(
                'pip', 'install',
                '--python', $venvPython,
                '-r', $reqPath,
                '--find-links', $wheelDir
            ) 'Failed to install the required components.'
            Write-Ok 'Required components installed'
        }

    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }

    # --- Shortcuts ---------------------------------------------------------
    $iconName = Get-Prop $m 'icon' ''
    $iconPath = ''
    if ($iconName) {
        $candidate = Join-Path $appDir $iconName
        if (Test-Path $candidate) { $iconPath = $candidate }
    }

    # What a shortcut points at depends on the kind: a native tool is started
    # directly, a Python tool through the interpreter in its own environment.
    # $consoleTarget stays empty when the tool has no useful console variant.
    $consoleTarget = ''
    if ($kind -eq 'native') {
        $exeName = Get-Prop $m 'exe' ''
        if ([string]::IsNullOrWhiteSpace($exeName)) {
            Fail "The distribution info for $displayName is incomplete (no exe entry). Please contact the developer."
        }
        $launchTarget = Join-Path $appDir $exeName
        if (-not (Test-Path $launchTarget)) {
            Fail "$exeName is missing from the package. Please contact the developer."
        }
        $launchArgs = Get-Prop $m 'args' ''
        # A native tool usually carries its own icon, so fall back to the
        # executable when the manifest does not name an icon file.
        if (-not $iconPath) { $iconPath = $launchTarget }
    } else {
        $launchArgs = Get-Prop $m 'entry' 'main.py'
        $consoleTarget = $venvPython
        $launchTarget = Join-Path $venvDir 'Scripts\pythonw.exe'
        if (-not (Test-Path $launchTarget)) { $launchTarget = $venvPython }
    }

    $shortcutOpts = Get-Prop $m 'shortcuts'
    $wantDesktop  = [bool] (Get-Prop $shortcutOpts 'desktop' $true)
    $wantStart    = [bool] (Get-Prop $shortcutOpts 'start_menu' $true)
    $wantConsole  = [bool] (Get-Prop $shortcutOpts 'console_variant' $false)
    # Asking for a console variant of a tool that has none would produce a
    # shortcut that shows an empty window, which is worse than no shortcut.
    if ($wantConsole -and [string]::IsNullOrWhiteSpace($consoleTarget)) { $wantConsole = $false }

    $startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$Publisher"
    $createdShortcuts = New-Object System.Collections.ArrayList

    if ($wantDesktop) {
        $p = Join-Path ([Environment]::GetFolderPath('Desktop')) "$displayName.lnk"
        New-Shortcut -Path $p -Target $launchTarget -Arguments $launchArgs `
            -WorkingDirectory $appDir -IconPath $iconPath -Description $displayName
        [void] $createdShortcuts.Add($p)
    }
    if ($wantStart) {
        $p = Join-Path $startMenuDir "$displayName.lnk"
        New-Shortcut -Path $p -Target $launchTarget -Arguments $launchArgs `
            -WorkingDirectory $appDir -IconPath $iconPath -Description $displayName
        [void] $createdShortcuts.Add($p)
    }
    if ($wantConsole) {
        # For troubleshooting: keeps the console open so errors stay readable.
        $p = Join-Path $startMenuDir "$displayName (Diagnostic Mode).lnk"
        New-Shortcut -Path $p -Target $consoleTarget -Arguments $launchArgs `
            -WorkingDirectory $appDir -IconPath $iconPath `
            -Description "Starts $displayName with a console window so error messages are visible"
        [void] $createdShortcuts.Add($p)
    }
    Write-Ok "Created shortcuts ($($createdShortcuts.Count) item(s))"

    # --- Record the state --------------------------------------------------
    $state = [ordered] @{
        name         = $name
        display_name = $displayName
        version      = $version
        kind         = $kind
        app_dir      = $appDir
        shortcuts    = @($createdShortcuts)
        base_url     = $BaseUrl
    }
    if ($kind -eq 'python') {
        $state['python']   = $python
        $state['venv_dir'] = $venvDir
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8

    Write-UninstallScript -Name $name -DisplayName $displayName -ToolRoot $toolRoot `
        -ShortcutPaths @($createdShortcuts)
    Register-Uninstall -Name $name -DisplayName $displayName -Version $version `
        -ToolRoot $toolRoot -IconPath $iconPath

    # --- Done --------------------------------------------------------------
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
# Entry point
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   Lee Lab Tool Installer' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan

Test-Environment

$index = Get-RemoteJson "$BaseUrl/tools/index.json"
$entry = Select-Tool $index
Install-Tool $entry
