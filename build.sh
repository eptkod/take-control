#!/bin/sh
# Builds build/Take Control.app (arm64 only, no Xcode project needed).
set -e
cd "$(dirname "$0")"
TARGET=arm64-apple-macos13.0
APP="build/Take Control.app"
SWIFT_FLAGS=
# TEST=1 ./build.sh: a separate test build with a button that fires the overheat warning.
if [ -n "$TEST" ]; then
    APP="build/Take Control Test.app"
    SWIFT_FLAGS="-D TEST_WARNING"
fi
OBJ=build/obj
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

clang -target $TARGET -Os -Wall -Wextra -c Sources/smc.c -o $OBJ/smc.o
clang -target $TARGET -Os -Wall -Wextra -c Sources/temps.c -o $OBJ/temps.o

# Privileged helper: SMC only.
clang -target $TARGET -Os -Wall -Wextra -Wl,-dead_strip -framework IOKit \
    Sources/helper.c $OBJ/smc.o -o "$APP/Contents/MacOS/tc-helper"

swiftc -target $TARGET -Osize $SWIFT_FLAGS -whole-module-optimization \
    -import-objc-header Sources/TakeControl.h \
    Sources/main.swift $OBJ/smc.o $OBJ/temps.o \
    -framework IOKit -Xlinker -dead_strip \
    -o "$APP/Contents/MacOS/TakeControl"

strip -x "$APP/Contents/MacOS/TakeControl" "$APP/Contents/MacOS/tc-helper"
cp Info.plist "$APP/Contents/Info.plist"
# Icons are prebuilt from Branding/ (run Branding/render.sh after editing the SVGs).
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
codesign --force -s - "$APP/Contents/MacOS/tc-helper"
codesign --force -s - "$APP"
# Finder caches icons by path; re-register so a changed icon shows up right away.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
