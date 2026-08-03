#!/bin/bash
# Capture la pile du thread principal pendant un blocage (beach ball). Le
# thread etant bloque, l'echantillon est stable et montre ou ca coince
# (pthread_join ? boucle a nous ? libssh2 ?).
# Usage: scripts/diag-hang.sh, appli GELEE; envoyer le fichier affiche a la fin.

set -u
out="/tmp/rssh-hang.txt"
pid=$(pgrep -x rottensshrimp | head -1)
if [ -z "$pid" ]; then
  echo "rottensshrimp introuvable (l'appli tourne-t-elle ?)." >&2
  exit 1
fi
echo "PID=$pid — echantillonnage 3 s (garder l'appli figee)…"
sample "$pid" 3 -file "$out" >/dev/null 2>&1
echo "----- pile du thread principal (Thread 0) -----"
awk '/^ *Thread /{p=($0 ~ /Thread 0/)} p' "$out" | sed -n '1,60p'
echo "-----------------------------------------------"
echo "Rapport complet: $out"
