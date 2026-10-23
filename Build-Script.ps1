$ErrorActionPreference = 'Stop'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.template.ps1'))
$adapter = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ccs21-antigravity-proxy.cjs')).TrimEnd([char[]]"`r`n")
$discovery = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ccs-discovery.ps1'))
if (-not $template.Contains('__EMBED_ADAPTER__')) { throw 'Adapter placeholder missing.' }
if (-not $template.Contains('__EMBED_DISCOVERY__')) { throw 'Discovery placeholder missing.' }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.ps1'),$template.Replace('__EMBED_ADAPTER__',$adapter).Replace('__EMBED_DISCOVERY__',$discovery),[Text.UTF8Encoding]::new($false))
Write-Host 'Built standalone Fix-CCS21-Antigravity.ps1.'

