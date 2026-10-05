#!/bin/zsh
# Builds Data Pebble and zips it for a GitHub release / Homebrew cask.
set -euo pipefail
cd -- "${0:A:h}"
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' 'Data Pebble.app/Contents/Info.plist')
mkdir -p dist
zip="dist/DataPebble-$version.zip"
rm -f -- "$zip"
ditto -c -k --sequesterRsrc --keepParent 'Data Pebble.app' "$zip"
echo "$zip"
shasum -a 256 "$zip"
