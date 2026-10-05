#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p 'Data Pebble.app/Contents/MacOS'
build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT
# Universal binary so the app runs on Apple silicon and Intel Macs.
for arch in arm64 x86_64; do
  xcrun clang -O2 -Wall -Wextra -Werror -target "$arch-apple-macos14" -c Sources/InterfaceCounters.c -o "$build_dir/InterfaceCounters-$arch.o"
  xcrun swiftc -parse-as-library -O -target "$arch-apple-macos14" -import-objc-header Sources/InterfaceCounters.h Sources/DataPebble.swift "$build_dir/InterfaceCounters-$arch.o" -o "$build_dir/DataPebble-$arch" -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications
done
xcrun lipo -create "$build_dir/DataPebble-arm64" "$build_dir/DataPebble-x86_64" -output 'Data Pebble.app/Contents/MacOS/DataPebble'
python3 - <<'PY'
import plistlib,pathlib
pathlib.Path('Data Pebble.app/Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'DataPebble','CFBundleIdentifier':'local.aidan.DataPebble','CFBundleName':'Data Pebble','CFBundleDisplayName':'Data Pebble','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.1','CFBundleVersion':'2','LSUIElement':True,'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}))
PY
xattr -d com.apple.FinderInfo 'Data Pebble.app' 2>/dev/null || true
codesign --force --sign - 'Data Pebble.app'
'Data Pebble.app/Contents/MacOS/DataPebble' --self-test
