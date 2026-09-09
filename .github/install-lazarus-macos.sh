#!/usr/bin/env bash
# Installe Lazarus 4.8 aarch64 sur un runner macOS. Partage par ci.yml et
# release.yml.
#
# Pas setup-lazarus: sur macOS il ne pose que la variante x86_64 (l'app
# sortirait en Intel/Rosetta) et s'arrete a 4.4. On installe la distribution
# aarch64 officielle 4.8, celle qui sert en local.
#
# SourceForge bride le debit des runners GitHub au point de faire expirer le
# job: on sert d'abord le miroir clamy54/lazarus-mirror (memes fichiers), et
# SourceForge n'est plus que le secours. Le cache d'actions du workflow evite
# meme ce premier telechargement d'un run au suivant.
#
# Chaque fichier est confronte a son empreinte AVANT d'etre installe, qu'il
# vienne du miroir, de SourceForge ou du cache: un miroir, un cache ou un
# telechargement tronque ne doivent pas pouvoir fabriquer le compilateur qui
# fabrique les binaires publies. Le telechargement va dans un fichier
# temporaire, renomme une fois verifie: le cache ne contient jamais un
# fichier a moitie ecrit.
set -euo pipefail

mirror="https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-aarch64"
sf="https://sourceforge.net/projects/lazarus/files/Lazarus%20macOS%20aarch64/Lazarus%204.8"
dl="$HOME/laz-dl"; mkdir -p "$dl"

# $1 fichier, $2 empreinte attendue: 0 si elle correspond
verify() {
  local got
  got="$(shasum -a 256 "$1" | cut -d' ' -f1)"
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
    shasum -a 256 "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  mv -f "$tmp" "$dl/$1"
  echo "$1: empreinte OK"
}

fetch fpc-3.2.4rc1a.intelarm64-macosx.dmg e7792c59a31982a00021566d1ab63b0c794ff87d63b6123fe0f45e8f5627f798
fetch lazarus-darwin-aarch64-4.8.zip      e5e0bf52bca911d4605dc875bd924ff5c74a0d0f6cf5699b936b377cc1986d1b

sudo hdiutil attach -noautoopen "$dl/fpc-3.2.4rc1a.intelarm64-macosx.dmg"
# le dmg 3.2.4rc1a monte en fpc-3.2.4rc1...-flat: glob sur fpc-*
pkg="$(find /Volumes/fpc-* -maxdepth 1 \( -name '*.mpkg' -o -name '*.pkg' \) | head -1)"
[ -n "$pkg" ] || { echo "paquet FPC introuvable dans le dmg" >&2; ls /Volumes >&2; exit 1; }
sudo installer -package "$pkg" -target /
sudo hdiutil detach /Volumes/fpc-*

unzip -q "$dl/lazarus-darwin-aarch64-4.8.zip" -d "$HOME/laz"

# la config portable du zip pointe /Developer/lazarus, inaccessible (racine
# scellee SSV): on la fait pointer sur l'emplacement reel
cfg="$HOME/laz/lazarus/config/environmentoptions.xml"
[ -f "$cfg" ] || { echo "config du zip introuvable" >&2; ls "$HOME/laz" "$HOME/laz/lazarus" >&2; exit 1; }
sed -i '' "s|/Developer/lazarus|$HOME/laz/lazarus|g" "$cfg"

lb="$HOME/laz/lazarus/lazbuild"
[ -x "$lb" ] || { echo "lazbuild introuvable dans le zip" >&2; exit 1; }
sudo ln -sf "$lb" /usr/local/bin/lazbuild
lazbuild --version
