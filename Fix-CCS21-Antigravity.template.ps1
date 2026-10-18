#requires -Version 5.1
<#
Repairs the reviewed Google Antigravity 1.8.0 / agy 1.4.2 CCS21 build.
The generated Fix-CCS21-Antigravity.ps1 includes its adapter and works offline.
#>
[CmdletBinding()]
param(
    [string]$ExtensionDir,
    [string]$CcsExe,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$adapter = @'
__EMBED_ADAPTER__
'@
$originalHash = '09DE6AB0D4431872AD6A6293E33315A15359A1B7FE2B6AF7C0CB14294AFC8EC9'
$oldMethod = 'renderIframe(a,b,c){var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$newMethod = 'async renderIframe(a,b,c){if(String(a.cspSource||"").includes(".webview.localhost")){var p=require("./ccs21-antigravity-proxy.cjs"),o=p.getTheiaWebviewOrigin(a,l.Uri.joinPath(this.context.extensionUri,"bridge.js"));b=await p.getProxyUrl(b,o,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function TextHash([string]$value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($value)))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
if (-not $ExtensionDir) {
    $ccsRoot = Join-Path $env:LOCALAPPDATA 'Texas Instruments\CCS'
    $candidates = @(Get-ChildItem -LiteralPath $ccsRoot -Directory -Filter 'ccs21*' | ForEach-Object {
        $deployment = Join-Path $_.FullName '0\theia\deployedPlugins'
        if (Test-Path -LiteralPath $deployment) {
            Get-ChildItem -LiteralPath $deployment -Directory -Filter 'google.google-antigravity*' | ForEach-Object {
                $candidate = Join-Path $_.FullName 'extension'
                if (Test-Path -LiteralPath (Join-Path $candidate 'package.json')) { Get-Item -LiteralPath $candidate }
            }
        }
    })
    if ($candidates.Count -ne 1) { throw 'Expected one CCS21 Antigravity installation. Pass -ExtensionDir with its extension folder.' }
    $ExtensionDir = $candidates[0].FullName
}
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$package = Get-Content -LiteralPath (Join-Path $ExtensionDir 'package.json') -Raw | ConvertFrom-Json
if ($package.publisher -ne 'google' -or $package.name -ne 'google-antigravity' -or $package.version -ne '1.8.0') {
    throw 'Unsupported extension. This repair supports the reviewed Antigravity 1.8.0 build only.'
}
$entryFile = Join-Path $ExtensionDir 'extension.js'
$helperFile = Join-Path $ExtensionDir 'ccs21-antigravity-proxy.cjs'
$backupDir = Join-Path $ExtensionDir 'ccs21-antigravity-backup'
$backupFile = Join-Path $backupDir 'extension.js.original'
$current = [IO.File]::ReadAllText($entryFile)
$currentHash = (Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash
$alreadyPatched = $current.Contains($newMethod)
if ($alreadyPatched) {
    if (-not (Test-Path -LiteralPath $backupFile)) { throw 'Patch backup is missing; refusing an unverifiable repair.' }
    $original = [IO.File]::ReadAllText($backupFile)
} else { $original = $current }
if ((TextHash $original) -ne $originalHash) { throw 'Extension source differs from the reviewed build; no changes made.' }
if (($original.Split(@($oldMethod),[StringSplitOptions]::None)).Count -ne 2) { throw 'Expected exactly one known renderIframe implementation.' }
$patched = $original.Replace($oldMethod,$newMethod)
if ($alreadyPatched -and $currentHash -ne (TextHash $patched)) { throw 'Other extension changes detected; refusing to overwrite.' }
if (Test-Path -LiteralPath $helperFile) {
    if ((Get-FileHash -LiteralPath $helperFile -Algorithm SHA256).Hash -ne (TextHash $adapter)) { throw 'Adapter file has unexpected contents; refusing to overwrite.' }
}
if ($CheckOnly) {
    if ($alreadyPatched -and -not (Test-Path -LiteralPath $helperFile)) { throw 'Patched entry point is missing its adapter. Run repair.' }
    Write-Host ('Compatible Antigravity 1.8.0 found. Adapter installed: ' + $alreadyPatched)
    Write-Host ('Extension: ' + $ExtensionDir)
    return
}
# Prepare every byte and validate the original before altering the installation.
if (-not $Restore) {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    if (Test-Path -LiteralPath $backupFile) {
        if ((Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Existing backup does not match the original.' }
    } else { [IO.File]::WriteAllText($backupFile,$original,$utf8) }
    [IO.File]::WriteAllText($helperFile,$adapter,$utf8)
    try {
        [IO.File]::WriteAllText($entryFile,$patched,$utf8)
        if ((Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash -ne (TextHash $patched)) { throw 'Patch verification failed.' }
    } catch {
        [IO.File]::WriteAllText($entryFile,$original,$utf8)
        throw
    }
    Write-Host 'Repair installed and verified. Original extension.js is backed up.' -ForegroundColor Green
} elseif ($alreadyPatched) {
    [IO.File]::WriteAllText($entryFile,$original,$utf8)
    if ((Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Restore verification failed.' }
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
