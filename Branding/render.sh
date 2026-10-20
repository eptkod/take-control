#!/bin/sh
# Regenerates every brand asset from the SVG masters in this folder.
# Outputs: ../Resources/AppIcon.icns, ../Resources/MenuBarIcon*.png, and PNG exports here.
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O render.swift -o "$TMP/render"
"$TMP/render" "$TMP"
mkdir -p ../Resources png
iconutil -c icns "$TMP/AppIcon.iconset" -o ../Resources/AppIcon.icns
cp "$TMP"/MenuBarIcon.png "$TMP"/MenuBarIcon@2x.png ../Resources/
cp "$TMP"/icon-1024.png "$TMP"/logo-light.png "$TMP"/logo-dark.png png/
echo "Rendered brand assets"
