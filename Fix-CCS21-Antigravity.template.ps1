#requires -Version 5.1
<#
Discovers installations by manifest identity and adapts the Webview API.
Generated standalone script includes all runtime files and works offline.
#>
[CmdletBinding()]
param(
    [string[]]$ExtensionDir,
    [Alias('ScanRoot','ProfileDir')][string[]]$SearchRoot,
    [string]$CcsExe,
    [string]$NodeExe,
    [string[]]$BackendUrl,
    [string]$ReportDir,
    [switch]$DeepScan,
    [switch]$CheckOnly,
    [switch]$Restore,
    [switch]$NoRestart,
    [switch]$NonInteractive,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolVersion = '2.0.0'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$adapter = @'
__EMBED_ADAPTER__
'@
$entryWrapper = @'
__EMBED_ENTRY__
'@
$parser = [Convert]::FromBase64String('__EMBED_PARSER_BASE64__')
$parserLicense = [Convert]::FromBase64String('__EMBED_LICENSE_BASE64__')
$wrapperName = 'ccs-antigravity-entry.cjs'
$stateName = '.ccs-antigravity-state.json'
$payload = [ordered]@{
    'ccs-antigravity-adapter.cjs' = $utf8.GetBytes($adapter)
    'ccs-antigravity-entry.cjs' = $utf8.GetBytes($entryWrapper)
    'ccs-antigravity-acorn.cjs' = $parser
    'ccs-antigravity-acorn-LICENSE' = $parserLicense
}
$discoveries = New-Object 'System.Collections.Generic.List[object]'
$discoveryPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$ccsExecutables = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$warnings = New-Object 'System.Collections.Generic.List[string]'

function FullPath([string]$value) {
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if (-not [IO.Path]::IsPathRooted($value)) { $value = [IO.Path]::Combine((Get-Location).Path,$value) }
    if ($value.Length -gt 240 -and -not $value.StartsWith('\\?\')) {
        if ($value.StartsWith('\\')) { $value = '\\?\UNC\' + $value.Substring(2) }
        else { $value = '\\?\' + $value }
    }
    $full=[IO.Path]::GetFullPath($value)
    $root=[IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd([char[]]'\/').Length -lt $root.Length) { return $root }
    return $full.TrimEnd([char[]]'\/')
}
function PathKey([string]$value) {
    $value=[IO.Path]::GetFullPath($value)
    if ($value.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { $value='\\'+$value.Substring(8) }
    elseif ($value.StartsWith('\\?\')) { $value=$value.Substring(4) }
    return $value.TrimEnd([char[]]'\/')
}
function Within([string]$root,[string]$relative) {
    if ([IO.Path]::IsPathRooted($relative)) { throw 'Expected an installation-relative path.' }
    $prefix = (PathKey $root) + [IO.Path]::DirectorySeparatorChar
    $result = FullPath ([IO.Path]::Combine($root,$relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
    if (-not (PathKey $result).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes its extension directory.' }
    return $result
}
function HashBytes([byte[]]$bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','') }
    finally { $algorithm.Dispose() }
}
function ReadBytes([string]$file) { return ,([IO.File]::ReadAllBytes($file)) }
function FileHash([string]$file) { return HashBytes (ReadBytes $file) }
function ReadJson([string]$file) { return [IO.File]::ReadAllText($file) | ConvertFrom-Json }
function JsonBytes($value) { return ,($utf8.GetBytes(($value | ConvertTo-Json -Depth 20))) }
function Property($value,[string]$name,$fallback=$null) {
    if ($null -ne $value -and $value.PSObject.Properties[$name]) { return $value.$name }
    return $fallback
}
function WriteAtomic([string]$file,[byte[]]$bytes) {
    $temporary = FullPath ($file + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = FullPath ($temporary + '.previous')
    try {
        [IO.File]::WriteAllBytes($temporary,$bytes)
        if ([IO.File]::Exists($file)) { [IO.File]::Replace($temporary,$file,$previous) }
        else { [IO.File]::Move($temporary,$file) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
    }
}
function Transaction($files) {
    $before = [ordered]@{}
    foreach ($file in $files.Keys) {
        if ([IO.File]::Exists($file)) { $before[$file] = ReadBytes $file } else { $before[$file] = $null }
    }
    try {
        foreach ($file in $files.Keys) {
            if ($null -eq $files[$file]) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
            else { WriteAtomic $file $files[$file]; if ((FileHash $file) -ne (HashBytes $files[$file])) { throw 'Post-write integrity check failed.' } }
        }
    } catch {
        $failure = $_
        $rollbackErrors=@()
        foreach ($file in $before.Keys) {
            try {
                if ($null -eq $before[$file]) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
                elseif (-not [IO.File]::Exists($file) -or (FileHash $file) -ne (HashBytes $before[$file])) { WriteAtomic $file $before[$file] }
            } catch { $rollbackErrors+=$_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw ('Write failed and rollback needs attention: '+($rollbackErrors -join '; ')) }
        throw $failure
    }
}
function SetManifestMain([string]$text,[string]$main) {
    # Locate the root JSON property, preserving every other byte of text.
    $depth=0; $locations=@()
    foreach ($token in [regex]::Matches($text,'"(?:\\.|[^"\\])*"|[{}\[\]]')) {
        if ($token.Value -eq '{' -or $token.Value -eq '[') { $depth++; continue }
        if ($token.Value -eq '}' -or $token.Value -eq ']') { $depth--; continue }
        if ($depth -eq 1 -and $token.Value -eq '"main"') {
            $value = [regex]::Match($text.Substring($token.Index+$token.Length),'^\s*:\s*("(?:\\.|[^"\\])*")')
            if ($value.Success) { $locations += [PSCustomObject]@{ Start=$token.Index+$token.Length+$value.Groups[1].Index; Length=$value.Groups[1].Length } }
        }
    }
    if ($locations.Count -ne 1) { throw 'Expected one root main property in package.json.' }
    $location=$locations[0]
    return $text.Substring(0,$location.Start)+($main | ConvertTo-Json -Compress)+$text.Substring($location.Start+$location.Length)
}
function ResolveEntry([string]$root,[string]$main,[int]$level=0) {
    if ($level -gt 5) { throw 'Cyclic extension main resolution.' }
    $base = Within $root $main
    foreach ($candidate in @($base,($base+'.js'),($base+'.cjs'),($base+'.mjs'))) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    if ([IO.Directory]::Exists($base)) {
        $nestedManifest=[IO.Path]::Combine($base,'package.json')
        if ([IO.File]::Exists($nestedManifest)) {
            $nested=Property (ReadJson $nestedManifest) 'main'
            if ($nested) {
                $relative=(PathKey $base).Substring((PathKey $root).Length+1)+'/'+$nested
                return ResolveEntry $root $relative ($level+1)
            }
        }
        foreach ($index in @('index.js','index.cjs')) { if ([IO.File]::Exists([IO.Path]::Combine($base,$index))) { return [IO.Path]::Combine($base,$index) } }
    }
    throw 'The manifest entry point does not exist.'
}
function AddInstallation([string]$directory) {
    $directory=FullPath $directory
    if ($discoveryPaths.Contains($directory)) { return $true }
    $file=[IO.Path]::Combine($directory,'package.json')
    if (-not [IO.File]::Exists($file)) { return $false }
    try {
        $package=ReadJson $file
        if ((Property $package 'publisher') -ne 'google' -or (Property $package 'name') -ne 'google-antigravity') { return $false }
        [void]$discoveryPaths.Add($directory)
        $discoveries.Add([PSCustomObject]@{Path=$directory;Version=[string](Property $package 'version' 'unspecified');Package=$package})
        return $true
    } catch { return $false }
}
function ScanDirectories([string[]]$roots,[int]$maxDepth) {
    $visited=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queue=New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($root in $roots) { if ($root) { try { $queue.Enqueue([PSCustomObject]@{Path=(FullPath $root);Depth=0}) } catch {} } }
    $count=0
    while ($queue.Count) {
        $item=$queue.Dequeue(); $directory=$item.Path
        try {
            if (-not [IO.Directory]::Exists($directory)) { continue }
            $attributes=[IO.File]::GetAttributes($directory)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $target=Property (Get-Item -LiteralPath $directory -Force -ErrorAction Stop) 'Target'
                if (-not $target) { continue }
                $target=[string](@($target)[0])
                if (-not [IO.Path]::IsPathRooted($target)) { $target=[IO.Path]::Combine([IO.Path]::GetDirectoryName($directory),$target) }
                $directory=FullPath $target
            }
            if (-not $visited.Add($directory)) { continue }
            $count++
            if ($count % 500 -eq 0 -and -not $Json) { Write-Progress -Activity 'Finding Antigravity installations' -Status ($count.ToString()+' folders checked') }
            if (AddInstallation $directory) { continue }
            $executable=[IO.Path]::Combine($directory,'ccstudio.exe')
            if ([IO.File]::Exists($executable)) { [void]$ccsExecutables.Add($executable) }
            if ($item.Depth -ge $maxDepth) { continue }
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                $leaf=[IO.Path]::GetFileName($child)
                if ($leaf -in @('.git','$Recycle.Bin','System Volume Information','AgentOutput','ccs21-antigravity-backup','ccs-antigravity-backup')) { continue }
                if ($maxDepth -lt [int]::MaxValue -and $leaf -eq 'node_modules') { continue }
                $queue.Enqueue([PSCustomObject]@{Path=$child;Depth=$item.Depth+1})
            }
        } catch { continue }
    }
    if (-not $Json) { Write-Progress -Activity 'Finding Antigravity installations' -Completed }
}
function AutoRoots {
    $roots=New-Object 'System.Collections.Generic.List[string]'
    $profiles=@($env:LOCALAPPDATA,$env:APPDATA,[Environment]::GetFolderPath('LocalApplicationData'),[Environment]::GetFolderPath('ApplicationData'))
    if ($env:USERPROFILE) { $profiles+=@([IO.Path]::Combine($env:USERPROFILE,'AppData\Local'),[IO.Path]::Combine($env:USERPROFILE,'AppData\Roaming')) }
    foreach ($profile in $profiles | Where-Object { $_ } | Sort-Object -Unique) {
        $roots.Add([IO.Path]::Combine($profile,'Texas Instruments\CCS'))
        $roots.Add([IO.Path]::Combine($profile,'CCStudio'))
    }
    foreach ($process in @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue)) {
        try { if ($process.Path) { [void]$ccsExecutables.Add($process.Path);$roots.Add([IO.Path]::GetDirectoryName($process.Path)) } } catch {}
    }
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='ccstudio.exe'" -ErrorAction Stop)) {
            if ($process.ExecutablePath) { [void]$ccsExecutables.Add([string]$process.ExecutablePath) }
            foreach ($match in [regex]::Matches([string]$process.CommandLine,'(?:^|\s)--(?:user-data-dir|plugins|extensions-dir)(?:=|\s+)(?:"(?<path>[^"]+)"|(?<path>[^\s]+))')) {
                $launchPath=$match.Groups['path'].Value -replace '^local-dir:',''
                $roots.Add($launchPath)
                $parent=[IO.Path]::GetDirectoryName($launchPath)
                if ($parent -and [IO.Directory]::Exists([IO.Path]::Combine($parent,'theia'))) { $roots.Add([IO.Path]::Combine($parent,'theia')) }
            }
        }
    } catch { $warnings.Add('Process launch paths unavailable; using configuration and filesystem discovery.') }
    foreach ($hint in @($CcsExe,$env:CCS_HOME,$env:CCS_INSTALL_DIR,$env:TI_CCS_ROOT)) {
        if (-not $hint) { continue }
        $hint=FullPath $hint
        if ([IO.Directory]::Exists($hint)) {
            $roots.Add($hint)
            foreach ($relative in @('ccstudio.exe','theia/ccstudio.exe','ccs/theia/ccstudio.exe')) {
                $candidate=FullPath ([IO.Path]::Combine($hint,$relative))
                if ([IO.File]::Exists($candidate)) { [void]$ccsExecutables.Add($candidate) }
            }
        } elseif ([IO.File]::Exists($hint)) { [void]$ccsExecutables.Add($hint) }
    }
    foreach ($executable in @($ccsExecutables)) {
        $parent=[IO.Path]::GetDirectoryName($executable)
        for ($i=0;$i -lt 3 -and $parent;$i++) { $roots.Add($parent);$parent=[IO.Path]::GetDirectoryName($parent) }
    }
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($record in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ([string](Property $record 'DisplayName') -notmatch 'Code Composer|CCStudio|Texas Instruments.*CCS') { continue }
            $location=Property $record 'InstallLocation';if ($location) { $roots.Add([string]$location) }
            $icon=[regex]::Match([string](Property $record 'DisplayIcon'),'^(?:"(?<file>[^"]+\.exe)"|(?<file>[^,]+\.exe))')
            if ($icon.Success) { $roots.Add([IO.Path]::GetDirectoryName($icon.Groups['file'].Value)) }
        }
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        foreach ($name in @('ti','Texas Instruments')) {
            $base=[IO.Path]::Combine($drive.Root,$name)
            if ([IO.Directory]::Exists($base)) {
                try { foreach ($candidate in [IO.Directory]::EnumerateDirectories($base)) { if ([IO.Path]::GetFileName($candidate) -match '^(?:ccs|ccstudio)') { $roots.Add($candidate) } } } catch {}
            }
        }
    }
    foreach ($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)) {
        if ($base) { $roots.Add([IO.Path]::Combine($base,'Texas Instruments'));$roots.Add([IO.Path]::Combine($base,'ti')) }
    }
    return @($roots | Sort-Object -Unique)
}
function GetLegacy([string]$root,[string]$entryFile,[string]$current) {
    $backupFile=$null; $original=$null
    if ($current.Contains('/*CCS21_AG_ADAPTER_START*/')) {
        $legacyRoot=Within $root 'AgentOutput/CCS21-Antigravity'
        $manifest=ReadJson ([IO.Path]::Combine($legacyRoot,'installed.json'))
        if ((FileHash $entryFile) -ne $manifest.patchedSha256) { throw 'The previous repair has unrecognized source edits.' }
        $backupFile=FullPath ([string]$manifest.originalFile)
        if (-not (PathKey $backupFile).StartsWith((PathKey $legacyRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($backupFile)) {
            $backupFile=FullPath ([IO.Path]::Combine($legacyRoot,([string]$manifest.originalSha256).Substring(0,12),'extension.js.original'))
        }
        if ((FileHash $backupFile) -ne $manifest.originalSha256) { throw 'Previous repair backup failed integrity validation.' }
        $oldHelper=FullPath ([IO.Path]::Combine([IO.Path]::GetDirectoryName($entryFile),'ccs21-antigravity-proxy.cjs'))
        if ([IO.File]::Exists($oldHelper) -and (FileHash $oldHelper) -ne $manifest.adapterSha256) { throw 'The previous adapter has local edits.' }
        $original=ReadBytes $backupFile
    } elseif ($current.Contains('require("./ccs21-antigravity-proxy.cjs")')) {
        $backupFile=Within $root 'ccs21-antigravity-backup/extension.js.original'
        $original=ReadBytes $backupFile
        $old='renderIframe(a,b,c){var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
        $patched='async renderIframe(a,b,c){if(String(a.cspSource||"").includes(".webview.localhost")){var p=require("./ccs21-antigravity-proxy.cjs"),o=p.getTheiaWebviewOrigin(a,l.Uri.joinPath(this.context.extensionUri,"bridge.js"));b=await p.getProxyUrl(b,o,this.context);console.log("[Antigravity CCS adapter] Exact-origin proxy ready")}var d=this.buildIframeUrl(b,c);console.log(`[Jetski] Loading iframe URL: ${cu(d)}`);this.renderWebviewHtml(a,b,d,c)}'
        $baseline=$utf8.GetString($original)
        if (-not $baseline.Contains($old) -or $baseline.Replace($old,$patched) -ne $current) { throw 'The legacy source cannot be restored without discarding local edits.' }
    }
    if ($null -ne $original) { return [PSCustomObject]@{Bytes=$original;Path=$entryFile} }
    return $null
}
function PlanInstallation($installation) {
    $root=$installation.Path; $manifestFile=Within $root 'package.json';$stateFile=Within $root $stateName
    $currentPackage=ReadBytes $manifestFile;$currentText=[IO.File]::ReadAllText($manifestFile)
    $main=[string](Property $installation.Package 'main')
    if (-not $main) { throw 'This package has no Node extension entry point.' }
    $state=$null; $migration=$null; $missing=@()
    if ($main.TrimStart([char[]]'./') -eq $wrapperName) {
        if (-not [IO.File]::Exists($stateFile)) { throw 'Repair metadata is missing; refusing to guess the original entry.' }
        $state=ReadJson $stateFile
        if ((FileHash $manifestFile) -ne $state.manifestSha256) { throw 'The repaired package manifest has local edits.' }
        $originalManifestFile=Within $root $state.manifestBackup
        if ((FileHash $originalManifestFile) -ne $state.originalManifestSha256) { throw 'The manifest backup failed integrity validation.' }
        $originalPackage=ReadBytes $originalManifestFile
        $main=[string]$state.originalMain
        foreach ($file in $state.files.PSObject.Properties) {
            $target=Within $root $file.Name
            if (-not [IO.File]::Exists($target)) { $missing+=$file.Name;continue }
            if ([IO.File]::Exists($target) -and (FileHash $target) -ne $file.Value) { throw ('Local changes found in '+$file.Name+'.') }
        }
        $migration=Property $state 'migration'
        if ($migration -and (FileHash (Within $root $migration.entry)) -ne $migration.originalSha256) { throw 'The migrated original entry has local edits.' }
    } else {
        $originalPackage=$currentPackage
        $previousRepair=$null
        if ([IO.File]::Exists($stateFile)) { $previousRepair=ReadJson $stateFile }
        foreach ($name in $payload.Keys) {
            $target=Within $root $name
            if (-not [IO.File]::Exists($target)) { continue }
            $expected=Property (Property $previousRepair 'files') $name
            if (-not $expected -or (FileHash $target) -ne $expected) { throw ('An untracked or edited file would be overwritten: '+$name) }
        }
    }
    $originalManifest=$utf8.GetString($originalPackage).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $entryFile=ResolveEntry $root $main
    if ([IO.Path]::GetExtension($entryFile) -eq '.mjs' -or (Property $originalManifest 'type') -eq 'module') { throw 'Native ESM extension entry points need a different host bridge; files were preserved.' }
    $legacy=$null
    if (-not $state) { $legacy=GetLegacy $root $entryFile ([IO.File]::ReadAllText($entryFile)) }
    $manifestHash=HashBytes $originalPackage
    $backupRelative='ccs-antigravity-backup/'+$manifestHash.Substring(0,16)
    $backupManifest=$backupRelative+'/package.original.json'
    $patchedManifest=$utf8.GetBytes((SetManifestMain ($utf8.GetString($originalPackage).TrimStart([char]0xFEFF)) ('./'+$wrapperName)))
    $hashes=[ordered]@{};foreach ($name in $payload.Keys) { $hashes[$name]=HashBytes $payload[$name] }
    if ($legacy) {
        $relativeEntry=(PathKey $entryFile).Substring((PathKey $root).Length+1)
        $migration=[PSCustomObject]@{entry=$relativeEntry;backup=($backupRelative+'/entry.original');originalSha256=(HashBytes $legacy.Bytes)}
    }
    $nextState=[ordered]@{toolVersion=$toolVersion;originalMain=$main;manifestBackup=$backupManifest;originalManifestSha256=$manifestHash;manifestSha256=(HashBytes $patchedManifest);files=$hashes;migration=$migration}
    return [PSCustomObject]@{Root=$root;Version=$installation.Version;Entry=$entryFile;OriginalPackage=$originalPackage;PatchedPackage=$patchedManifest;BackupManifest=$backupManifest;State=$state;NextState=$nextState;Legacy=$legacy;Migration=$migration;Status=$(if ($missing.Count) {'Incomplete-runtime'} elseif ($state) {'Installed'} elseif ($legacy) {'Legacy-adapter'} else {'Ready'})}
}

if ($CheckOnly -and $Restore) { throw 'Use either -CheckOnly or -Restore.' }
if ($ExtensionDir -and $SearchRoot) { throw 'Use -ExtensionDir or -SearchRoot, not both.' }
$mode='automatic'
if ($ExtensionDir) {
    $mode='explicit'
    foreach ($directory in $ExtensionDir) { if (-not (AddInstallation $directory)) { throw 'An explicit extension directory does not contain a Google Antigravity manifest.' } }
} elseif ($SearchRoot) { $mode='search-roots';ScanDirectories $SearchRoot ([int]::MaxValue) }
else {
    ScanDirectories (AutoRoots) 9
    if ($DeepScan -or $discoveries.Count -eq 0) {
        $mode='full-disk-fallback'
        if (-not $Json) { Write-Host 'Searching accessible filesystem drives. This may take time.' }
        ScanDirectories @((Get-PSDrive -PSProvider FileSystem | Where-Object { [IO.Directory]::Exists($_.Root) }).Root) ([int]::MaxValue)
    }
}
if ($discoveries.Count -eq 0) { throw 'No installed Google Antigravity package was found. Inaccessible or unmapped network roots require -SearchRoot.' }
$plans=New-Object 'System.Collections.Generic.List[object]'
$results=New-Object 'System.Collections.Generic.List[object]'
foreach ($installation in $discoveries) {
    try { $plans.Add((PlanInstallation $installation)) }
    catch { $results.Add([PSCustomObject]@{path=$installation.Path;version=$installation.Version;status='unsupported-or-modified';reason=$_.Exception.Message}) }
}

# Backend checks are optional when the IDE is closed; otherwise validate actual
# scripts, including hashed filenames, before any installation is modified.
$backendChecks=@()
if (-not $Restore) {
    if (-not $BackendUrl) {
        $ports=@()
        try { $processes=@(Get-CimInstance Win32_Process -Filter "Name='agy.exe'" -ErrorAction Stop) } catch { $processes=@() }
        foreach ($process in $processes) {
            $match=[regex]::Match([string]$process.CommandLine,'(?:^|\s)--(?:hub-port|port)(?:=|\s+)(\d+)(?:\s|$)')
            if ($match.Success) { $ports+=('http://127.0.0.1:'+$match.Groups[1].Value) }
        }
        $BackendUrl=@($ports | Sort-Object -Unique)
    }
    if (@($BackendUrl).Count -gt 0) {
        foreach ($value in $BackendUrl) {
            $url=New-Object Uri($value)
            if ($url.Scheme -ne 'http' -or $url.Host -notin @('localhost','127.0.0.1','[::1]','::1') -or $url.UserInfo -or $url.Query -or $url.Fragment -or $url.AbsolutePath -ne '/') { throw 'BackendUrl must be one HTTP loopback origin without credentials or query parameters.' }
        }
        if (-not $NodeExe) {
            $command=Get-Command node.exe -ErrorAction SilentlyContinue
            if ($command) { $NodeExe=$command.Source }
        }
        if (-not $NodeExe) {
            if ($CcsExe) { [void]$ccsExecutables.Add((FullPath $CcsExe)) }
            foreach ($process in @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue)) {
                try { if ($process.Path) { [void]$ccsExecutables.Add($process.Path) } } catch {}
            }
            foreach ($executable in @($ccsExecutables)) {
                if ([IO.Directory]::Exists($executable)) { $parent=$executable }
                else { $parent=[IO.Path]::GetDirectoryName($executable) }
                for ($i=0;$i -lt 4 -and $parent;$i++) {
                    foreach ($relative in @('node.exe','node/node.exe','tools/node/node.exe','ccs/tools/node/node.exe')) {
                        $candidate=[IO.Path]::Combine($parent,$relative)
                        if ([IO.File]::Exists($candidate)) { $NodeExe=$candidate;break }
                    }
                    if ($NodeExe) { break };$parent=[IO.Path]::GetDirectoryName($parent)
                }
                if ($NodeExe) { break }
            }
        }
        if (-not $NodeExe -or -not [IO.File]::Exists($NodeExe)) { throw 'No Node runtime was found for the running backend check. Pass -CcsExe or -NodeExe.' }
        $probeRoot=[IO.Path]::Combine([IO.Path]::GetTempPath(),('ccs-antigravity-check-'+[Guid]::NewGuid().ToString('N')))
        [void][IO.Directory]::CreateDirectory($probeRoot)
        try {
            foreach ($name in @('ccs-antigravity-adapter.cjs','ccs-antigravity-acorn.cjs')) { [IO.File]::WriteAllBytes([IO.Path]::Combine($probeRoot,$name),$payload[$name]) }
            foreach ($url in $BackendUrl) {
                $output=& $NodeExe ([IO.Path]::Combine($probeRoot,'ccs-antigravity-adapter.cjs')) --check-backend $url 2>&1
                if ($LASTEXITCODE -ne 0) { throw ('Backend compatibility check failed before writing: '+($output -join ' ')) }
                $backendChecks+=($output -join '') | ConvertFrom-Json
            }
        } finally {
            foreach ($name in @('ccs-antigravity-adapter.cjs','ccs-antigravity-acorn.cjs')) { $file=[IO.Path]::Combine($probeRoot,$name);if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
            [IO.Directory]::Delete($probeRoot,$false)
        }
    }
}
foreach ($plan in $plans) {
    try {
        if ($CheckOnly) { $status=$plan.Status }
        elseif ($Restore) {
            $changes=[ordered]@{}
            if ($plan.State) {
                $changes[(Within $plan.Root 'package.json')]=$plan.OriginalPackage
                if ($plan.Migration) { $changes[(Within $plan.Root $plan.Migration.entry)]=ReadBytes (Within $plan.Root $plan.Migration.backup) }
                foreach ($name in $payload.Keys) { $changes[(Within $plan.Root $name)]=$null }
                $changes[(Within $plan.Root $stateName)]=$null
            } elseif ($plan.Legacy) { $changes[$plan.Entry]=$plan.Legacy.Bytes }
            if ($changes.Count) { Transaction $changes }
            $status='restored'
        } else {
            $backupFile=Within $plan.Root $plan.BackupManifest
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupFile))
            if ([IO.File]::Exists($backupFile)) { if ((FileHash $backupFile) -ne (HashBytes $plan.OriginalPackage)) { throw 'Existing manifest backup belongs to a different original.' } }
            else { WriteAtomic $backupFile $plan.OriginalPackage }
            if ($plan.Legacy) {
                $sourceBackup=Within $plan.Root $plan.Migration.backup
                if ([IO.File]::Exists($sourceBackup)) { if ((FileHash $sourceBackup) -ne $plan.Migration.originalSha256) { throw 'Existing source backup has changed.' } }
                else { WriteAtomic $sourceBackup $plan.Legacy.Bytes }
            }
            $changes=[ordered]@{}
            if ($plan.Legacy) { $changes[$plan.Entry]=$plan.Legacy.Bytes }
            foreach ($name in $payload.Keys) { $changes[(Within $plan.Root $name)]=$payload[$name] }
            $changes[(Within $plan.Root $stateName)]=JsonBytes $plan.NextState
            $changes[(Within $plan.Root 'package.json')]=$plan.PatchedPackage
            Transaction $changes
            $status='installed-restart-required'
        }
        $results.Add([PSCustomObject]@{path=$plan.Root;version=$plan.Version;entry=$plan.Entry;status=$status})
    } catch { $results.Add([PSCustomObject]@{path=$plan.Root;version=$plan.Version;status='failed';reason=$_.Exception.Message}) }
}
$report=[PSCustomObject]@{toolVersion=$toolVersion;discoveryMode=$mode;backendStatus=$(if ($backendChecks.Count) {'verified'} else {'deferred-until-activation'});backendChecks=$backendChecks;uiVerified=$false;installations=@($results.ToArray())}
if (-not $CheckOnly) {
    if (-not $ReportDir) { $ReportDir=[IO.Path]::Combine($PSScriptRoot,'AgentOutput') }
    [void][IO.Directory]::CreateDirectory((FullPath $ReportDir))
    $reportFile=[IO.Path]::Combine((FullPath $ReportDir),('repair-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')+'.json'))
    WriteAtomic $reportFile (JsonBytes $report)
}
if ($Json) { $report | ConvertTo-Json -Depth 20 }
else {
    $results | Select-Object version,status,path,reason | Format-Table -AutoSize
    Write-Host ('Backend check: '+$report.backendStatus+'. File installation does not prove UI success.')
    if (-not $CheckOnly) { Write-Host ('Report: '+$reportFile) }
}
if (@($results | Where-Object { $_.status -in @('failed','unsupported-or-modified') }).Count) { throw 'Some installations were preserved because they need attention. See the results above.' }
if ($CheckOnly -or $NoRestart) { if (-not $CheckOnly -and -not $Json) { Write-Host 'Restart CCS to refresh its extension manifest, then verify chat and Settings.' };return }
$running=@(Get-Process -Name ccstudio -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
if ($running.Count -eq 1) {
    $runningExe=$running[0].Path
    if ($CcsExe -and [IO.File]::Exists($CcsExe) -and (PathKey $CcsExe) -ine (PathKey $runningExe)) { Write-Warning 'The running CCS is a different installation. Restart the repaired installation manually.';return }
    $CcsExe=$runningExe
    try { $launch=Get-CimInstance Win32_Process -Filter ('ProcessId='+$running[0].Id) -ErrorAction Stop } catch { $launch=$null }
    if (-not $launch -or [string]$launch.CommandLine -notmatch '^\s*(?:"[^"]+"|\S+)\s*(?<arguments>[\s\S]*)$') {
        Write-Warning 'Original launch arguments are unavailable. Restart CCS manually to retain its profile and workspace.';return
    }
    $restartArguments=$Matches['arguments']
    if (-not $running[0].CloseMainWindow() -or -not $running[0].WaitForExit(30000)) { Write-Warning 'CCS is still open. Complete its Save dialog, then restart manually.';return }
} elseif ($running.Count -gt 1 -or @(Get-Process -Name ccstudio -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Warning 'Multiple or unidentifiable CCS windows remain open. Restart them manually; no process was force-killed.';return
} else {
    if (-not $Json) { Write-Host 'Open CCS to verify the repaired views. No duplicate instance was started.' };return
}
if ($CcsExe -and [IO.File]::Exists($CcsExe)) {
    if ($restartArguments) { Start-Process -FilePath $CcsExe -ArgumentList $restartArguments -WindowStyle Hidden }
    else { Start-Process -FilePath $CcsExe -WindowStyle Hidden }
}
elseif (-not $Json) { Write-Host 'Open CCS manually to verify the repaired views.' }
