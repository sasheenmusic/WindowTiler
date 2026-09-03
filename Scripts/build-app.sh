#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

app_dir="dist/Window Tiler.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp ".build/release/WindowTiler" "$contents_dir/MacOS/WindowTiler"
cp "Resources/Info.plist" "$contents_dir/Info.plist"
# Prefer the Mac owner's real Apple Development identity. Unlike an ad-hoc
# signature, this keeps Accessibility trust attached across rebuilt versions.
signing_identity="${WINDOW_TILER_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi

if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --options runtime --timestamp=none --sign "$signing_identity" "$app_dir"
else
    echo "Warning: no Apple Development signing identity found; using a temporary signature."
    codesign --force --deep --sign - "$app_dir"
fi

echo "$PWD/$app_dir"
