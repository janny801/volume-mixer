#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/dist/Volume Mixer.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/VolumeMixer "$app/Contents/MacOS/VolumeMixer"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier com.janny801.volume-mixer "$app"
echo "$app"
