# インストール処理全体の配線を、実際には何もインストールせずに検証する。
#
# install.ps1 から関数定義だけを取り出したあと、外部に影響する関数
# (uv の導入、パッケージ導入、ショートカット作成、レジストリ登録) を差し替えて
# Install-Tool を動かす。配布物の取得は file:// URL で行うため通信も発生しない。
#
# 実行方法（Windows 上で）:
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-install-flow.ps1

[CmdletBinding()]
param(
    [string] $InstallerPath = ''
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
}
$fixtureDir = Join-Path $PSScriptRoot 'fixtures'
if (-not (Test-Path $fixtureDir)) { $fixtureDir = Join-Path (Split-Path -Parent $InstallerPath) 'fixtures' }

function Check([string] $Name, [bool] $Condition, [string] $Detail = '') {
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red
        $script:Fail++
    }
}

# --- install.ps1 の関数定義を読み込む ---------------------------------------
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) { throw "install.ps1 に構文エラーがあります" }
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }

# Fail は exit 1 するため、失敗経路をこのプロセス内で試すには一時的に差し替える
# 必要がある。元の定義を控えておき、試したあとで戻す。
$failFuncText = @($funcs | Where-Object { $_.Name -eq 'Fail' })[0].Extent.Text

# --- Install-Tool が参照するスクリプト変数 ----------------------------------
$Publisher    = 'Lee Lab'
$RegistryRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$Quiet        = $true
$Tool         = 'flowtest'
$Channel        = 'beta'
$DefaultChannel = 'beta'
$KnownChannels  = @('alpha', 'beta')

$sandbox = Join-Path $env:TEMP ('leelab-flow-' + [System.IO.Path]::GetRandomFileName())
$InstallRoot = Join-Path $sandbox 'installroot'
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

# --- 外部に影響する処理を差し替える -----------------------------------------
$script:UvCalls = New-Object System.Collections.ArrayList
$script:Shortcuts = New-Object System.Collections.ArrayList
$script:Registered = $null

function Install-Uv { return 'C:\stub\uv.exe' }

function Invoke-Uv([string] $UvExe, [string[]] $UvArgs, [string] $FailMessage) {
    [void] $script:UvCalls.Add(($UvArgs -join ' '))
    # `uv venv` 相当のときだけ、仮想環境らしきものを作っておく
    if ($UvArgs[0] -eq 'venv') {
        $target = $UvArgs[$UvArgs.Length - 1]
        $scripts = Join-Path $target 'Scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        Set-Content -Path (Join-Path $scripts 'python.exe')  -Value 'stub'
        Set-Content -Path (Join-Path $scripts 'pythonw.exe') -Value 'stub'
    }
}

function New-Shortcut {
    param([string] $Path, [string] $Target, [string] $Arguments,
          [string] $WorkingDirectory, [string] $IconPath, [string] $Description)
    [void] $script:Shortcuts.Add([pscustomobject] @{
        Path = $Path; Target = $Target; Arguments = $Arguments
        WorkingDirectory = $WorkingDirectory; IconPath = $IconPath
    })
}

function Register-Uninstall {
    param([string] $Name, [string] $DisplayName, [string] $Version,
          [string] $ToolRoot, [string] $IconPath)
    $script:Registered = [pscustomobject] @{ Name = $Name; Version = $Version; ToolRoot = $ToolRoot }
}

try {

# --- 配布物を用意する（暗号化あり）------------------------------------------
$fx = Get-Content -Raw (Join-Path $fixtureDir 'sample.json') | ConvertFrom-Json
$distDir = Join-Path $sandbox 'dist'
New-Item -ItemType Directory -Force -Path (Join-Path $distDir 'tools') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $distDir 'wheels') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $distDir 'releases') | Out-Null
Set-Content -Path (Join-Path $distDir 'wheels\dummy.whl') -Value 'stub wheel'

# 中身のあるアプリ zip を作る
$appSrc = Join-Path $sandbox 'src\flowtest-1.2.3'
New-Item -ItemType Directory -Force -Path $appSrc | Out-Null
Set-Content -Path (Join-Path $appSrc 'main.py') -Value 'print("hello")'
Set-Content -Path (Join-Path $appSrc 'requirements.txt') -Value 'requests'
Set-Content -Path (Join-Path $appSrc 'flowtest.ico') -Value 'not really an icon'
$plainZip = Join-Path $sandbox 'flowtest-1.2.3.zip'
Compress-Archive -Path $appSrc -DestinationPath $plainZip -Force
$zipSha = (Get-FileHash -Path $plainZip -Algorithm SHA256).Hash.ToLowerInvariant()

