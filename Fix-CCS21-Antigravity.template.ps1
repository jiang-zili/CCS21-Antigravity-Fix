#requires -Version 5.1
<#
Detects extension/backend versions and repairs compatible renderer structures.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [string]$ProfileDir,
    [string[]]$SearchRoot,
    [string]$BackendUrl,
    [string]$ReportDir,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolVersion = '1.3.0'
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
    $stream = [IO.File]::OpenRead((IOPath $path))
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}
function BytesHash([byte[]]$bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
function GetRenderPlan([string]$source) {
    $id = '[A-Za-z_$][A-Za-z0-9_$]*'
    $pattern = '(?<![\w$])(?:async\s+)?renderIframe\s*\(\s*(?<view>'+$id+')\s*,\s*(?<server>'+$id+')\s*,\s*(?<options>'+$id+')\s*\)\s*\{\s*(?<body>(?:var|let|const)\s+(?<url>'+$id+')\s*=\s*this\.buildIframeUrl\(\s*\k<server>\s*,\s*\k<options>\s*\)\s*;\s*(?:console\.log\(`\[Jetski\] Loading iframe URL: \$\{'+$id+'\(\k<url>\)\}`\);\s*)?(?:return\s+)?this\.renderWebviewHtml\(\s*\k<view>\s*,\s*\k<server>\s*,\s*\k<url>\s*,\s*\k<options>\s*\)\s*;?\s*)\}'
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
__EMBED_DISCOVERY__
# Dot-sourcing exposes pure planning/discovery functions for isolated tests.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($CheckOnly -and $Restore) { throw 'Use either -CheckOnly or -Restore.' }
$processInventory = @(Get-CcsProcesses)
if (-not $ExtensionDir) {
    $roots = @()
    if ($ProfileDir) { $roots = @($ProfileDir) }
    elseif ($SearchRoot) { $roots = @($SearchRoot) }
    else {
        foreach ($proc in $processInventory | Where-Object { $_.Name -ieq 'ccstudio.exe' }) {
            foreach ($option in @('user-data-dir','plugins','extensions-dir')) {
                foreach ($launchPath in @(Get-LaunchPath ([string]$proc.CommandLine) $option)) {
                    $launchPath=$launchPath -replace '^local-dir:',''
                    $roots += $launchPath
                    $parent=Split-Path -Parent $launchPath
                    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent 'theia') -PathType Container)) { $roots += $parent }
                }
            }
        }
        $roots = @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Sort-Object -Unique)
        # Active launch paths take precedence over stale profiles.
        $active = @(Find-AntigravityExtensions $roots)
        if ($active.Count -eq 0) {
            foreach ($base in @($env:LOCALAPPDATA,$env:APPDATA)) {
                if ($base) { $roots += Join-Path $base 'Texas Instruments\CCS' }
            }
        }
    }
    $target = Select-RepairTarget @(Find-AntigravityExtensions $roots) 'Antigravity extension' 'Directory' -Headless:$NonInteractive
    $ExtensionDir = $target.Directory
}
$extensionInfo = Get-AntigravityPackage $ExtensionDir
if ($null -eq $extensionInfo) { throw 'Expected a Google Antigravity package and an existing package.main entry inside its directory. No files changed.' }
$ExtensionDir = $extensionInfo.Directory
$package = $extensionInfo.Package
Write-Host ('Detected Antigravity extension ' + $package.version + '. Checking renderer structure.')
$entryFile = $extensionInfo.Entry
$helperFile = Join-Path (Split-Path -Parent $entryFile) 'ccs21-antigravity-proxy.cjs'
$legacyBackupFile = Join-Path $ExtensionDir 'ccs21-antigravity-backup\extension.js.original'
$backupRoot = Join-Path $ExtensionDir 'AgentOutput\CCS21-Antigravity'
$manifestFile = Join-Path $backupRoot 'installed.json'
$manifest = $null
if ([IO.File]::Exists((IOPath $manifestFile))) { $manifest = [IO.File]::ReadAllText((IOPath $manifestFile)) | ConvertFrom-Json }
$current = [IO.File]::ReadAllText((IOPath $entryFile))
$currentBytes = [IO.File]::ReadAllBytes((IOPath $entryFile))
$currentHash = FileHash $entryFile
$legacyPatched = $current.Contains($legacyPatchedMethod)
$alreadyPatched = $legacyPatched -or $current.Contains('/*CCS21_AG_ADAPTER_START*/')
if ($alreadyPatched -and -not $legacyPatched) {
    if ($null -eq $manifest -or $currentHash -ne $manifest.patchedSha256) { throw 'Installed patch changed or its manifest is missing. No files changed.' }
    $sourceBackup = [IO.Path]::GetFullPath([string]$manifest.originalFile)
    if (-not $sourceBackup.StartsWith([IO.Path]::GetFullPath($backupRoot) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup manifest points outside AgentOutput.' }
    if ((FileHash $sourceBackup) -ne $manifest.originalSha256) { throw 'Original backup failed SHA-256 validation.' }
    $original = [IO.File]::ReadAllText((IOPath $sourceBackup))
} elseif ($legacyPatched) {
    $sourceBackup = Join-Path $backupRoot 'extension.js.original'
    if (-not ([IO.File]::Exists((IOPath $sourceBackup)))) { $sourceBackup = $legacyBackupFile }
    if (-not ([IO.File]::Exists((IOPath $sourceBackup)))) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText((IOPath $sourceBackup))
    if ((TextHash $original) -ne $legacyOriginalHash) { throw 'Legacy original backup does not match the reviewed build.' }
} else { $original = $current }
if ($alreadyPatched) { $originalBytes = [IO.File]::ReadAllBytes((IOPath $sourceBackup)) }
else { $originalBytes = $currentBytes }
$originalHash = BytesHash $originalBytes
# Keep Windows PowerShell 5.1 paths below MAX_PATH. Verify the full hash on
# every reuse, so a shortened directory name never authorizes another source.
$backupDir = Join-Path $backupRoot $originalHash.Substring(0,12)
$backupFile = Join-Path $backupDir 'extension.js.original'
$plan = GetRenderPlan $original
$patched = $original.Replace($plan.originalMethod,$plan.replacement)
if ($legacyPatched -and $currentHash -ne (TextHash ($original.Replace($plan.originalMethod,$legacyPatchedMethod)))) { throw 'Other legacy extension changes detected; refusing to overwrite.' }
Write-Host ('Compatible renderer detected. Source SHA-256: ' + $originalHash)
if ([IO.File]::Exists((IOPath $helperFile))) {
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
        $ccsTarget = Select-RepairTarget @(Find-CcsInstallations $processInventory $SearchRoot) 'CCS executable' 'Executable' -Headless:$NonInteractive
    } else {
        $ccsTarget = Resolve-CcsExecutable $CcsExe
    }
    if ($null -eq $ccsTarget) { throw 'Selected CCS has no bundled Node.js/resources structure. No files changed.' }
    $CcsExe = $ccsTarget.Executable
    $nodeExe = $ccsTarget.Node
    Write-Host ('CCS executable: ' + $CcsExe)
    $backendUrls = @()
    $backendProcesses = @($processInventory | Where-Object { $_.Name -ieq 'agy.exe' })
    if ($BackendUrl) { $backendUrls = @($BackendUrl) }
    else {
        $backendUrls = @($backendProcesses | ForEach-Object {
            if ($_.CommandLine -match '(?:^|\s)--hub-port(?:=|\s+)(\d+)(?:\s|$)') { 'http://127.0.0.1:' + $Matches[1] }
        } | Sort-Object -Unique)
    }
    if ($backendUrls.Count -gt 1) { Write-Host 'Multiple local agy backends found; checking each. Use -BackendUrl to check one specific session.' }
    if ($backendUrls.Count -eq 0) { Write-Host 'No backend address available. Install-time backend check pending; the adapter checks it when the panel opens.' }
    $probeFile = Join-Path ([IO.Path]::GetTempPath()) ('ccs21-antigravity-check-' + [Guid]::NewGuid().ToString('N') + '.cjs')
    try {
        [IO.File]::WriteAllText((IOPath $probeFile),$adapter,$utf8)
        & $nodeExe --check $probeFile
        if ($LASTEXITCODE -ne 0) { throw 'Bundled Node.js cannot parse this adapter. No files changed.' }
        $syntaxFile = [IO.Path]::ChangeExtension($probeFile,'.js')
        try {
            [IO.File]::WriteAllText((IOPath $syntaxFile),$patched,$utf8)
            & $nodeExe --check $syntaxFile
            if ($LASTEXITCODE -ne 0) { throw 'Patched extension syntax check failed. No files changed.' }
        } finally { if ([IO.File]::Exists((IOPath $syntaxFile))) { [IO.File]::Delete((IOPath $syntaxFile)) } }
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
    } finally { if ([IO.File]::Exists((IOPath $probeFile))) { [IO.File]::Delete((IOPath $probeFile)) } }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not ([IO.File]::Exists((IOPath $helperFile)))) { throw 'Patched entry point is missing its adapter. Run repair.' }
    $adapterCurrent = ([IO.File]::Exists((IOPath $helperFile))) -and ((FileHash $helperFile) -eq (TextHash $adapter))
    Write-Host ('Compatible Antigravity ' + $package.version + '. Current adapter installed: ' + ($alreadyPatched -and $adapterCurrent -and -not $legacyPatched))
    if ($alreadyPatched -and ($legacyPatched -or -not $adapterCurrent)) { Write-Host 'Legacy adapter found. Run repair to enable automatic update compatibility.' }
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    # Fail on an unwritable report location before touching the extension.
    [IO.Directory]::CreateDirectory((IOPath $ReportDir)) | Out-Null
    $reportProbe = Join-Path $ReportDir ('.write-check-' + [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText((IOPath $reportProbe),'',$utf8)
    [IO.File]::Delete((IOPath $reportProbe))
    if (-not (Test-Path -LiteralPath $backupDir)) { [IO.Directory]::CreateDirectory((IOPath $backupDir)) | Out-Null }
    if ([IO.File]::Exists((IOPath $backupFile))) {
        if ((FileHash $backupFile) -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllBytes((IOPath $backupFile),$originalBytes) }
    $snapshotDir = Join-Path $backupDir ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'))
    [IO.Directory]::CreateDirectory((IOPath $snapshotDir)) | Out-Null
    [IO.File]::Copy((IOPath $entryFile),(IOPath (Join-Path $snapshotDir 'extension.js.before')))
    $previousHelper = $null
    if ([IO.File]::Exists((IOPath $helperFile))) {
        $previousHelper = [IO.File]::ReadAllBytes((IOPath $helperFile))
        [IO.File]::Copy((IOPath $helperFile),(IOPath (Join-Path $snapshotDir 'proxy.cjs.before')))
    }
    $previousManifest = $null
    if ([IO.File]::Exists((IOPath $manifestFile))) {
        $previousManifest = [IO.File]::ReadAllBytes((IOPath $manifestFile))
        [IO.File]::Copy((IOPath $manifestFile),(IOPath (Join-Path $snapshotDir 'installed.json.before')))
    }
    if ((FileHash $entryFile) -ne $currentHash) { throw 'Extension changed during preflight. Rerun repair.' }
    try {
        [IO.File]::WriteAllText((IOPath $helperFile),$adapter,$utf8)
        [IO.File]::WriteAllText((IOPath $entryFile),$patched,$utf8)
        if ((FileHash $entryFile) -ne (TextHash $patched) -or (FileHash $helperFile) -ne (TextHash $adapter)) { throw 'Patch verification failed.' }
        $manifestJson = [PSCustomObject]@{ toolVersion=$toolVersion; extensionVersion=$package.version; originalFile=$backupFile; originalSha256=$originalHash; patchedSha256=(TextHash $patched); adapterSha256=(TextHash $adapter) } | ConvertTo-Json
        [IO.File]::WriteAllText((IOPath $manifestFile),$manifestJson,$utf8)
    } catch {
        [IO.File]::WriteAllBytes((IOPath $entryFile),$currentBytes)
        if ($null -ne $previousHelper) { [IO.File]::WriteAllBytes((IOPath $helperFile),$previousHelper) }
        elseif ([IO.File]::Exists((IOPath $helperFile))) { [IO.File]::Delete((IOPath $helperFile)) }
        if ($null -ne $previousManifest) { [IO.File]::WriteAllBytes((IOPath $manifestFile),$previousManifest) }
        elseif ([IO.File]::Exists((IOPath $manifestFile))) { [IO.File]::Delete((IOPath $manifestFile)) }
        throw
    }
    [IO.Directory]::CreateDirectory((IOPath $ReportDir)) | Out-Null
    $reportFile = Join-Path $ReportDir ('repair-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
    $reportJson = [PSCustomObject]@{ toolVersion=$toolVersion; extension=$ExtensionDir; entryFile=$entryFile; ccsExecutable=$CcsExe; extensionVersion=$package.version; installed=$true; installedBackendVersions=$binaryVersions; backendChecks=$backendChecks; backendVerified=($backendChecks.Count -gt 0); uiVerified=$false; status='installed-reload-required'; backup=$snapshotDir } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((IOPath $reportFile),$reportJson,$utf8)
    Write-Host ('Adapter ' + $toolVersion + ' installed. Backend verified: ' + ($backendChecks.Count -gt 0) + '. Backup: ' + $snapshotDir) -ForegroundColor Green
    Write-Host 'UI verification is pending. Reload CCS21 and confirm the Antigravity panel opens.'
    Write-Host ('Report: ' + $reportFile)
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllBytes((IOPath $entryFile),$originalBytes)
    if ((FileHash $entryFile) -ne $originalHash) { throw 'Restore verification failed.' }
    if ([IO.File]::Exists((IOPath $helperFile))) { [IO.File]::Delete((IOPath $helperFile)) }
    Write-Host 'Original extension.js restored and verified.' -ForegroundColor Green
} else { Write-Host 'Original extension is already present.' }
if ($NoRestart) { Write-Host 'In CCS use Developer: Reload Window to load the change.'; return }
$running = @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -ne 0 -and ($CcsExe -and $_.Path -ieq $CcsExe)
})
if ($running.Count -gt 1) { throw 'Multiple CCS21 windows are open. Reload each window manually.' }
if ($running.Count -eq 1) {
    $launch = @($processInventory | Where-Object { $_.ProcessId -eq $running[0].Id -and $_.CommandLine })
    if ($launch.Count -ne 1 -or $launch[0].CommandLine -notmatch '^\s*(?:"[^"]+"|\S+)\s*(?<arguments>[\s\S]*)$') {
        Write-Host 'Original launch arguments unavailable. Use Developer: Reload Window to retain your profile/workspace.'
        return
    }
    $restartArguments = $Matches['arguments']
    if (-not $CcsExe) { $CcsExe = $running[0].Path }
    Write-Host 'Restarting CCS21. Save changes if CCS asks; no process will be force-killed.'
    if (-not $running[0].CloseMainWindow()) { throw 'CCS did not accept a graceful close. Use Developer: Reload Window.' }
    if (-not $running[0].WaitForExit(30000)) { throw 'CCS is still open, possibly awaiting Save. Complete that dialog, then restart CCS.' }
}
if ($running.Count -eq 0) {
    Write-Host 'Open or reload the selected CCS installation to load the change. No duplicate instance was started.'
    return
}
if ($CcsExe -and ([IO.File]::Exists((IOPath $CcsExe)))) {
    if ($restartArguments) { Start-Process -FilePath $CcsExe -ArgumentList $restartArguments -WindowStyle Hidden }
    else { Start-Process -FilePath $CcsExe -WindowStyle Hidden }
}
else { Write-Host 'Repair complete. Open CCS21 manually.' }

