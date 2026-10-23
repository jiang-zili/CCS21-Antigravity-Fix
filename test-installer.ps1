#requires -Version 5.1
param([string]$NodeExe,[string]$BackendUrl,[string]$TestRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if (-not $TestRoot) { $TestRoot=Join-Path $PSScriptRoot 'AgentOutput\installer-tests' }
$TestRoot=[IO.Path]::GetFullPath($TestRoot)
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$testBackendUrl=$BackendUrl
. (Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.ps1')
$BackendUrl=$testBackendUrl
# Keep this installer regression independent of the developer's live IDE/backends.
function Get-CimInstance { return @() }
$results=New-Object 'System.Collections.Generic.List[string]'
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $results.Add($Message) }
function ExpectFailure([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert $failed $Message
}
$fixtureRoot=Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
$ccsRoot=Join-Path $fixtureRoot 'Custom tools & (portable) !'
$theia=Join-Path $ccsRoot 'ccs\theia'
New-Item -ItemType Directory -Force -Path (Join-Path $theia 'resources'),(Join-Path $ccsRoot 'ccs\tools\node') | Out-Null
[IO.File]::WriteAllText((Join-Path $theia 'ccstudio.exe'),'fixture; never executed')
Copy-Item -LiteralPath $NodeExe -Destination (Join-Path $ccsRoot 'ccs\tools\node\node.exe')
$customExe=Join-Path $theia 'ccstudio.exe'
Assert ((Resolve-CcsExecutable $ccsRoot).Executable -eq $customExe) 'Arbitrary CCS root without a ccs21 folder name'
Assert ((Resolve-CcsExecutable $theia).Executable -eq $customExe) 'Accept executable, theia directory and installation root'
$unicode=[string][char]0x4E2D+[char]0x6587
$profile=Join-Path $fixtureRoot ($unicode+' profile & [x] !\non-numeric name')
$extension=Join-Path $profile 'theia\deployedPlugins\arbitrary-plugin-folder\extension'
New-Item -ItemType Directory -Force -Path (Join-Path $extension 'dist') | Out-Null
$entry=Join-Path $extension 'dist\entry.js'
$source='class Renderer { async renderIframe(view, server, options) { const url = this.buildIframeUrl(server, options); return this.renderWebviewHtml(view, server, url, options); } }'
$utf8Bom=New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText($entry,$source,$utf8Bom)
[IO.File]::WriteAllText((Join-Path $extension 'package.json'),'{"publisher":"google","name":"google-antigravity","version":"99.42.0-future","main":"./dist/entry"}')
$before=FileHash $entry
$found=@(Find-AntigravityExtensions @($profile))
Assert ($found.Count -eq 1 -and $found[0].Entry -eq $entry) 'Unicode, spaces, brackets, ampersands, non-numeric profiles and package.main'
Assert (@(Get-LaunchPath ('ccstudio.exe --user-data-dir="'+$profile+'" --plugins "'+$extension+'"') 'user-data-dir')[0] -eq $profile) 'Quoted custom launch profile detection'
Assert (@(Get-LaunchPath ('ccstudio.exe --plugins "'+$extension+'"') 'plugins')[0] -eq $extension) 'Space-separated plugin launch option'
ExpectFailure { Select-RepairTarget @($found[0],$found[0]) 'test' 'Directory' -Headless } 'Multiple candidates never silently select a copy'
ExpectFailure { GetRenderPlan ($source+$source) } 'Duplicate renderers rejected'
ExpectFailure { GetRenderPlan ($source.Replace('buildIframeUrl','changedProtocol')) } 'Changed renderer protocol rejected'
$planned=GetRenderPlan $source
Assert (-not $planned.replacement.Contains('async async')) 'Existing async renderer retained without duplicate async'
$scriptFile=Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.ps1'
$reports=Join-Path $fixtureRoot 'reports'
function RunRepair([string[]]$Extra) {
    $params=@{ ExtensionDir=$extension; CcsExe=$customExe; ReportDir=$reports; NoRestart=$true; NonInteractive=$true }
    if ($BackendUrl) { $params.BackendUrl=$BackendUrl }
    foreach ($flag in $Extra) { $params[$flag]=$true }
    & $scriptFile @params
}
RunRepair @('CheckOnly')
Assert ((FileHash $entry) -eq $before -and -not (Test-Path -LiteralPath $reports)) 'CheckOnly leaves installation and report directories untouched'
RunRepair @()
$patchedHash=FileHash $entry
Assert ($patchedHash -ne $before) 'Install modifies the intended nested entry'
Assert (([IO.File]::ReadAllText($entry).Split(@('CCS21_AG_ADAPTER_START'),[StringSplitOptions]::None)).Count -eq 2) 'Exactly one renderer injection'
$firstReport=Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $reports -Filter 'repair-*.json') | Select-Object -Last 1).FullName -Raw | ConvertFrom-Json
Assert (-not $firstReport.uiVerified -and $firstReport.ccsExecutable -eq $customExe) 'Report separates install, backend and UI evidence'
Assert ($firstReport.backup.Length -gt 260) 'Backup paths longer than traditional MAX_PATH are supported'
if ($BackendUrl) { Assert $firstReport.backendVerified 'Live fixture backend structure verified' }
# Exercise the v1.2 installed-manifest upgrade contract with a previous helper.
$installedManifest=Join-Path $extension 'AgentOutput\CCS21-Antigravity\installed.json'
$installed=([IO.File]::ReadAllText((IOPath $installedManifest)) | ConvertFrom-Json)
$oldHelper=Join-Path $extension 'dist\ccs21-antigravity-proxy.cjs'
[IO.File]::WriteAllText((IOPath $oldHelper),'/* previous adapter fixture */')
$installed.toolVersion='1.2.0'
$installed.adapterSha256=FileHash $oldHelper
[IO.File]::WriteAllText((IOPath $installedManifest),($installed | ConvertTo-Json))
RunRepair @()
Assert ((FileHash $oldHelper) -eq (TextHash $adapter)) 'Previous manifest/helper upgraded with verified source backup'
RunRepair @()
Assert ((FileHash $entry) -eq $patchedHash) 'Repeat installation is idempotent'
RunRepair @('Restore')
Assert ((FileHash $entry) -eq $before -and [IO.File]::ReadAllBytes($entry)[0] -eq 239) 'Restore preserves original bytes including UTF-8 BOM'
Assert (-not (Test-Path -LiteralPath (Join-Path $extension 'dist\ccs21-antigravity-proxy.cjs'))) 'Restore removes the owned helper beside package.main'
# Simulate an official extension update overwriting the patch, with another version.
[IO.File]::WriteAllText($entry,$source.Replace('const url','let url'),$utf8Bom)
$updatedHash=FileHash $entry
RunRepair @()
RunRepair @('Restore')
Assert ((FileHash $entry) -eq $updatedHash) 'Official update gets its own verified backup and restoration'
# Missing runtime backend must be reported as pending rather than falsely verified.
$BackendUrl=''
RunRepair @()
$lastReport=Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $reports -Filter 'repair-*.json' | Sort-Object Name) | Select-Object -Last 1).FullName -Raw | ConvertFrom-Json
Assert (-not $lastReport.backendVerified) 'Unavailable backend is recorded as pending'
[IO.File]::AppendAllText($entry,'// user edit')
$editedHash=FileHash $entry
ExpectFailure { RunRepair @() } 'Local edits are not overwritten'
Assert ((FileHash $entry) -eq $editedHash) 'Rejected edit preserves file hash'
$results | ForEach-Object { Write-Host ('PASS: '+$_) }
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'results.json') -Encoding UTF8
Write-Host ('PASS: '+$results.Count+' installer assertions. Fixtures retained in '+$fixtureRoot)