# 暗号化は install.ps1 側に実装が無いため、検証用に .NET で暗号化する
function Protect-OpenSslFile {
    param([string] $InPath, [string] $OutPath, [string] $Password, [int] $Iterations)
    $salt = New-Object byte[] 8
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($salt)
    $pwBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        [byte[]] $pwBytes, [byte[]] $salt, $Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $keyIv = $kdf.GetBytes(48)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keyIv[0..31]
    $aes.IV  = $keyIv[32..47]
    $out = [System.IO.File]::Create($OutPath)
    $out.Write([System.Text.Encoding]::ASCII.GetBytes('Salted__'), 0, 8)
    $out.Write($salt, 0, 8)
    $cs = New-Object System.Security.Cryptography.CryptoStream(
        $out, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
    $in = [System.IO.File]::OpenRead($InPath)
    $in.CopyTo($cs)
    $in.Dispose(); $cs.Dispose(); $out.Dispose(); $aes.Dispose(); $kdf.Dispose()
}

$encAsset = Join-Path $distDir 'releases\flowtest-1.2.3.zip.enc'
Protect-OpenSslFile -InPath $plainZip -OutPath $encAsset `
    -Password $fx.password -Iterations $fx.kdf_iterations

# file:// の URL を組み立てる
$BaseUrl = 'file:///' + ($distDir -replace '\\', '/')

$manifest = [ordered] @{
    schema = 1; name = 'flowtest'; display_name = 'Flow Test'
    description = '配線検証用'; version = '1.2.3'; python = '3.12'
    package = [ordered] @{
        url = "$BaseUrl/releases/flowtest-1.2.3.zip.enc"
        sha256 = $zipSha
        encrypted = $true
        kdf_iterations = $fx.kdf_iterations
    }
    requirements = 'requirements.txt'; entry = 'main.py'; icon = 'flowtest.ico'
    wheels = @('wheels/dummy.whl')
    preserve = @('settings.json', 'userdata')
    shortcuts = [ordered] @{ desktop = $false; start_menu = $true; console_variant = $true }
    notes = @('This is a tool used for verification only.')
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flowtest.json') -Encoding UTF8

$entry = [pscustomobject] @{ name = 'flowtest'; display_name = 'Flow Test'; manifest = 'tools/flowtest.json' }

# --- 新規インストール --------------------------------------------------------
Write-Host ''
Write-Host '暗号化された配布物の新規インストール' -ForegroundColor Yellow
$env:LEELAB_PASSWORD = $fx.password
Install-Tool $entry | Out-Null

$toolRoot = Join-Path $InstallRoot 'flowtest'
$appDir = Join-Path $toolRoot 'app'
Check 'app extracted'          (Test-Path (Join-Path $appDir 'main.py'))
Check 'archive root stripped'  (-not (Test-Path (Join-Path $appDir 'flowtest-1.2.3')))
Check 'state file written'     (Test-Path (Join-Path $toolRoot 'install.json'))
Check 'uninstaller written'    (Test-Path (Join-Path $toolRoot 'uninstall.ps1'))
Check 'registered as 1.2.3'    ($null -ne $script:Registered -and $script:Registered.Version -eq '1.2.3')

# 注意: Where-Object の結果に直接 .Count を使わないこと。結果が 1 件だけのとき、
# PSCustomObject では PSObject のプロパティ探索が優先されて .Count が取れない。
# 必ず @() で配列に包んでから数えること。
Check 'uv python install called' (@($script:UvCalls | Where-Object { $_ -like 'python install*' }).Count -eq 1)
Check 'uv venv used --clear'     (@($script:UvCalls | Where-Object { $_ -like 'venv --clear*' }).Count -eq 1)
Check 'uv pip install called'    (@($script:UvCalls | Where-Object { $_ -like 'pip install*' }).Count -eq 1)
Check 'wheels passed to pip'     (@($script:UvCalls | Where-Object { $_ -like '*--find-links*' }).Count -eq 1)

# desktop=false を尊重し、start_menu と console_variant の 2 つだけ作ること
Check 'shortcut count honours manifest' (@($script:Shortcuts).Count -eq 2)
Check 'no desktop shortcut'   (@($script:Shortcuts | Where-Object { $_.Path -like '*Desktop*' }).Count -eq 0)
Check 'console variant made'  (@($script:Shortcuts | Where-Object { $_.Path -like '*Diagnostic Mode*' }).Count -eq 1)
$main = $script:Shortcuts | Where-Object { $_.Path -notlike '*Diagnostic Mode*' } | Select-Object -First 1
Check 'shortcut targets pythonw' ($main.Target -like '*pythonw.exe')
Check 'shortcut workdir is app'  ($main.WorkingDirectory -eq $appDir)
Check 'shortcut uses icon'       ($main.IconPath -eq (Join-Path $appDir 'flowtest.ico'))

# --- 更新（ユーザデータの保持）----------------------------------------------
Write-Host ''
Write-Host '更新時のユーザデータ保持' -ForegroundColor Yellow
Set-Content -Path (Join-Path $appDir 'settings.json') -Value 'MY-SETTINGS'
New-Item -ItemType Directory -Force -Path (Join-Path $appDir 'userdata') | Out-Null
Set-Content -Path (Join-Path $appDir 'userdata\notes.txt') -Value 'MY-NOTES'

$script:UvCalls.Clear(); $script:Shortcuts.Clear()
Install-Tool $entry | Out-Null
Check 'settings preserved' ((Get-Content (Join-Path $appDir 'settings.json') -Raw).Trim() -eq 'MY-SETTINGS')
Check 'userdata preserved' ((Get-Content (Join-Path $appDir 'userdata\notes.txt') -Raw).Trim() -eq 'MY-NOTES')
Check 'app still present'  (Test-Path (Join-Path $appDir 'main.py'))

# --- 誤ったパスワード --------------------------------------------------------
Write-Host ''
Write-Host '誤ったパスワードでのインストール' -ForegroundColor Yellow
$env:LEELAB_PASSWORD = 'wrong'
$probe = @"
`$ErrorActionPreference = 'Stop'
`$env:LEELAB_PASSWORD = 'wrong'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$InstallerPath', [ref]`$null, [ref]`$null)
foreach (`$f in `$ast.FindAll({ param(`$n) `$n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, `$false)) {
    Invoke-Expression `$f.Extent.Text
}
Unlock-Package -EncPath '$encAsset' -ZipPath '$(Join-Path $sandbox "nope.zip")' ``
    -ExpectedSha256 '$zipSha' -Iterations $($fx.kdf_iterations) -DisplayName 'Flow Test'
"@
$probeFile = Join-Path $sandbox 'probe.ps1'
[System.IO.File]::WriteAllText($probeFile, $probe, (New-Object System.Text.UTF8Encoding($true)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
Check 'wrong password refuses install' ($LASTEXITCODE -ne 0)

# --- 暗号化なしの配布物も従来どおり動くこと ----------------------------------
Write-Host ''
Write-Host '暗号化されていない配布物' -ForegroundColor Yellow
Remove-Item Env:\LEELAB_PASSWORD -ErrorAction SilentlyContinue
Copy-Item $plainZip (Join-Path $distDir 'releases\flowtest-plain.zip')
$manifest.package = [ordered] @{
    url = "$BaseUrl/releases/flowtest-plain.zip"
    sha256 = $zipSha
}
$manifest.version = '1.2.4'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flowtest.json') -Encoding UTF8

$script:UvCalls.Clear(); $script:Shortcuts.Clear()
Install-Tool $entry | Out-Null
Check 'plain package installs'  (Test-Path (Join-Path $appDir 'main.py'))
Check 'registered as 1.2.4'     ($script:Registered.Version -eq '1.2.4')
Check 'settings still preserved' ((Get-Content (Join-Path $appDir 'settings.json') -Raw).Trim() -eq 'MY-SETTINGS')

# --- リリースチャネル --------------------------------------------------------
# 既定 (beta) は tools/<tool>.json、それ以外は tools/<tool>-<channel>.json を読む。
# index.json の manifest 欄は常に既定チャネルのパスで、alpha はそこから導かれる。
# 配布物 (Release の zip) は両チャネルで共有するため、ここでも同じ zip を指す。
Write-Host ''
Write-Host 'リリースチャネル (alpha)' -ForegroundColor Yellow

$state = Get-Content -Raw (Join-Path $toolRoot 'install.json') | ConvertFrom-Json
Check 'state records the channel' ($state.channel -eq 'beta')

Copy-Item $plainZip (Join-Path $distDir 'releases\flowtest-alpha.zip')
$alphaManifest = [ordered] @{
    schema = 1; name = 'flowtest'; display_name = 'Flow Test'
    description = '配線検証用（alpha）'; version = '1.9.0'; python = '3.12'
    package = [ordered] @{
        url = "$BaseUrl/releases/flowtest-alpha.zip"
        sha256 = $zipSha
    }
    requirements = 'requirements.txt'; entry = 'main.py'; icon = 'flowtest.ico'
    preserve = @('settings.json', 'userdata')
    shortcuts = [ordered] @{ desktop = $false; start_menu = $true; console_variant = $true }
}
$alphaManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flowtest-alpha.json') -Encoding UTF8

# エントリは beta のときと同じもの（manifest 欄は tools/flowtest.json のまま）。
$Channel = 'alpha'
$script:UvCalls.Clear(); $script:Shortcuts.Clear()
$alphaLog = (Install-Tool $entry 6>&1) -join "`n"
$alphaState = Get-Content -Raw (Join-Path $toolRoot 'install.json') | ConvertFrom-Json
Check 'alpha manifest used'        ($script:Registered.Version -eq '1.9.0')
Check 'state records alpha'        ($alphaState.channel -eq 'alpha')
Check 'switching channel is announced' ($alphaLog -like '*alpha channel*') $alphaLog
Check 'settings survive the switch' ((Get-Content (Join-Path $appDir 'settings.json') -Raw).Trim() -eq 'MY-SETTINGS')

# beta に戻す。alpha より版が古くても、指定したチャネルの内容を入れること。
$Channel = 'beta'
$script:UvCalls.Clear(); $script:Shortcuts.Clear()
$backLog = (Install-Tool $entry 6>&1) -join "`n"
$backState = Get-Content -Raw (Join-Path $toolRoot 'install.json') | ConvertFrom-Json
Check 'back on the beta manifest'  ($script:Registered.Version -eq '1.2.4')
Check 'state records beta again'   ($backState.channel -eq 'beta')
Check 'the switch back is announced' ($backLog -like '*beta channel*') $backLog

# alpha のマニフェストがまだ無いツールは、通信エラーではなく「そのチャネルには
# まだ出ていない」と伝えること。
function Fail([string] $Text) { throw "INSTALLER-FAIL: $Text" }
$Channel = 'alpha'
$noAlphaEntry = [pscustomobject] @{ name = 'noalpha'; display_name = 'No Alpha'; manifest = 'tools/noalpha.json' }
$caughtChannel = ''
try { Install-Tool $noAlphaEntry | Out-Null } catch { $caughtChannel = $_.Exception.Message }
Check 'missing alpha manifest is explained' `
    ($caughtChannel -like '*INSTALLER-FAIL*not been released on the alpha channel*') $caughtChannel
Invoke-Expression $failFuncText   # Fail を元に戻す
$Channel = 'beta'

# --- ハッシュ検証付きの依存 (requirements_hashed) -----------------------------
# 監査済みの成果物をピン留めしたファイルは、本体の requirements.txt より「先に」
# 入れなければならない。同じピンが requirements.txt にも書かれており、既に入って
# いる要求に対して pip / uv は何も検証しないため、順序が逆だとハッシュ検証が
# 一度も走らない（valles#67 で実際に踏んだ罠）。
Write-Host ''
Write-Host 'ハッシュ検証付きの依存 (requirements_hashed)' -ForegroundColor Yellow

Set-Content -Path (Join-Path $appSrc 'requirements-audited.txt') -Value @(
    '# 検証用。実際の導入は Invoke-Uv を差し替えているため走らない',
    'audited-package==1.0.0 \',
    '    --hash=sha256:0000000000000000000000000000000000000000000000000000000000000000'
)
$hashedZip = Join-Path $sandbox 'flowtest-1.2.5.zip'
Compress-Archive -Path $appSrc -DestinationPath $hashedZip -Force
Copy-Item $hashedZip (Join-Path $distDir 'releases\flowtest-hashed.zip')
$manifest.package = [ordered] @{
    url = "$BaseUrl/releases/flowtest-hashed.zip"
    sha256 = (Get-FileHash -Path $hashedZip -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest.version = '1.2.5'
$manifest.requirements_hashed = @('requirements-audited.txt')
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flowtest.json') -Encoding UTF8

$script:UvCalls.Clear(); $script:Shortcuts.Clear()
Install-Tool $entry | Out-Null

$hashedIdx = -1
$plainIdx = -1
for ($i = 0; $i -lt $script:UvCalls.Count; $i++) {
    $call = $script:UvCalls[$i]
    if ($call -notlike 'pip install*') { continue }
    if ($call -like '*--require-hashes*') {
        if ($hashedIdx -lt 0) { $hashedIdx = $i }
    } elseif ($plainIdx -lt 0) {
        $plainIdx = $i
    }
}
Check 'two pip installs happen'   (@($script:UvCalls | Where-Object { $_ -like 'pip install*' }).Count -eq 2)
Check 'hashed install uses --require-hashes' ($hashedIdx -ge 0)
Check 'hashed install uses --no-deps' ($hashedIdx -ge 0 -and $script:UvCalls[$hashedIdx] -like '*--no-deps*')
Check 'hashed install names the file' ($hashedIdx -ge 0 -and $script:UvCalls[$hashedIdx] -like '*requirements-audited.txt*')
Check 'hashed install gets --find-links' ($hashedIdx -ge 0 -and $script:UvCalls[$hashedIdx] -like '*--find-links*')
Check 'hashed install runs BEFORE the main one' ($hashedIdx -ge 0 -and $plainIdx -gt $hashedIdx)
Check 'main install has no --require-hashes' ($plainIdx -ge 0 -and $script:UvCalls[$plainIdx] -notlike '*--require-hashes*')

# 配布物に当該ファイルが無いときは黙って飛ばさず、失敗すること。飛ばしてしまうと
# 「検証したつもりで検証していない」インストールが出来上がる。
$script:UvCalls.Clear()
function Fail([string] $Text) { throw "INSTALLER-FAIL: $Text" }
$manifest.version = '1.2.6'
$manifest.requirements_hashed = @('requirements-not-shipped.txt')
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flowtest.json') -Encoding UTF8
$caught = ''
try { Install-Tool $entry | Out-Null } catch { $caught = $_.Exception.Message }
Check 'missing hashed file refuses install' ($caught -like '*INSTALLER-FAIL*requirements-not-shipped.txt*') $caught
Check 'and nothing was installed first'     (@($script:UvCalls | Where-Object { $_ -like 'pip install*' }).Count -eq 0)
Invoke-Expression $failFuncText   # Fail を元に戻す

# --- ネイティブアプリ (kind: native) -----------------------------------------
# ビルド済みの実行ファイルを配る種別。uv / Python / venv を一切通らないこと、
# ショートカットが実行ファイルを直接指し、作業フォルダが app に向くことを確認する。
# MMDAgent-EX はカレントディレクトリを基準にコンテンツを読み書きするため、
# 作業フォルダの指定を落とすと利用者のデータが別の場所に散らばる。
Write-Host ''
Write-Host 'ネイティブアプリ (kind: native)' -ForegroundColor Yellow

$nativeSrc = Join-Path $sandbox 'nativesrc'
New-Item -ItemType Directory -Force -Path (Join-Path $nativeSrc 'AppData') | Out-Null
Set-Content -Path (Join-Path $nativeSrc 'FlowNative.exe')     -Value 'stub executable'
Set-Content -Path (Join-Path $nativeSrc 'FlowNative.mdf')     -Value 'stub config'
Set-Content -Path (Join-Path $nativeSrc 'AppData\data.bin')   -Value 'stub data'
# 配布物は単一の親フォルダで包まない形（複数ルート）。実際の MMDAgent-EX の
# 配布 zip と同じ構造にしておく。
$nativeZip = Join-Path $sandbox 'flownative-2.0.0.zip'
Compress-Archive -Path (Join-Path $nativeSrc '*') -DestinationPath $nativeZip -Force
Copy-Item $nativeZip (Join-Path $distDir 'releases\flownative-2.0.0.zip')

$nativeManifest = [ordered] @{
    schema = 1; name = 'flownative'; display_name = 'Flow Native'
    description = '配線検証用（ネイティブ）'; version = '2.0.0'; kind = 'native'
    package = [ordered] @{
        url = "$BaseUrl/releases/flownative-2.0.0.zip"
        sha256 = (Get-FileHash -Path $nativeZip -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    exe = 'FlowNative.exe'
    shortcuts = [ordered] @{ desktop = $true; start_menu = $true; console_variant = $true }
}
$nativeManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flownative.json') -Encoding UTF8
$nativeEntry = [pscustomobject] @{ name = 'flownative'; display_name = 'Flow Native'; manifest = 'tools/flownative.json' }

$script:UvCalls.Clear(); $script:Shortcuts.Clear()
Install-Tool $nativeEntry | Out-Null

$nativeRoot = Join-Path $InstallRoot 'flownative'
$nativeApp  = Join-Path $nativeRoot 'app'
Check 'native exe extracted'      (Test-Path (Join-Path $nativeApp 'FlowNative.exe'))
Check 'native subdir extracted'   (Test-Path (Join-Path $nativeApp 'AppData\data.bin'))
Check 'native skips uv entirely'  (@($script:UvCalls).Count -eq 0)
Check 'no venv created'           (-not (Test-Path (Join-Path $nativeRoot '.venv')))
Check 'native registered as 2.0.0' ($script:Registered.Version -eq '2.0.0')

# console_variant を要求されていても、ネイティブには別のコンソール版が無いので
# 作らないこと。作ると中身の無い窓が開くだけで、利用者を混乱させる。
Check 'native shortcut count'     (@($script:Shortcuts).Count -eq 2)
Check 'no diagnostic shortcut'    (@($script:Shortcuts | Where-Object { $_.Path -like '*Diagnostic Mode*' }).Count -eq 0)
$nativeMain = $script:Shortcuts | Where-Object { $_.Path -like '*Desktop*' } | Select-Object -First 1
Check 'shortcut targets the exe'  ($nativeMain.Target -eq (Join-Path $nativeApp 'FlowNative.exe'))
Check 'native shortcut workdir'   ($nativeMain.WorkingDirectory -eq $nativeApp)
Check 'icon falls back to the exe' ($nativeMain.IconPath -eq (Join-Path $nativeApp 'FlowNative.exe'))

$nativeState = Get-Content -Raw (Join-Path $nativeRoot 'install.json') | ConvertFrom-Json
Check 'state records the kind'    ($nativeState.kind -eq 'native')
Check 'state has no venv_dir'     (-not (@($nativeState.PSObject.Properties.Name) -contains 'venv_dir'))

# 配布物に実行ファイルが無いときは、ショートカットだけ作って成功したことにせず
# 失敗すること。壊れたショートカットを残す方が利用者には分かりにくい。
function Fail([string] $Text) { throw "INSTALLER-FAIL: $Text" }
$nativeManifest.version = '2.0.1'
$nativeManifest.exe = 'NotShipped.exe'
$nativeManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flownative.json') -Encoding UTF8
$caughtExe = ''
try { Install-Tool $nativeEntry | Out-Null } catch { $caughtExe = $_.Exception.Message }
Check 'missing exe refuses install' ($caughtExe -like '*INSTALLER-FAIL*NotShipped.exe*') $caughtExe

# 将来 kind が増えたとき、古いインストーラが Python ツールとして誤って処理する
# ことのないよう、知らない kind では止まること。
$nativeManifest.exe = 'FlowNative.exe'
$nativeManifest.kind = 'wasm'
$nativeManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $distDir 'tools\flownative.json') -Encoding UTF8
$caughtKind = ''
try { Install-Tool $nativeEntry | Out-Null } catch { $caughtKind = $_.Exception.Message }
Check 'unknown kind refuses install' ($caughtKind -like '*INSTALLER-FAIL*wasm*') $caughtKind
Invoke-Expression $failFuncText   # Fail を元に戻す

} finally {
    Remove-Item Env:\LEELAB_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $script:Pass   Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
