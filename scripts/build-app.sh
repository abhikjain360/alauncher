#!/usr/bin/env bash
# Builds alauncher.app into build/ and signs it. Usage: build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
config=${1:-release}

xcrun swift build -c "$config" --product alauncher
bin_dir=$(xcrun swift build -c "$config" --show-bin-path)

app=build/alauncher.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
# A unique build number gives every build a new signature, the same way a
# code change would, so permission persistence is tested on every rebuild.
plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M%S)" "$app/Contents/Info.plist"
cp "$bin_dir/alauncher" "$app/Contents/MacOS/alauncher"
cp Resources/default-config.toml "$app/Contents/Resources/default-config.toml"

scripts/sign.sh "$app"
echo "Built $app ($config)"
