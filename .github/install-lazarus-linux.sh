#!/usr/bin/env bash
# Installe Lazarus 4.8 + FPC 3.2.2 sur un runner Linux amd64. Partage par
# ci.yml et release.yml.
#
# Plus setup-lazarus: il s'arrete a 4.4 et tire tout de SourceForge, qui bride
# les runners GitHub au point de faire expirer le job -- six fois en une
# apres-midi. Les .deb officiels viennent donc du miroir clamy54/lazarus-mirror
# (memes fichiers), SourceForge n'est plus que le secours. Le cache d'actions
# du workflow evite meme ce premier telechargement d'un run au suivant.
set -euo pipefail

mirror="https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-linux-amd64"
sf="https://sourceforge.net/projects/lazarus/files/Lazarus%20Linux%20amd64%20DEB/Lazarus%204.8"
dl="$HOME/laz-dl"; mkdir -p "$dl"

fetch() {  # $1 nom du fichier; garde la copie du cache si elle est la
  [ -s "$dl/$1" ] && { echo "$1: depuis le cache"; return 0; }
  curl -fsSL --retry 3 -o "$dl/$1" "$mirror/$1" && { echo "$1: depuis le miroir GitHub"; return 0; }
  echo "$1: miroir indisponible, repli SourceForge" >&2
  curl -fsSL --retry 3 -o "$dl/$1" "$sf/$1/download"
}

fetch fpc-laz_3.2.2-210709_amd64.deb
fetch fpc-src_3.2.2-210709_amd64.deb
fetch lazarus-project_4.8.0-0_amd64.deb

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "$dl/fpc-laz_3.2.2-210709_amd64.deb" \
  "$dl/fpc-src_3.2.2-210709_amd64.deb" \
  "$dl/lazarus-project_4.8.0-0_amd64.deb"
lazbuild --version
