#!/bin/bash
# Application Mac « Robot appels » : met à jour le dossier de travail du robot puis le lance dans le Terminal.
# Le code vient de l'application ; les données (config.json, campagne.json, resultats/) restent dans
# ~/Library/Application Support/Robot appels et sont conservées d'une version à l'autre.
SRC="$(cd "$(dirname "$0")/../Resources/robot" && pwd)"
DATA="$HOME/Library/Application Support/Robot appels"
ANCIEN="$HOME/Desktop/Robot appels"
mkdir -p "$DATA"

# Première ouverture : reprendre les réglages et la campagne de l'ancien dossier du Bureau s'il existe.
if [ ! -f "$DATA/config.json" ]; then
  for f in config.json campagne.json; do
    [ -f "$ANCIEN/$f" ] && cp "$ANCIEN/$f" "$DATA/"
  done
  [ -d "$ANCIEN/resultats" ] && cp -R "$ANCIEN/resultats" "$DATA/"
  [ -f "$DATA/config.json" ] || cp "$SRC/config.json" "$DATA/"
fi

# Code de l'application : installé tant que la mise à jour automatique (version.txt) n'a pas pris le relais.
# config.json (tes identifiants) n'est jamais remplacé.
if [ ! -f "$DATA/version.txt" ]; then
  for f in "$SRC"/*; do
    [ "$(basename "$f")" = config.json ] || cp -R "$f" "$DATA/"
  done
fi
chmod +x "$DATA/Lancer Robot appels.command"
open -a Terminal "$DATA/Lancer Robot appels.command"
