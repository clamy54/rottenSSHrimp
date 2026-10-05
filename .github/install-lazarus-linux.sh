#!/usr/bin/env bash
# FPC 3.2.2 + Lazarus trunk (GTK3), runner Linux amd64 (ci.yml, release.yml).
# Lazarus: commit epingle, bati ici (make lazbuild). Le hash git fait foi.
# Pas setup-lazarus: bloque a 4.4, et SourceForge bride les runners jusqu'au
# timeout. Miroir d'abord, SourceForge en secours.
# Empreinte verifiee AVANT installation, d'ou qu'il vienne: le compilateur
# des binaires publies ne sort pas d'un cache douteux. Temp puis mv.
set -euo pipefail

mirror="https://github.com/clamy54/lazarus-mirror/releases/download/lazarus-4.8-linux-amd64"
sf="https://sourceforge.net/projects/lazarus/files/Lazarus%20Linux%20amd64%20DEB/Lazarus%204.8"
dl="$HOME/laz-dl"; mkdir -p "$dl"

# $1 fichier, $2 SHA-256 attendu
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

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "$dl/fpc-laz_3.2.2-210709_amd64.deb" \
  "$dl/fpc-src_3.2.2-210709_amd64.deb" \
  make git libgtk-3-dev

laz_commit=39a5eec43c6846e8d63cbb6c5fd263db38c4ea5b
laz_url=https://gitlab.com/freepascal.org/lazarus/lazarus.git
lazdir="$HOME/lazarus-trunk"
if [ ! -x "$lazdir/lazbuild" ] || [ "$(cat "$lazdir/.commit" 2>/dev/null)" != "$laz_commit" ]; then
  rm -rf "$lazdir"; mkdir -p "$lazdir"
  git -C "$lazdir" init -q
  git -C "$lazdir" fetch -q --depth 1 "$laz_url" "$laz_commit"
  git -C "$lazdir" checkout -q FETCH_HEAD
  [ "$(git -C "$lazdir" rev-parse HEAD)" = "$laz_commit" ] || { echo "Lazarus: commit inattendu" >&2; exit 1; }
  make -C "$lazdir" lazbuild >/dev/null
  echo "$laz_commit" > "$lazdir/.commit"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$lazdir" >> "$GITHUB_PATH"
  echo "LAZARUS_DIR=$lazdir" >> "$GITHUB_ENV"
fi
"$lazdir/lazbuild" --version
