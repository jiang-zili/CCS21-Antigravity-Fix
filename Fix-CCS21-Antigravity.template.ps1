#requires -Version 5.1
<#
Detects extension/backend versions and repairs compatible renderer structures.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [string]$BackendUrl,
    [string]$ReportDir,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolVersion = '1.2.0'
if (-not $ReportDir) { $ReportDir = Join-Path $PSScriptRoot 'AgentOutput' }
$adapter = @'
__EMBED_ADAPTER__
'@
$legacyOriginalHash = '09DE6AB0D4431872AD6A6293E33315A15359A1B7FE2B6AF7C0CB14294AFC8EC9'
$legacyPatchedMethod = 'async renderIframe(a,b,c){if(String(a.cspSource||"").includes(".webview.localhost")){var p=require("./ccs21-antigravity-proxy.cjs"),o=p.getTheiaWebviewOrigin(a,l.Uri.joinPath(this.context.extensionUri,"bridge.js"));b=await p.getProxyUrl(b,o,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function TextHash([string]$value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($value)))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
function FileHash([string]$path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function GetRenderPlan([string]$source) {
    $id = '[A-Za-z_$][A-Za-z0-9_$]*'
    $pattern = 'renderIframe\((?<view>'+$id+'),(?<server>'+$id+'),(?<options>'+$id+')\)\{(?<body>(?:var|let|const) (?<url>'+$id+')=this\.buildIframeUrl\(\k<server>,\k<options>\);console\.log\(`\[Jetski\] Loading iframe URL: \$\{'+$id+'\(\k<url>\)\}`\);this\.renderWebviewHtml\(\k<view>,\k<server>,\k<url>,\k<options>\))\}'
    $found = [regex]::Matches($source,$pattern)
    if ($found.Count -ne 1) { throw ('Unsupported extension renderer structure: expected one local renderer, found ' + $found.Count + '. No files changed.') }
    $match = $found[0]
    if ($match.Value.Contains('__ccs21Embed')) { throw 'Renderer variable collision. No files changed.' }
    $view = $match.Groups['view'].Value
    $server = $match.Groups['server'].Value
    $options = $match.Groups['options'].Value
    $injection = '/*CCS21_AG_ADAPTER_START*/if(String('+$view+'.cspSource||"").includes(".webview.localhost")){var __ccs21EmbedAdapter=require("./ccs21-antigravity-proxy.cjs"),__ccs21EmbedOrigin=__ccs21EmbedAdapter.getTheiaWebviewOrigin('+$view+',this.context.extensionUri);'+$server+'=await __ccs21EmbedAdapter.getProxyUrl('+$server+',__ccs21EmbedOrigin,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}/*CCS21_AG_ADAPTER_END*/'
    $replacement = 'async renderIframe('+$view+','+$server+','+$options+'){'+$injection+$match.Groups['body'].Value+'}'
    return [PSCustomObject]@{ originalMethod=$match.Value; replacement=$replacement }
}
if ($CheckOnly -and $Restore) { throw 'Use either -CheckOnly or -Restore.' }
if (-not $ExtensionDir) {
    $ccsRoot = Join-Path $env:LOCALAPPDATA 'Texas Instruments\CCS'
    $candidates = @(Get-ChildItem -LiteralPath $ccsRoot -Directory -Filter 'ccs21*' | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
        $deployment = Join-Path $_.FullName 'theia\deployedPlugins'
        if (Test-Path -LiteralPath $deployment) {
            Get-ChildItem -LiteralPath $deployment -Directory -Filter 'google.google-antigravity*' | ForEach-Object {
                $candidate = Join-Path $_.FullName 'extension'
                if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { Get-Item -LiteralPath $candidate }
            }
        }
        }
    })
    if ($candidates.Count -ne 1) { throw 'Expected one CCS21 Antigravity installation. Pass -ExtensionDir with its extension folder.' }
    $ExtensionDir = $candidates[0].FullName
}
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$package = Get-Content -LiteralPath (Join-Path $ExtensionDir 'package.json') -Raw | ConvertFrom-Json
if ($package.publisher -ne 'google' -or $package.name -ne 'google-antigravity' -or $package.version -notmatch '^\d+\.\d+\.\d+') {
    throw 'Expected a Google Antigravity extension package with a valid version.'
}
Write-Host ('Detected Antigravity extension ' + $package.version + '. Checking renderer structure.')
$entryFile = Join-Path $ExtensionDir 'extension.js'
$helperFile = Join-Path $ExtensionDir 'ccs21-antigravity-proxy.cjs'
$legacyBackupFile = Join-Path $ExtensionDir 'ccs21-antigravity-backup\extension.js.original'
$backupRoot = Join-Path $ExtensionDir 'AgentOutput\CCS21-Antigravity'
$manifestFile = Join-Path $backupRoot 'installed.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestFile) { $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json }
$current = [IO.File]::ReadAllText($entryFile)
$currentHash = FileHash $entryFile
$legacyPatched = $current.Contains($legacyPatchedMethod)
$alreadyPatched = $legacyPatched -or $current.Contains('/*CCS21_AG_ADAPTER_START*/')
if ($alreadyPatched -and -not $legacyPatched) {
    if ($null -eq $manifest -or $currentHash -ne $manifest.patchedSha256) { throw 'Installed patch changed or its manifest is missing. No files changed.' }
    $sourceBackup = [IO.Path]::GetFullPath([string]$manifest.originalFile)
    if (-not $sourceBackup.StartsWith([IO.Path]::GetFullPath($backupRoot) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup manifest points outside AgentOutput.' }
    if ((FileHash $sourceBackup) -ne $manifest.originalSha256) { throw 'Original backup failed SHA-256 validation.' }
    $original = [IO.File]::ReadAllText($sourceBackup)
} elseif ($legacyPatched) {
    $sourceBackup = Join-Path $backupRoot 'extension.js.original'
    if (-not (Test-Path -LiteralPath $sourceBackup)) { $sourceBackup = $legacyBackupFile }
    if (-not (Test-Path -LiteralPath $sourceBackup)) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText($sourceBackup)
    if ((TextHash $original) -ne $legacyOriginalHash) { throw 'Legacy original backup does not match the reviewed build.' }
} else { $original = $current }
$originalHash = TextHash $original
# Keep Windows PowerShell 5.1 paths below MAX_PATH. Verify the full hash on
# every reuse, so a shortened directory name never authorizes another source.
$backupDir = Join-Path $backupRoot $originalHash.Substring(0,12)
$backupFile = Join-Path $backupDir 'extension.js.original'
$plan = GetRenderPlan $original
$patched = $original.Replace($plan.originalMethod,$plan.replacement)
if ($legacyPatched -and $currentHash -ne (TextHash ($original.Replace($plan.originalMethod,$legacyPatchedMethod)))) { throw 'Other legacy extension changes detected; refusing to overwrite.' }
Write-Host ('Compatible renderer detected. Source SHA-256: ' + $originalHash)
if (Test-Path -LiteralPath $helperFile) {
    $helperHash = FileHash $helperFile
    $knownHelpers = @((TextHash $adapter),'D9F36391B8F33025E4BE0502F7BE55E49042A9766509A44646AF2A7F6FFC30B3','F7DDA1CDB4A063D3C128A201439A45FD35203ACBDA193B0CF6B4E3EFC241069E')
    if ($null -ne $manifest) { $knownHelpers += [string]$manifest.adapterSha256 }
    if ($helperHash -notin $knownHelpers) { throw 'Adapter file has unexpected local edits; refusing to overwrite.' }
}
# Preflight the real frontend, not just package.json: agy updates independently.
$backendChecks = @()
$binaryVersions = @()
if (-not $Restore) {
    if (-not $CcsExe) {
        $ccsPaths = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Where-Object { $_ -like '*\ccs21*\ccs\theia\ccstudio.exe' } | Sort-Object -Unique)
        if ($ccsPaths.Count -eq 1) { $CcsExe = $ccsPaths[0] }
        elseif (Test-Path -LiteralPath 'C:\ti\ccs2101\ccs\theia\ccstudio.exe') { $CcsExe = 'C:\ti\ccs2101\ccs\theia\ccstudio.exe' }
    }
    if (-not $CcsExe -or -not (Test-Path -LiteralPath $CcsExe)) { throw 'Pass -CcsExe pointing to the CCS21 executable. No files changed.' }
    $nodeExe = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $CcsExe) '..\tools\node\node.exe'))
    if (-not (Test-Path -LiteralPath $nodeExe)) { throw 'CCS bundled Node.js was not found. No files changed.' }
    $backendUrls = @()
    $backendProcesses = @(Get-CimInstance Win32_Process -Filter "Name='agy.exe'")
    if ($BackendUrl) { $backendUrls = @($BackendUrl) }
    else {
        $backendUrls = @($backendProcesses | ForEach-Object {
            if ($_.CommandLine -match '(?:^|\s)--hub-port=(\d+)(?:\s|$)') { 'http://127.0.0.1:' + $Matches[1] }
        } | Sort-Object -Unique)
    }
    if ($backendUrls.Count -eq 0) { throw 'Open CCS21 and the Antigravity panel first, then rerun. No running agy backend was found; no files changed.' }
    $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('ccs21-antigravity-check-' + [Guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [IO.File]::WriteAllText($probeFile,$adapter,$utf8)
        foreach ($binary in @($backendProcesses | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ } | Sort-Object -Unique)) {
            # Installed and running versions may differ after an update.
            $installedVersion = (& $nodeExe $probeFile --binary-version $binary) -join ''
            $binaryVersions += [PSCustomObject]@{ executable=$binary; installedVersion=$installedVersion }
            Write-Host ('Installed agy executable version: ' + $installedVersion)
        }
        foreach ($url in $backendUrls) {
            $probeOutput = & $nodeExe $probeFile --check-backend $url 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('Backend check failed: ' + ($probeOutput -join ' ') + '. No files changed.') }
            $probe = ($probeOutput -join '') | ConvertFrom-Json
            $backendChecks += [PSCustomObject]@{ url=$url; version=$probe.version; mode=$probe.mode; sha256=$probe.sha256 }
            Write-Host ('Verified running agy ' + $probe.version + ' (' + $probe.mode + '), frontend: ' + $probe.sha256)
        }
    } finally { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile } }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not (Test-Path -LiteralPath $helperFile)) { throw 'Patched entry point is missing its adapter. Run repair.' }
    $adapterCurrent = (Test-Path -LiteralPath $helperFile) -and ((FileHash $helperFile) -eq (TextHash $adapter))
    Write-Host ('Compatible Antigravity ' + $package.version + '. Current adapter installed: ' + ($alreadyPatched -and $adapterCurrent -and -not $legacyPatched))
    if ($alreadyPatched -and ($legacyPatched -or -not $adapterCurrent)) { Write-Host 'Legacy adapter found. Run repair to enable automatic update compatibility.' }
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    if (Test-Path -LiteralPath $backupFile) {
        if ((FileHash $backupFile) -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllText($backupFile,$original,$utf8) }
    $snapshotDir = Join-Path $backupDir ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $snapshotDir | Out-Null
    Copy-Item -LiteralPath $entryFile -Destination (Join-Path $snapshotDir 'extension.js.before')
    $previousHelper = $null
    if (Test-Path -LiteralPath $helperFile) {
        $previousHelper = [IO.File]::ReadAllBytes($helperFile)
        Copy-Item -LiteralPath $helperFile -Destination (Join-Path $snapshotDir 'proxy.cjs.before')
    }
    try {
        [IO.File]::WriteAllText($helperFile,$adapter,$utf8)
        [IO.File]::WriteAllText($entryFile,$patched,$utf8)
        if ((FileHash $entryFile) -ne (TextHash $patched) -or (FileHash $helperFile) -ne (TextHash $adapter)) { throw 'Patch verification failed.' }
        [PSCustomObject]@{ toolVersion=$toolVersion; extensionVersion=$package.version; originalFile=$backupFile; originalSha256=$originalHash; patchedSha256=(TextHash $patched); adapterSha256=(TextHash $adapter) } | ConvertTo-Json | Set-Content -LiteralPath $manifestFile -Encoding UTF8
    } catch {
        [IO.File]::WriteAllText($entryFile,$current,$utf8)
        if ($null -ne $previousHelper) { [IO.File]::WriteAllBytes($helperFile,$previousHelper) }
        elseif (Test-Path -LiteralPath $helperFile) { Remove-Item -LiteralPath $helperFile }
        throw
    }
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $reportFile = Join-Path $ReportDir ('repair-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
    [PSCustomObject]@{ toolVersion=$toolVersion; extension=$ExtensionDir; extensionVersion=$package.version; installed=$true; installedBackendVersions=$binaryVersions; backendChecks=$backendChecks; uiVerified=$false; status='installed-reload-required'; backup=$snapshotDir } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    Write-Host ('Adapter ' + $toolVersion + ' installed; running backend compatibility verified. Backup: ' + $snapshotDir) -ForegroundColor Green
    Write-Host 'UI verification is pending. Reload CCS21 and confirm the Antigravity panel opens.'
    Write-Host ('Report: ' + $reportFile)
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllText($entryFile,$original,$utf8)
    if ((FileHash $entryFile) -ne $originalHash) { throw 'Restore verification failed.' }
    if (Test-Path -LiteralPath $helperFile) { Remove-Item -LiteralPath $helperFile }
    Write-Host 'Original extension.js restored and verified.' -ForegroundColor Green
} else { Write-Host 'Original extension is already present.' }
if ($NoRestart) { Write-Host 'In CCS use Developer: Reload Window to load the change.'; return }
$running = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and $_.Path -like '*\ccs21*\ccs\theia\ccstudio.exe'
})
if ($running.Count -gt 1) { throw 'Multiple CCS21 windows are open. Reload each window manually.' }
if ($running.Count -eq 1) {
    if (-not $CcsExe) { $CcsExe = $running[0].Path }
    Write-Host 'Restarting CCS21. Save changes if CCS asks; no process will be force-killed.'
    if (-not $running[0].CloseMainWindow()) { throw 'CCS did not accept a graceful close. Use Developer: Reload Window.' }
    if (-not $running[0].WaitForExit(30000)) { throw 'CCS is still open, possibly awaiting Save. Complete that dialog, then restart CCS.' }
}
if ($running.Count -eq 0 -and @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\ccs21*\ccs\theia\ccstudio.exe' }).Count -gt 0) {
    Write-Host 'CCS21 is running but its window cannot be identified. Use Developer: Reload Window; no duplicate CCS instance was started.'
    return
}
if (-not $CcsExe) {
    $executables = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $tiRoot = Join-Path $_.Root 'ti'
        if (Test-Path -LiteralPath $tiRoot) {
            Get-ChildItem -LiteralPath $tiRoot -Directory -Filter 'ccs21*' | ForEach-Object {
                $exe = Join-Path $_.FullName 'ccs\theia\ccstudio.exe'
                if (Test-Path -LiteralPath $exe) { $exe }
            }
        }
    })
    if ($executables.Count -eq 1) { $CcsExe = $executables[0] }
}
if ($CcsExe -and (Test-Path -LiteralPath $CcsExe)) { Start-Process -FilePath $CcsExe -WindowStyle Hidden }
else { Write-Host 'Repair complete. Open CCS21 manually.' }
