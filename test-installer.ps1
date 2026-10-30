#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$utf8=New-Object Text.UTF8Encoding($false)
$fixtureRoot=Join-Path $PSScriptRoot ('.local\installer-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script=Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.ps1'
$shell=(Get-Process -Id $PID).Path
function Assert($condition,[string]$message) {if (-not $condition) {throw $message}}
function Hash([byte[]]$value) {$sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash($value))}finally{$sha.Dispose()}}
function Save([string]$file,[string]$text) {[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file));[IO.File]::WriteAllText($file,$text,$utf8)}
function Fixture([string]$relative,[string]$version,[string]$main='./compiled/deep/custom-loader.cjs') {
    $root=Join-Path $fixtureRoot $relative
    $manifest='{"publisher":"google","name":"google-antigravity","version":"'+$version+'","main":"'+$main+'","scripts":{"main":"must-stay-unchanged"},"description":"Unicode path test"}'
    Save (Join-Path $root 'package.json') $manifest
    $entry=Join-Path $root $main
    Save $entry 'exports.activate = function renamedPanelRenderer(context) { return context; };'
    return [PSCustomObject]@{root=$root;manifest=$manifest;entry=$entry;source=[IO.File]::ReadAllBytes($entry)}
}
function InvokeRepair([string[]]$options,[switch]$ExpectFailure) {
    $saved=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$output=& $shell -NoProfile -ExecutionPolicy Bypass -File $script @options -Json -NoRestart -ReportDir (Join-Path $fixtureRoot 'reports') 2>&1;$code=$LASTEXITCODE}
    finally {$ErrorActionPreference=$saved}
    if($ExpectFailure){Assert ($code -ne 0) 'Expected a refusal but the installer succeeded.';return}
    if($code -ne 0){throw ('Installer failed: '+($output -join "`n"))}
    return ($output -join '') | ConvertFrom-Json
}
$first=Fixture 'custom location\unusual-version\插件 目录\extension' '0.3.0'
$second=Fixture 'custom location\other copy\extension' '99.88.77-beta.1' './some-other-entry.js'
Save (Join-Path $fixtureRoot 'custom location\unrelated\package.json') '{"publisher":"other","name":"google-antigravity","main":"extension.js"}'
$check=InvokeRepair @('-SearchRoot',(Join-Path $fixtureRoot 'custom location'),'-CheckOnly')
Assert ($check.installations.Count -eq 2) 'Manifest discovery missed versions or non-ASCII paths.'
Assert ($check.backendStatus -eq 'deferred-until-activation') 'Closed-IDE checks should work offline.'
$installed=InvokeRepair @('-SearchRoot',(Join-Path $fixtureRoot 'custom location'))
Assert (@($installed.installations | Where-Object {$_.status -eq 'installed-restart-required'}).Count -eq 2) 'Not all selected copies were installed.'
foreach($item in @($first,$second)) {
    $package=[IO.File]::ReadAllText((Join-Path $item.root 'package.json')) | ConvertFrom-Json
    Assert ($package.main -eq './ccs-antigravity-entry.cjs') 'Manifest wrapper was not selected.'
    Assert ($package.scripts.main -eq 'must-stay-unchanged') 'A nested main property was altered.'
    Assert ((Hash ([IO.File]::ReadAllBytes($item.entry))) -eq (Hash $item.source)) 'Original extension source changed.'
}
$repeat=InvokeRepair @('-SearchRoot',(Join-Path $fixtureRoot 'custom location'))
Assert (@($repeat.installations | Where-Object {$_.status -eq 'installed-restart-required'}).Count -eq 2) 'Repeated repair failed.'
$missingParser=Join-Path $first.root 'ccs-antigravity-acorn.cjs'
[IO.File]::Delete($missingParser)
$incomplete=InvokeRepair @('-ExtensionDir',$first.root,'-CheckOnly')
Assert ($incomplete.installations[0].status -eq 'Incomplete-runtime') 'Missing runtime was reported as complete.'
$null=InvokeRepair @('-ExtensionDir',$first.root)
Assert ([IO.File]::Exists($missingParser)) 'Missing runtime was not repaired.'
$editedHelper=Join-Path $first.root 'ccs-antigravity-adapter.cjs'
$helperBefore=[IO.File]::ReadAllBytes($editedHelper)
$packageBefore=[IO.File]::ReadAllBytes((Join-Path $first.root 'package.json'))
Save $editedHelper 'module.exports = { localEdit: true };'
InvokeRepair @('-ExtensionDir',$first.root,'-Restore') -ExpectFailure
Assert ((Hash ([IO.File]::ReadAllBytes((Join-Path $first.root 'package.json')))) -eq (Hash $packageBefore)) 'Refused restore still modified the package.'
[IO.File]::WriteAllBytes($editedHelper,$helperBefore)
$restored=InvokeRepair @('-SearchRoot',(Join-Path $fixtureRoot 'custom location'),'-Restore')
foreach($item in @($first,$second)) {
    Assert ([IO.File]::ReadAllText((Join-Path $item.root 'package.json')) -eq $item.manifest) 'Manifest restore was not exact.'
    Assert ((Hash ([IO.File]::ReadAllBytes($item.entry))) -eq (Hash $item.source)) 'Source restore was not exact.'
    foreach($name in @('ccs-antigravity-entry.cjs','ccs-antigravity-adapter.cjs','ccs-antigravity-acorn.cjs','ccs-antigravity-acorn-LICENSE','.ccs-antigravity-state.json')) {Assert (-not [IO.File]::Exists((Join-Path $item.root $name))) ('Restore left '+$name)}
}
# Simulate an official update overwriting package.json and changing its entry,
# while the prior adapter files remain in the deployed directory.
$null=InvokeRepair @('-ExtensionDir',$first.root)
$updatedManifest='{"publisher":"google","name":"google-antigravity","version":"123.0.0","main":"./updated-entry.cjs"}'
Save (Join-Path $first.root 'package.json') $updatedManifest
Save (Join-Path $first.root 'updated-entry.cjs') 'exports.activate = () => "updated-official-source";'
$null=InvokeRepair @('-ExtensionDir',$first.root)
$null=InvokeRepair @('-ExtensionDir',$first.root,'-Restore')
Assert ([IO.File]::ReadAllText((Join-Path $first.root 'package.json')) -eq $updatedManifest) 'Official-update restore used an older manifest.'
# Previous v1.2 repair migration uses its recorded hashes, regardless of version.
$legacy=Fixture 'legacy installation\extension' '7.4.1' './extension.js'
$originalHash=(Hash $legacy.source).Replace('-','')
$legacyBackup=Join-Path $legacy.root ('AgentOutput\CCS21-Antigravity\'+$originalHash.Substring(0,12)+'\extension.js.original')
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($legacyBackup));[IO.File]::WriteAllBytes($legacyBackup,$legacy.source)
Save $legacy.entry ([IO.File]::ReadAllText($legacy.entry)+'/*CCS21_AG_ADAPTER_START*/ /*CCS21_AG_ADAPTER_END*/')
Save (Join-Path $legacy.root 'ccs21-antigravity-proxy.cjs') 'module.exports = {};'
$oldState=@{originalFile=$legacyBackup;originalSha256=$originalHash;patchedSha256=(Hash ([IO.File]::ReadAllBytes($legacy.entry))).Replace('-','');adapterSha256=(Hash ([IO.File]::ReadAllBytes((Join-Path $legacy.root 'ccs21-antigravity-proxy.cjs')))).Replace('-','')}
Save (Join-Path $legacy.root 'AgentOutput\CCS21-Antigravity\installed.json') ($oldState | ConvertTo-Json)
$null=InvokeRepair @('-ExtensionDir',$legacy.root)
Assert ((Hash ([IO.File]::ReadAllBytes($legacy.entry))) -eq (Hash $legacy.source)) 'Legacy source was not migrated to the saved original.'
$null=InvokeRepair @('-ExtensionDir',$legacy.root,'-Restore')
Assert ([IO.File]::ReadAllText((Join-Path $legacy.root 'package.json')) -eq $legacy.manifest) 'Legacy restore used a patched package.'
# v1.3 keeps its helper beside an arbitrary nested main and preserves BOM bytes.
# This also crosses the extended-path boundary inside a short-enough root.
$paddingLength=[Math]::Max(4,210-($fixtureRoot.Length+18))
$legacy13=Fixture (('long-profile-'+('x'*$paddingLength))+'\plugins') '99.42.0-future' './dist/entry.js'
$bomSource=[byte[]](@(239,187,191)+$legacy13.source)
[IO.File]::WriteAllBytes($legacy13.entry,$bomSource)
$legacy13Hash=(Hash $bomSource).Replace('-','')
$legacy13Backup=Join-Path $legacy13.root ('AgentOutput\CCS21-Antigravity\'+$legacy13Hash.Substring(0,12)+'\extension.js.original')
Assert ($legacy13Backup.Length -gt 260) 'Fixture must exercise a backup longer than MAX_PATH.'
$longBackup='\\?\'+$legacy13Backup
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($longBackup));[IO.File]::WriteAllBytes($longBackup,$bomSource)
Save $legacy13.entry '/*CCS21_AG_ADAPTER_START*/ exports.activate = () => {}; /*CCS21_AG_ADAPTER_END*/'
$legacy13Helper=Join-Path ([IO.Path]::GetDirectoryName($legacy13.entry)) 'ccs21-antigravity-proxy.cjs'
Save $legacy13Helper 'module.exports = { version: "legacy13" };'
$legacy13HelperBytes=[IO.File]::ReadAllBytes($legacy13Helper)
$legacy13State=@{toolVersion='1.3.0';originalFile=$legacy13Backup;originalSha256=$legacy13Hash;patchedSha256=(Hash ([IO.File]::ReadAllBytes($legacy13.entry))).Replace('-','');adapterSha256=(Hash $legacy13HelperBytes).Replace('-','')}
$legacy13Manifest='\\?\'+(Join-Path $legacy13.root 'AgentOutput\CCS21-Antigravity\installed.json')
[IO.File]::WriteAllText($legacy13Manifest,($legacy13State | ConvertTo-Json),$utf8)
Save $legacy13Helper '// unrecognized local edit'
InvokeRepair @('-ExtensionDir',$legacy13.root) -ExpectFailure
Assert (([IO.File]::ReadAllText($legacy13.entry)).Contains('CCS21_AG_ADAPTER_START')) 'Refused nested helper still altered its entry.'
[IO.File]::WriteAllBytes($legacy13Helper,$legacy13HelperBytes)
$null=InvokeRepair @('-ProfileDir',$legacy13.root,'-NonInteractive')
Assert ((Hash ([IO.File]::ReadAllBytes($legacy13.entry))) -eq (Hash $bomSource)) 'v1.3 migration did not preserve original BOM bytes.'
$null=InvokeRepair @('-ExtensionDir',$legacy13.root,'-Restore')
Assert ((Hash ([IO.File]::ReadAllBytes($legacy13.entry))) -eq (Hash $bomSource)) 'v1.3 restore changed original bytes.'
$esm=Fixture 'future ESM\extension' '500.1.0' './entry.mjs'
$null=InvokeRepair @('-ExtensionDir',$esm.root,'-CheckOnly') -ExpectFailure
Assert ([IO.File]::ReadAllText((Join-Path $esm.root 'package.json')) -eq $esm.manifest) 'Unsupported architecture was modified.'
$readOnly=Fixture 'read-only destination\extension' '8.0.0'
$readOnlyPackage=Join-Path $readOnly.root 'package.json'
[IO.File]::SetAttributes($readOnlyPackage,[IO.FileAttributes]::ReadOnly)
try {
    $null=InvokeRepair @('-ExtensionDir',$readOnly.root) -ExpectFailure
    Assert ([IO.File]::ReadAllText($readOnlyPackage) -eq $readOnly.manifest) 'Failed transaction altered its original manifest.'
    Assert (-not [IO.File]::Exists((Join-Path $readOnly.root 'ccs-antigravity-entry.cjs'))) 'Failed transaction left its new wrapper installed.'
    Assert (-not [IO.File]::Exists((Join-Path $readOnly.root '.ccs-antigravity-state.json'))) 'Failed transaction left active repair metadata.'
} finally {[IO.File]::SetAttributes($readOnlyPackage,[IO.FileAttributes]::Normal)}
Write-Output 'PASS: arbitrary versions and paths; Unicode/spaces; metadata discovery; multiple copies; preserved original source; repeat repair; missing-runtime recovery; local-edit refusal; exact restore; official update; v1.2/v1.3 migration; long-path backup; nested helper validation; BOM preservation; legacy switch compatibility; unsupported architecture preservation; failed-write rollback.'
