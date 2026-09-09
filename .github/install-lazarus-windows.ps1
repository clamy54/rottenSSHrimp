# Installe Lazarus 4.8 + FPC 3.2.2 sur un runner Windows x64. Partage par
# ci.yml et release.yml.
#
# Plus setup-lazarus: il s'arrete a 4.4 et tire tout de SourceForge, qui bride
# les runners GitHub au point de faire expirer le job. L'installeur officiel
# vient donc du miroir clamy54/lazarus-mirror (meme fichier), SourceForge n'est
# plus que le secours. Le cache d'actions du workflow evite meme ce premier
# telechargement d'un run au suivant.
#
# L'installeur est confronte a son empreinte AVANT d'etre execute, qu'il
# vienne du miroir, de SourceForge ou du cache: un miroir, un cache ou un
# telechargement tronque ne doivent pas pouvoir fabriquer le compilateur qui
# fabrique les binaires publies. Le telechargement va dans un fichier
# temporaire, renomme une fois verifie: le cache ne contient jamais un fichier
# a moitie ecrit.
#
# Install silencieuse dans C:\lazarus, un des chemins que build.ps1 sonde.
$ErrorActionPreference = 'Stop'

$name = "lazarus-4.8-fpc-3.2.2-win64.exe"
$expected = "ed25ee171d55e23cf14e0633159fdd2325efba56e186f8ab817ad3bf97d267d7"
$mirror = "https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-win64/$name"
$sf = "https://sourceforge.net/projects/lazarus/files/Lazarus%20Windows%2064%20bits/Lazarus%204.8/$name/download"
$dl = Join-Path $HOME "laz-dl"; New-Item -ItemType Directory -Force $dl | Out-Null
$exe = Join-Path $dl $name
$tmp = "$exe.part"

function Test-Fingerprint([string]$path, [string]$sha) {
  return ((Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() -eq $sha)
}

$cached = $false
if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 0) {
  if (Test-Fingerprint $exe $expected) {
    Write-Output "${name}: depuis le cache (empreinte OK)"
    $cached = $true
  } else {
    Write-Warning "${name}: copie du cache corrompue, retelechargement"
    Remove-Item -Force $exe
  }
}

if (-not $cached) {
  if (Test-Path $tmp) { Remove-Item -Force $tmp }
  try {
    curl.exe -fsSL --retry 3 -o $tmp $mirror
    if ($LASTEXITCODE -ne 0) { throw "miroir" }
    Write-Output "${name}: depuis le miroir GitHub"
  } catch {
    Write-Warning "${name}: miroir indisponible, repli SourceForge"
    curl.exe -fsSL --retry 3 -o $tmp $sf
    if ($LASTEXITCODE -ne 0) { throw "telechargement impossible" }
  }
  if (-not (Test-Fingerprint $tmp $expected)) {
    $got = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLowerInvariant()
    Remove-Item -Force $tmp
    throw "${name}: empreinte SHA-256 inattendue ($got), fichier refuse"
  }
  Move-Item -Force $tmp $exe
  Write-Output "${name}: empreinte OK"
}

Start-Process -Wait -FilePath $exe -ArgumentList '/VERYSILENT','/NORESTART','/SP-','/SUPPRESSMSGBOXES','/DIR=C:\lazarus'
if (-not (Test-Path 'C:\lazarus\lazbuild.exe')) { throw "lazbuild.exe absent apres installation" }
& 'C:\lazarus\lazbuild.exe' --version
