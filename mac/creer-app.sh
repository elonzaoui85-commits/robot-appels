#!/bin/bash
# Fabrique « Robot appels.app » (application Mac) à partir du dossier robot-appels.
# Utilisation : ./mac/creer-app.sh [dossier de sortie]   (par défaut : le dossier courant)
set -e
RACINE="$(cd "$(dirname "$0")/.." && pwd)"
SORTIE="${1:-.}"
APP="$SORTIE/Robot appels.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/robot"
cp "$RACINE/mac/lanceur.sh" "$APP/Contents/MacOS/Robot appels"
chmod +x "$APP/Contents/MacOS/Robot appels"
cp "$RACINE/mac/robot.icns" "$APP/Contents/Resources/robot.icns"
(cd "$RACINE" && tar -cf - --exclude ./mac --exclude ./resultats --exclude ./campagne.json --exclude ./.gitignore --exclude ./.gitattributes .) | tar -xf - -C "$APP/Contents/Resources/robot"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Robot appels</string>
  <key>CFBundleDisplayName</key><string>Robot appels</string>
  <key>CFBundleIdentifier</key><string>com.robotappels.app</string>
  <key>CFBundleExecutable</key><string>Robot appels</string>
  <key>CFBundleIconFile</key><string>robot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
echo "Application créée : $APP"
