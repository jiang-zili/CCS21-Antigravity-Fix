# Discovery is based on package identity and executable structure, never folder/version names.
function IOPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}
function Read-Property($Value, [string]$Name) {
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $null
}
function Get-CcsProcesses {
    try { return @(Get-CimInstance Win32_Process -Filter "Name='ccstudio.exe' OR Name='agy.exe'" -ErrorAction Stop) }
    catch {
        Write-Verbose 'Process command lines unavailable; using executable paths and explicit search roots.'
        return @(Get-Process -Name ccstudio,agy -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Name=($_.ProcessName + '.exe'); ExecutablePath=$_.Path; CommandLine=''; ProcessId=$_.Id }
        })
    }
}
function Get-LaunchPath([string]$CommandLine, [string]$Option) {
    $pattern = '(?:^|\s)--' + [regex]::Escape($Option) + '(?:=|\s+)(?:"(?<quoted>[^"]+)"|(?<plain>[^\s]+))'
    foreach ($match in [regex]::Matches($CommandLine,$pattern)) {
        if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value }
        else { $match.Groups['plain'].Value }
    }
}
function Get-SearchDirectories([string[]]$Roots, [int]$Depth=6) {
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $queue.Enqueue([PSCustomObject]@{ Path=[IO.Path]::GetFullPath($root); Level=0 })
    }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if (-not $visited.Add($item.Path)) { continue }
        $item.Path
        if ($item.Level -ge $Depth) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $dir.Name -in @('node_modules','.git','AgentOutput')) { continue }
            $queue.Enqueue([PSCustomObject]@{ Path=$dir.FullName; Level=($item.Level+1) })
        }
    }
}
function Get-AntigravityPackage([string]$Directory) {
    $manifestPath = Join-Path $Directory 'package.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    try {
        $pkg = [IO.File]::ReadAllText((IOPath $manifestPath)) | ConvertFrom-Json
        if ((Read-Property $pkg 'publisher') -ne 'google' -or (Read-Property $pkg 'name') -ne 'google-antigravity') { return }
        $main = [string](Read-Property $pkg 'main')
        if (-not $main) { $main = 'extension.js' }
        $root = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]'\/')
        $entry = [IO.Path]::GetFullPath((Join-Path $root $main))
        if (-not [IO.Path]::HasExtension($entry)) { $entry += '.js' }
        if (-not $entry.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package main escapes its extension directory.' }
        if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { return }
        [PSCustomObject]@{ Directory=$root; Entry=$entry; Package=$pkg; Version=[string](Read-Property $pkg 'version') }
    } catch { Write-Verbose ('Cannot use extension package ' + $Directory + ': ' + $_.Exception.Message) }
}
function Find-AntigravityExtensions([string[]]$Roots) {
    $result = @{}
    foreach ($dir in @(Get-SearchDirectories $Roots)) {
        $candidate = Get-AntigravityPackage $dir
        if ($null -ne $candidate) { $result[$candidate.Directory] = $candidate }
    }
    @($result.Values | Sort-Object Directory)
}
function Resolve-CcsExecutable([string]$Path) {
    if (-not $Path) { return }
    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    $possibilities = @($Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $possibilities = @('ccstudio.exe','theia\ccstudio.exe','ccs\theia\ccstudio.exe') | ForEach-Object { Join-Path $Path $_ }
    }
    foreach ($exe in $possibilities) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or [IO.Path]::GetFileName($exe) -ine 'ccstudio.exe') { continue }
        $exe = [IO.Path]::GetFullPath($exe)
        $node = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $exe) '..\tools\node\node.exe'))
        if ((Test-Path -LiteralPath $node -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) 'resources') -PathType Container)) {
            return [PSCustomObject]@{ Executable=$exe; Node=$node }
        }
    }
}
function Find-CcsInstallations([object[]]$Processes, [string[]]$Roots) {
    $hints = @($Processes | Where-Object { $_.Name -ieq 'ccstudio.exe' } | ForEach-Object { $_.ExecutablePath })
    $running = @{}
    foreach ($hint in $hints) {
        $candidate=Resolve-CcsExecutable $hint
        if ($null -ne $candidate) { $running[$candidate.Executable]=$candidate }
    }
    if ($running.Count -gt 0) { return @($running.Values | Sort-Object Executable) }
    foreach ($name in @('CCS_HOME','CCS_INSTALL_DIR','TI_CCS_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $hints += $value }
    }
    # Registry/shortcut locations are hints, never required install locations.
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($app in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ([string](Read-Property $app 'DisplayName') -match '(?i)Code Composer|CCStudio') {
                $hints += [string](Read-Property $app 'InstallLocation')
                $icon = [string](Read-Property $app 'DisplayIcon')
                if ($icon) { $hints += ($icon -replace ',\s*-?\d+$','').Trim('"') }
            }
        }
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($special in @('Programs','CommonPrograms','Desktop','CommonDesktopDirectory')) {
            $folder = [Environment]::GetFolderPath($special)
            if (-not $folder) { continue }
            foreach ($dir in @(Get-SearchDirectories @($folder) 3)) {
                foreach ($link in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
                    $target = $shell.CreateShortcut($link.FullName).TargetPath
                    if ([IO.Path]::GetFileName($target) -ieq 'ccstudio.exe') { $hints += $target }
                }
            }
        }
    } catch { Write-Verbose 'Shortcut discovery unavailable.' }
    foreach ($dir in @(Get-SearchDirectories $Roots 3)) { $hints += $dir }
    $result = @{}
    foreach ($hint in @($hints | Where-Object { $_ } | Sort-Object -Unique)) {
        $candidate = Resolve-CcsExecutable $hint
        if ($null -ne $candidate) { $result[$candidate.Executable] = $candidate }
    }
    @($result.Values | Sort-Object Executable)
}
function Select-RepairTarget([object[]]$Candidates,[string]$Label,[string]$Property,[switch]$Headless) {
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    if ($Candidates.Count -gt 1 -and -not $Headless) {
        Write-Host ('Multiple ' + $Label + ' found. Select the intended installation:')
        for ($i=0;$i -lt $Candidates.Count;$i++) { Write-Host ('[{0}] {1}' -f ($i+1),$Candidates[$i].$Property) }
        $answer=0
        if ([int]::TryParse((Read-Host 'Number (empty cancels)'),[ref]$answer) -and $answer -ge 1 -and $answer -le $Candidates.Count) { return $Candidates[$answer-1] }
        throw 'Selection cancelled. No files changed.'
    }
    if ($Headless) { throw ('Found ' + $Candidates.Count + ' ' + $Label + '. Specify -ExtensionDir/-CcsExe or -ProfileDir/-SearchRoot; no files changed.') }
    Add-Type -AssemblyName System.Windows.Forms
    if ($Label -eq 'CCS executable') {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title='Select ccstudio.exe at its actual installation location'
        $dialog.Filter='CCStudio (ccstudio.exe)|ccstudio.exe'
    } else {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description='Select the Antigravity extension folder containing package.json'
    }
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw 'Selection cancelled. No files changed.' }
        if ($Label -eq 'CCS executable') { $selected=Resolve-CcsExecutable $dialog.FileName }
        else { $selected=Get-AntigravityPackage $dialog.SelectedPath }
        if ($null -eq $selected) { throw 'Selected location has no compatible installation structure. No files changed.' }
        return $selected
    } finally { $dialog.Dispose() }
}
