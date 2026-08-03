#!/usr/bin/env bash
#
# SBOM CycloneDX 1.5 d'une distribution binaire.
#
# Usage: gen-sbom.sh <sortie.json> <produit> <version> <plateforme> <composant>...
#   composant: "nom|version|licence|chemin[|type]" -- version et licence vides
#   sont omises du SBOM plutot qu'inventees; type defaut library.
#
# Un chemin manquant est un ECHEC: un SBOM qui tait un binaire embarque dit le
# contraire de ce qu'il prouve. JSON assemble a la main (bash 3.2, pas de jq).
set -euo pipefail

if [ $# -lt 5 ]; then
  echo "usage: $0 <sortie.json> <produit> <version> <plateforme> <composant>..." >&2
  echo "  composant: \"nom|version|licence|chemin[|type]\"" >&2
  exit 2
fi

out="$1"; product="$2"; version="$3"; platform="$4"
shift 4

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"
ts="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)"

components=""
count=0
for desc in "$@"; do
  IFS='|' read -r cname cver clic cpath ctype <<EOF
$desc
EOF
  if [ -z "${cname:-}" ] || [ -z "${cpath:-}" ]; then
    echo "descripteur invalide (nom ou chemin vide): $desc" >&2
    exit 2
  fi
  if [ ! -f "$cpath" ]; then
    echo "ECHEC: composant introuvable: $cpath" >&2
    exit 1
  fi
  [ -n "${ctype:-}" ] || ctype="library"
  hash="$(sha256_of "$cpath")"

  comp="    {
      \"type\": \"$ctype\",
      \"name\": \"$cname\","
  [ -n "$cver" ] && comp="$comp
      \"version\": \"$cver\","
  [ -n "$clic" ] && comp="$comp
      \"licenses\": [ { \"license\": { \"name\": \"$clic\" } } ],"
  comp="$comp
      \"hashes\": [ { \"alg\": \"SHA-256\", \"content\": \"$hash\" } ],
      \"properties\": [
        { \"name\": \"rssh:filename\", \"value\": \"$(basename "$cpath")\" }
      ]
    }"

  if [ -n "$components" ]; then
    components="$components,
$comp"
  else
    components="$comp"
  fi
  count=$((count + 1))
done

cat > "$out" <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "timestamp": "$ts",
    "component": {
      "type": "application",
      "name": "$product",
      "version": "$version"
    },
    "properties": [
      { "name": "rssh:platform", "value": "$platform" }
    ]
  },
  "components": [
$components
  ]
}
EOF

echo "SBOM -> $out (${count} composants)"
