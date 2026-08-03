# Build portable (Windows). Localise lazbuild tout seul, chemin .lpi relatif,
# tue l'exe avant de recompiler.
# Usage: powershell -File scripts\build.ps1 [-Release]
param([switch]$Release)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lpi = Join-Path $root 'app\rottensshrimp.lpi'

$lazbuild = (Get-Command lazbuild -ErrorAction SilentlyContinue).Source
if (-not $lazbuild) {
  $candidates = @(
    'C:\lazarus\lazbuild.exe',
    'C:\fpcupdeluxe\lazarus\lazbuild.exe',
    "$env:USERPROFILE\fpcupdeluxe\lazarus\lazbuild.exe",
    "$env:LOCALAPPDATA\lazarus\lazbuild.exe",
    'C:\Program Files\Lazarus\lazbuild.exe'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { $lazbuild = $c; break } }
}
if (-not $lazbuild) { Write-Error 'lazbuild introuvable. Ajoute-le au PATH ou installe Lazarus.' }

Get-Process rottensshrimp -ErrorAction SilentlyContinue | Stop-Process -Force

$buildArgs = @()
if ($Release) { $buildArgs += '--build-mode=Release' }
$buildArgs += $lpi

Write-Host "lazbuild: $lazbuild"
# lazbuild resout les chemins de ressources du .lpi par rapport au cwd,
# pas au .lpi : on se place dans app\ pour la duree du build.
Push-Location (Join-Path $root 'app')
try {
  & $lazbuild @buildArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
Write-Host "OK -> $root\rottensshrimp.exe"
