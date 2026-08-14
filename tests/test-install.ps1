# install.ps1 の純粋なロジック部分の単体テスト。
#
# インストーラのエントリポイントを走らせずに検証するため、AST から関数定義だけを
# 取り出して評価する。uv や Python の導入は行わないので、実行しても環境は汚れない。
#
# 実行方法（Windows 上で）:
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test-install.ps1
#
# WSL から実行する場合は、install.ps1 と tools\index.json を Windows 側から読める
# 場所にコピーしてから -InstallerPath / -IndexPath を指定する。

[CmdletBinding()]
param(
    [string] $InstallerPath = '',
    [string] $IndexPath = ''
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'
}
if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    $IndexPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\index.json'
}

function Check([string] $Name, [bool] $Condition, [string] $Detail = '') {
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red
        $script:Fail++
    }
}

# --- 関数定義だけを読み込む -------------------------------------------------
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ("  line " + $_.Extent.StartLineNumber + ": " + $_.Message) -ForegroundColor Red }
    throw "install.ps1 に構文エラーがあります"
}

$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
Write-Host "Loaded $($funcs.Count) functions from install.ps1" -ForegroundColor Cyan
Write-Host ''

$sandbox = Join-Path $env:TEMP ('leelab-test-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

try {

# --- ファイルの文字コード ---------------------------------------------------
# install.ps1 は `irm <url> | iex` で実行される。Invoke-RestMethod は先頭の BOM を
# 文字列に残すため、BOM があると `<#` がブロックコメント開始として認識されず、
# コメント本文がすべてコードとして解釈されてスクリプト全体が壊れる。
#
# BOM を外せるのは、ファイルに非 ASCII バイトが 1 つも無い場合に限られる。BOM が
# 無いと Windows PowerShell 5.1 はシステムのコードページ (日本語環境では cp932) で
# 読むため、非 ASCII の文字が壊れるからである。
Write-Host 'install.ps1 の文字コード' -ForegroundColor Yellow

$bytes = [System.IO.File]::ReadAllBytes($InstallerPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check 'no BOM' (-not $hasBom)

$nonAscii = 0
foreach ($b in $bytes) { if ($b -ge 0x80) { $nonAscii++ } }
Check 'pure ASCII' ($nonAscii -eq 0) "($nonAscii non-ASCII byte(s))"

# irm | iex の経路を忠実に再現する。UTF8Encoding.GetString は BOM を除去しないため、
# Invoke-RestMethod が返す文字列と同じものが得られる。
# (System.Net.WebClient.DownloadString は BOM を除去してしまうので、検証に使わないこと)
$asIrm = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
$irmErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($asIrm, [ref]$null, [ref]$irmErrors) | Out-Null
Check 'parses the way irm | iex sees it' ($irmErrors.Count -eq 0) `
    ("first error: " + $(if ($irmErrors.Count) { "line $($irmErrors[0].Extent.StartLineNumber) $($irmErrors[0].Message)" } else { '' }))

# 逆に、BOM を付けると壊れることも確認しておく（この検査自体が機能している証拠）
$withBom = [string][char]0xFEFF + $asIrm
$bomErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($withBom, [ref]$null, [ref]$bomErrors) | Out-Null
Check 'a BOM would break it (guard is meaningful)' ($bomErrors.Count -gt 0)


# --- Get-Prop ---------------------------------------------------------------
# StrictMode 下でマニフェストの任意項目を安全に読めることを確認する。
Write-Host 'Get-Prop' -ForegroundColor Yellow
$obj = '{"a":"x","b":false,"c":null,"n":0}' | ConvertFrom-Json
Check 'existing string'      ((Get-Prop $obj 'a' 'def') -eq 'x')
Check 'missing -> default'   ((Get-Prop $obj 'zzz' 'def') -eq 'def')
Check 'false is preserved'   ((Get-Prop $obj 'b' $true) -eq $false)
Check 'json null -> default' ((Get-Prop $obj 'c' 'def') -eq 'def')
Check 'zero is preserved'    ((Get-Prop $obj 'n' 99) -eq 0)
Check 'null object'          ((Get-Prop $null 'a' 'def') -eq 'def')

# --- Expand-Package ---------------------------------------------------------
Write-Host ''
Write-Host 'Expand-Package' -ForegroundColor Yellow

# (1) 単一のルートフォルダで包まれた zip は、そのフォルダを取り除く
$src = Join-Path $sandbox 'src1\valles-1.0.0'
New-Item -ItemType Directory -Force -Path $src | Out-Null
Set-Content -Path (Join-Path $src 'main.py') -Value 'print(1)'
New-Item -ItemType Directory -Force -Path (Join-Path $src 'valles') | Out-Null
Set-Content -Path (Join-Path $src 'valles\gui.py') -Value 'x'
$zip1 = Join-Path $sandbox 'one-root.zip'
Compress-Archive -Path $src -DestinationPath $zip1 -Force
$dest1 = Join-Path $sandbox 'out1'
Expand-Package $zip1 $dest1
Check 'single root stripped'    (Test-Path (Join-Path $dest1 'main.py'))
Check 'nested dir kept'         (Test-Path (Join-Path $dest1 'valles\gui.py'))
Check 'root folder not nested'  (-not (Test-Path (Join-Path $dest1 'valles-1.0.0')))

# (2) ルートに複数の要素がある zip は、そのまま展開する
$src2 = Join-Path $sandbox 'src2'
New-Item -ItemType Directory -Force -Path $src2 | Out-Null
Set-Content -Path (Join-Path $src2 'main.py') -Value 'print(2)'
Set-Content -Path (Join-Path $src2 'requirements.txt') -Value 'flet'
$zip2 = Join-Path $sandbox 'multi-root.zip'
Compress-Archive -Path (Join-Path $src2 '*') -DestinationPath $zip2 -Force
$dest2 = Join-Path $sandbox 'out2'
Expand-Package $zip2 $dest2
Check 'multi root kept as-is'   ((Test-Path (Join-Path $dest2 'main.py')) -and (Test-Path (Join-Path $dest2 'requirements.txt')))

# (3) 更新時に、旧バージョンの残骸が残らないこと
Set-Content -Path (Join-Path $dest1 'STALE.txt') -Value 'old'
Expand-Package $zip1 $dest1
Check 'stale file removed'      (-not (Test-Path (Join-Path $dest1 'STALE.txt')))

# --- Save-UserData / Restore-UserData ---------------------------------------
# ここが壊れると、更新のたびに利用者の設定と s2m モデルが消える。
Write-Host ''
Write-Host 'Save-UserData / Restore-UserData (the update path)' -ForegroundColor Yellow

$appDir = Join-Path $sandbox 'app'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
Set-Content -Path (Join-Path $appDir 'main.py') -Value 'OLD VERSION'
Set-Content -Path (Join-Path $appDir 'settings.json') -Value '{"host":"avatar-01"}'
New-Item -ItemType Directory -Force -Path (Join-Path $appDir 'contents') | Out-Null
Set-Content -Path (Join-Path $appDir 'contents\cache.json') -Value '{"cached":true}'
New-Item -ItemType Directory -Force -Path (Join-Path $appDir 'valles\s2m\cache') | Out-Null
Set-Content -Path (Join-Path $appDir 'valles\s2m\cache\model.pth') -Value 'PRETEND 119MB MODEL'

$preserve = @('settings.json', 'contents', 'valles/s2m/cache')
$backup = Save-UserData $appDir $preserve
Check 'backup created' ($null -ne $backup -and (Test-Path $backup))

# 更新を模擬する: app フォルダはまるごと置き換わる
Expand-Package $zip1 $appDir
Check 'app replaced' ((Get-Content (Join-Path $appDir 'main.py') -Raw).Trim() -eq 'print(1)')
Check 'settings gone before restore' (-not (Test-Path (Join-Path $appDir 'settings.json')))

Restore-UserData $backup $appDir
Check 'settings.json restored' `
    ((Get-Content (Join-Path $appDir 'settings.json') -Raw).Trim() -eq '{"host":"avatar-01"}')
Check 'contents/ restored' `
    (Test-Path (Join-Path $appDir 'contents\cache.json'))
Check 'nested s2m model restored' `
    ((Get-Content (Join-Path $appDir 'valles\s2m\cache\model.pth') -Raw).Trim() -eq 'PRETEND 119MB MODEL')
Check 'new version still in place' `
    ((Get-Content (Join-Path $appDir 'main.py') -Raw).Trim() -eq 'print(1)')
Check 'backup cleaned up' (-not (Test-Path $backup))

# 新規インストール（旧 app フォルダが無い）でも落ちないこと
$fresh = Save-UserData (Join-Path $sandbox 'does-not-exist') $preserve
Check 'no app dir -> null' ($null -eq $fresh)
Restore-UserData $null $appDir
Check 'restore of null is a no-op' (Test-Path (Join-Path $appDir 'main.py'))

# preserve を宣言していないツールでも落ちないこと
$none = Save-UserData $appDir @()
Check 'empty preserve list -> null' ($null -eq $none)

# --- Write-UninstallScript --------------------------------------------------
Write-Host ''
Write-Host 'Write-UninstallScript' -ForegroundColor Yellow

$toolRoot = Join-Path $sandbox 'toolroot'
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
$shortcuts = @('C:\Users\test\Desktop\Valles.lnk', 'C:\Users\test\Start Menu\Valles.lnk')
Write-UninstallScript -Name 'valles' -DisplayName 'Valles' -ToolRoot $toolRoot -ShortcutPaths $shortcuts

$uninst = Join-Path $toolRoot 'uninstall.ps1'
Check 'uninstall.ps1 written' (Test-Path $uninst)

$ue = $null
[System.Management.Automation.Language.Parser]::ParseFile($uninst, [ref]$null, [ref]$ue) | Out-Null
Check 'uninstall.ps1 parses' ($ue.Count -eq 0) ("errors: " + ($ue | ForEach-Object { $_.Message }))

# BOM が無いと日本語環境で文字化けして構文エラーになる
$bytes = [System.IO.File]::ReadAllBytes($uninst)
Check 'uninstall.ps1 has UTF-8 BOM' ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

$text = [System.IO.File]::ReadAllText($uninst, [System.Text.Encoding]::UTF8)
Check 'tool root embedded'   ($text -like "*$toolRoot*")
Check 'both shortcuts listed' (($text -like '*Desktop\Valles.lnk*') -and ($text -like '*Start Menu\Valles.lnk*'))
Check 'registry key embedded' ($text -like '*LeeLab-valles*')

# ショートカットを 1 つも作らない構成でも、正しいスクリプトが生成されること
$toolRoot2 = Join-Path $sandbox 'toolroot2'
New-Item -ItemType Directory -Force -Path $toolRoot2 | Out-Null
Write-UninstallScript -Name 'x' -DisplayName 'X' -ToolRoot $toolRoot2 -ShortcutPaths @()
$ue2 = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $toolRoot2 'uninstall.ps1'), [ref]$null, [ref]$ue2) | Out-Null
Check 'no shortcuts -> still valid' ($ue2.Count -eq 0)

# --- Unprotect-OpenSslFile --------------------------------------------------
# 配布物の暗号化は CI 側 (openssl) とインストーラ側 (.NET) で別実装になるため、
# 両者が食い違うと「誰も開けない配布物」が出来上がる。固定データで互換性を守る。
Write-Host ''
Write-Host 'Unprotect-OpenSslFile (openssl との相互運用)' -ForegroundColor Yellow

$fixtureDir = Join-Path $PSScriptRoot 'fixtures'
if (-not (Test-Path $fixtureDir)) { $fixtureDir = Join-Path (Split-Path -Parent $InstallerPath) 'fixtures' }
$fx = Get-Content -Raw (Join-Path $fixtureDir 'sample.json') | ConvertFrom-Json
$encFile = Join-Path $fixtureDir 'sample.enc'
$decFile = Join-Path $sandbox 'decrypted.txt'

Unprotect-OpenSslFile -InPath $encFile -OutPath $decFile `
    -Password $fx.password -Iterations $fx.kdf_iterations
$decHash = (Get-FileHash -Path $decFile -Algorithm SHA256).Hash.ToLowerInvariant()
Check 'correct password decrypts'  ($decHash -eq $fx.plaintext_sha256) "got $decHash"
Check 'decrypted size matches'     ((Get-Item $decFile).Length -eq $fx.plaintext_size)

# 誤ったパスワードは、パディング検証の例外か、ハッシュ不一致で検出できること
$wrongDetected = $false
try {
    Unprotect-OpenSslFile -InPath $encFile -OutPath (Join-Path $sandbox 'wrong.txt') `
        -Password 'not-the-password' -Iterations $fx.kdf_iterations
    $h = (Get-FileHash -Path (Join-Path $sandbox 'wrong.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrongDetected = ($h -ne $fx.plaintext_sha256)
} catch { $wrongDetected = $true }
Check 'wrong password detected' $wrongDetected

# 反復回数が食い違っても検出できること（マニフェストと CI の設定ずれ）
$iterDetected = $false
try {
    Unprotect-OpenSslFile -InPath $encFile -OutPath (Join-Path $sandbox 'iter.txt') `
        -Password $fx.password -Iterations 100000
    $h = (Get-FileHash -Path (Join-Path $sandbox 'iter.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    $iterDetected = ($h -ne $fx.plaintext_sha256)
} catch { $iterDetected = $true }
Check 'iteration mismatch detected' $iterDetected

# 暗号化されていないファイルを渡された場合
$plainFile = Join-Path $sandbox 'notencrypted.bin'
Set-Content -Path $plainFile -Value 'this is not an openssl container at all'
$magicDetected = $false
try {
    Unprotect-OpenSslFile -InPath $plainFile -OutPath (Join-Path $sandbox 'x.bin') `
        -Password 'whatever' -Iterations $fx.kdf_iterations
} catch { $magicDetected = $true }
Check 'non-encrypted input rejected' $magicDetected

# --- Unlock-Package ---------------------------------------------------------
Write-Host ''
Write-Host 'Unlock-Package' -ForegroundColor Yellow

$unlocked = Join-Path $sandbox 'unlocked.txt'
$env:LEELAB_PASSWORD = $fx.password
Unlock-Package -EncPath $encFile -ZipPath $unlocked -ExpectedSha256 $fx.plaintext_sha256 `
    -Iterations $fx.kdf_iterations -DisplayName 'Test'
Check 'unlock with correct password' (Test-Path $unlocked)
Check 'unlocked content matches' `
    ((Get-FileHash -Path $unlocked -Algorithm SHA256).Hash.ToLowerInvariant() -eq $fx.plaintext_sha256)

# 誤ったパスワードでは Fail が呼ばれて終了する。Fail は exit するため、
# ここでは別プロセスに実行させて終了コードを確認する。
$env:LEELAB_PASSWORD = 'definitely-wrong'
$probe = @"
`$ErrorActionPreference = 'Stop'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$InstallerPath', [ref]`$null, [ref]`$null)
foreach (`$f in `$ast.FindAll({ param(`$n) `$n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, `$false)) {
    Invoke-Expression `$f.Extent.Text
}
Unlock-Package -EncPath '$encFile' -ZipPath '$(Join-Path $sandbox "fail.txt")' ``
    -ExpectedSha256 '$($fx.plaintext_sha256)' -Iterations $($fx.kdf_iterations) -DisplayName 'Test'
"@
$probeFile = Join-Path $sandbox 'probe.ps1'
[System.IO.File]::WriteAllText($probeFile, $probe, (New-Object System.Text.UTF8Encoding($true)))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeFile | Out-Null
Check 'wrong password exits with error' ($LASTEXITCODE -ne 0)
Check 'no output file left behind'      (-not (Test-Path (Join-Path $sandbox 'fail.txt')))
Remove-Item Env:\LEELAB_PASSWORD -ErrorAction SilentlyContinue

# --- Select-Tool ------------------------------------------------------------
Write-Host ''
Write-Host 'Select-Tool' -ForegroundColor Yellow
# 配布中の全ツールが、名前を指定して選べること。index.json にツールを足したら
# ここも増やす（マニフェストの綴り違いはこの検証で落ちる）。
$index = Get-Content -Raw $IndexPath | ConvertFrom-Json
foreach ($t in $index.tools) {
    $Tool = $t.name
    Check "named tool selected ($($t.name))" ((Select-Tool $index).name -eq $t.name)
}

# ツールが 1 つだけなら、聞かずに自動選択する。実際の index.json の件数に依存
# させると、ツールを足した瞬間に入力待ちで止まるテストになるため、ここでは
# 1 件だけの索引を組み立てて確かめる。
$Tool = ''
$soloIndex = [pscustomobject] @{
    schema = 1
    tools  = @([pscustomobject] @{ name = 'solo'; display_name = 'Solo'; manifest = 'tools/solo.json' })
}
Check 'single tool auto-selected' ((Select-Tool $soloIndex).name -eq 'solo')

} finally {
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $script:Pass   Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
