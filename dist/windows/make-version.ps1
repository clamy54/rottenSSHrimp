# Extrait RSSH_VERSION de src\util\uVersion.pas et genere version.iss.
# Lance par rottensshrimp.iss a la compilation, comme make-notices.ps1.
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here '..\..\src\util\uVersion.pas'

$m = Select-String -LiteralPath $src -Pattern "RSSH_VERSION\s*=\s*'([^']+)'" |
    Select-Object -First 1
if (-not $m) {
    Write-Host "RSSH_VERSION introuvable dans $src"
    exit 1
}
$ver = $m.Matches[0].Groups[1].Value

Set-Content -LiteralPath (Join-Path $here 'version.iss') `
    -Value "#define AppVersion `"$ver`"" -Encoding ASCII
Write-Host "version.iss genere: AppVersion=$ver"
exit 0
