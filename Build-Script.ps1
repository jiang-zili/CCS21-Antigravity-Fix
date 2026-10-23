$ErrorActionPreference = 'Stop'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.template.ps1'))
$parts = @{
    '__EMBED_ADAPTER__' = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ccs21-antigravity-proxy.cjs')).TrimEnd([char[]]"`r`n")
    '__EMBED_ENTRY__' = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ccs-antigravity-entry.cjs')).TrimEnd([char[]]"`r`n")
    '__EMBED_PARSER_BASE64__' = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'vendor/acorn.cjs')))
    '__EMBED_LICENSE_BASE64__' = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'vendor/ACORN-LICENSE')))
}
foreach ($part in $parts.Keys) {
    if (-not $template.Contains($part)) { throw ('Missing build placeholder: '+$part) }
    if ($parts[$part] -match '(?m)^''@') { throw 'Embedded source would close the PowerShell here-string.' }
    $template=$template.Replace($part,$parts[$part])
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Fix-CCS21-Antigravity.ps1'),$template,[Text.UTF8Encoding]::new($false))
$releaseFiles=@('.gitattributes','.gitignore','Build-Script.ps1','CHANGELOG.md','Fix-CCS21-Antigravity.ps1','Fix-CCS21-Antigravity.template.ps1','README.md','Run-Check.cmd','Run-Fix.cmd','Run-Restore.cmd','ccs-discovery.ps1','ccs21-antigravity-proxy.cjs','ccs-antigravity-entry.cjs','test-adapter.cjs','test-backend.cjs','test-installer.ps1','vendor/acorn.cjs','vendor/ACORN-LICENSE','vendor/README.md')
$checksums=foreach ($file in ($releaseFiles | Sort-Object)) {
    $hash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file) -Algorithm SHA256).Hash.ToLowerInvariant()
    $hash+'  '+$file
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'SHA256SUMS.txt'),($checksums -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
Write-Host 'Built standalone Fix-CCS21-Antigravity.ps1 and SHA256SUMS.txt.'
