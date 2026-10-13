#!/bin/bash
# Double-clic sur ce fichier (Mac) : lance le Robot appels et ouvre sa fenêtre.
cd "$(dirname "$0")" || exit 1
clear
echo "=========================================="
echo "   Robot appels — lancement"
echo "=========================================="
echo

PWSH="$(command -v pwsh || true)"
[ -z "$PWSH" ] && [ -x /usr/local/bin/pwsh ] && PWSH=/usr/local/bin/pwsh
[ -z "$PWSH" ] && [ -x /usr/local/microsoft/powershell/7/pwsh ] && PWSH=/usr/local/microsoft/powershell/7/pwsh

if [ -z "$PWSH" ]; then
  echo "📦 Première fois : il faut installer PowerShell (gratuit, fait par Microsoft)."
  if [ "$(uname -m)" = "arm64" ]; then ARCH=arm64; else ARCH=x64; fi
  PKG="/tmp/powershell-7.4.6-osx-$ARCH.pkg"
  echo "   Téléchargement en cours…"
  if ! curl -fSL -o "$PKG" "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-osx-$ARCH.pkg"; then
    echo
    echo "❌ Le téléchargement a échoué. Vérifie ta connexion Internet et relance ce fichier."
    read -r -p "Appuie sur Entrée pour fermer…"
    exit 1
  fi
  open "$PKG"
  echo
  echo "👉 L'installateur s'est ouvert : clique sur Continuer jusqu'à Installer"
  echo "   (le Mac demande ton mot de passe de session, c'est normal)."
  echo "👉 Quand c'est terminé, double-clique à nouveau sur « Lancer Robot appels »."
  echo
  read -r -p "Appuie sur Entrée pour fermer…"
  exit 0
fi

if ! "$PWSH" -NoProfile -File ./configurer.ps1; then
  echo
  read -r -p "Appuie sur Entrée pour fermer…"
  exit 1
fi

echo
echo "✅ Le robot démarre et sa fenêtre va s'ouvrir."
echo "   Laisse CETTE fenêtre du Terminal ouverte (tu peux la réduire dans le Dock) :"
echo "   tant qu'elle est ouverte, le robot tourne et les campagnes continuent."
echo "   Pour arrêter le robot : ferme cette fenêtre (ou bouton « Arrêter » dans le robot)."
echo
# exec : le Terminal passe la main au robot (la mise à jour automatique peut remplacer ce fichier).
exec "$PWSH" -NoProfile -File ./application.ps1
