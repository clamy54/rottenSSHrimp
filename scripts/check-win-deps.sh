#!/usr/bin/env bash
#
# DEPS.md contre les DLL versionnees, dans les deux sens. Une provenance
# perimee ne prouve rien: deja vu, 9 sur 11 apres un re-provisioning.
#
# Usage: scripts/check-win-deps.sh   (0 = concordance, 1 = ecarts detailles)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps="${root}/packaging/windows/DEPS.md"

if command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  sha() { sha256sum "$1" | cut -d' ' -f1; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# `xxx.dll`: `64 hexa`
sed -n 's/.*`\([A-Za-z0-9._-]*\.dll\)`[[:space:]]*:[[:space:]]*`\([0-9a-f]\{64\}\)`.*/\1 \2/p' \
  "$deps" | sort -u > "$tmp/doc.txt"

if ! [ -s "$tmp/doc.txt" ]; then
  echo "ECHEC: aucune empreinte extraite de ${deps}." >&2
  exit 1
fi

fail=0

# un nom, deux hash: le document se contredit avant meme les fichiers
for dup in $(cut -d' ' -f1 "$tmp/doc.txt" | sort | uniq -d); do
  echo "CONTRADICTION ${dup}: plusieurs empreintes differentes dans DEPS.md"
  fail=1
done

# 1. document -> fichiers
while IFS=' ' read -r name want; do
  f="${root}/${name}"
  if [ ! -f "$f" ]; then
    echo "MANQUANT   ${name}: consigne dans DEPS.md, absent de la racine"
    fail=1
    continue
  fi
  got="$(sha "$f")"
  if [ "$got" != "$want" ]; then
    echo "DIVERGENCE ${name}: DEPS.md=${want} vs fichier=${got}"
    fail=1
  fi
done < "$tmp/doc.txt"

# 2. fichiers -> document
git -C "$root" ls-files '*.dll' | grep -v '/' > "$tmp/tracked.txt"
while IFS= read -r name; do
  if ! grep -q "^${name} " "$tmp/doc.txt"; then
    echo "NON DOCUMENTEE ${name}: DLL suivie sans empreinte dans DEPS.md"
    fail=1
  fi
done < "$tmp/tracked.txt"

n=$(wc -l < "$tmp/doc.txt" | tr -d ' ')
if [ "$fail" -eq 0 ]; then
  echo "OK: les ${n} empreintes de DEPS.md concordent avec les DLL suivies."
else
  echo
  echo "DEPS.md ne decrit PAS les DLL reellement versionnees." >&2
  echo "Refaire les empreintes apres tout re-provisioning (et verifier la" >&2
  echo "provenance du build avant de les consigner)." >&2
fi
exit "$fail"
