# Installe Lazarus 4.8 + FPC 3.2.2 sur un runner Windows x64. Partage par
# ci.yml et release.yml.
#
# Plus setup-lazarus: il s'arrete a 4.4 et tire tout de SourceForge, qui bride
# les runners GitHub au point de faire expirer le job. L'installeur officiel
# vient donc du miroir clamy54/lazarus-mirror (meme fichier), SourceForge n'est
# plus que le secours. Le cache d'actions du workflow evite meme ce premier
# telechargement d'un run au suivant.
#
# Install silencieuse dans C:\lazarus, un des chemins que build.ps1 sonde.
$ErrorActionPreference = 'Stop'

$name = "lazarus-4.8-fpc-3.2.2-win64.exe"
$mirror = "https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-win64/$name"
$sf = "https://sourceforge.net/projects/lazarus/files/Lazarus%20Windows%2064%20bits/Lazarus%204.8/$name/download"
$dl = Join-Path $HOME "laz-dl"; New-Item -ItemType Directory -Force $dl | Out-Null
$exe = Join-Path $dl $name

if ((Test-Path $exe) -and (Get-Item $exe).Length -gt 0) {
  Write-Output "${name}: depuis le cache"
} else {
  try {
    curl.exe -fsSL --retry 3 -o $exe $mirror
    if ($LASTEXITCODE -ne 0) { throw "miroir" }
    Write-Output "${name}: depuis le miroir GitHub"
  } catch {
    Write-Warning "${name}: miroir indisponible, repli SourceForge"
    curl.exe -fsSL --retry 3 -o $exe $sf
    if ($LASTEXITCODE -ne 0) { throw "telechargement impossible" }
  }
}

Start-Process -Wait -FilePath $exe -ArgumentList '/VERYSILENT','/NORESTART','/SP-','/SUPPRESSMSGBOXES','/DIR=C:\lazarus'
if (-not (Test-Path 'C:\lazarus\lazbuild.exe')) { throw "lazbuild.exe absent apres installation" }
& 'C:\lazarus\lazbuild.exe' --version
