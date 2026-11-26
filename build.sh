#!/bin/bash
# Usage: ./build.sh          -> builds build/BlueNotch.app
#        ./build.sh install  -> builds, copies to ~/Applications and launches
set -euo pipefail
cd "$(dirname "$0")"
APP=build/BlueNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/BlueNotch" \
  -framework IOBluetooth -framework IOKit -framework ServiceManagement -framework SwiftUI -framework AppKit
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "install" ]]; then
  pkill -x BlueNotch || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/BlueNotch.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/BlueNotch.app
  echo "Installed to ~/Applications/BlueNotch.app"
fi
