#!/bin/sh
# Packages build/Take Control.app into build/TakeControl-<version>.dmg (drag-to-Applications layout).
set -e
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="build/TakeControl-$VERSION.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/Take Control.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Take Control" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
