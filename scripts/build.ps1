# Build Windows. Usage: powershell -File scripts\build.ps1 [-Release]
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
# lazbuild resout les ressources depuis le cwd, PAS depuis le .lpi
Push-Location (Join-Path $root 'app')
try {
  & $lazbuild @buildArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
Write-Host "OK -> $root\rottensshrimp.exe"
