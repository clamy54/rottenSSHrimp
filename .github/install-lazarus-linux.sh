#!/usr/bin/env bash
# Installe Lazarus 4.8 + FPC 3.2.2 sur un runner Linux amd64. Partage par
# ci.yml et release.yml.
#
# Plus setup-lazarus: il s'arrete a 4.4 et tire tout de SourceForge, qui bride
# les runners GitHub au point de faire expirer le job -- six fois en une
# apres-midi. Les .deb officiels viennent donc du miroir clamy54/lazarus-mirror
# (memes fichiers), SourceForge n'est plus que le secours. Le cache d'actions
# du workflow evite meme ce premier telechargement d'un run au suivant.
#
# Chaque fichier est confronte a son empreinte AVANT d'etre installe, qu'il
# vienne du miroir, de SourceForge ou du cache: un miroir, un cache ou un
# telechargement tronque ne doivent pas pouvoir fabriquer le compilateur qui
# fabrique les binaires publies. Le telechargement va dans un fichier
# temporaire, renomme une fois verifie: le cache ne contient jamais un
# fichier a moitie ecrit.
set -euo pipefail

mirror="https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-linux-amd64"
sf="https://sourceforge.net/projects/lazarus/files/Lazarus%20Linux%20amd64%20DEB/Lazarus%204.8"
dl="$HOME/laz-dl"; mkdir -p "$dl"

# $1 fichier, $2 empreinte attendue: 0 si elle correspond
verify() {
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ]
}

fetch() {  # $1 nom du fichier, $2 SHA-256 attendu
  if [ -s "$dl/$1" ]; then
    if verify "$dl/$1" "$2"; then echo "$1: depuis le cache (empreinte OK)"; return 0; fi
    echo "$1: copie du cache corrompue, retelechargement" >&2
    rm -f "$dl/$1"
  fi
  local tmp="$dl/$1.part"
  rm -f "$tmp"
  if curl -fsSL --retry 3 -o "$tmp" "$mirror/$1"; then
    echo "$1: depuis le miroir GitHub"
  else
    echo "$1: miroir indisponible, repli SourceForge" >&2
    curl -fsSL --retry 3 -o "$tmp" "$sf/$1/download"
  fi
  if ! verify "$tmp" "$2"; then
    echo "$1: empreinte SHA-256 inattendue, fichier refuse" >&2
    sha256sum "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  mv -f "$tmp" "$dl/$1"
  echo "$1: empreinte OK"
}

fetch fpc-laz_3.2.2-210709_amd64.deb   92000f2b831184e153aab0c910f8ae9240450e5c6d76dc189cf53116ee501d83
fetch fpc-src_3.2.2-210709_amd64.deb   8c9e145d8056754a9ca39ce3e52e982b8e4816124984c5f542f2a874e721ad53
fetch lazarus-project_4.8.0-0_amd64.deb 401742cefb01ad99a628188034bf728fb5360d641ed2be5f91fb0ee183a301cd

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "$dl/fpc-laz_3.2.2-210709_amd64.deb" \
  "$dl/fpc-src_3.2.2-210709_amd64.deb" \
  "$dl/lazarus-project_4.8.0-0_amd64.deb"
lazbuild --version
