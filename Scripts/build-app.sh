#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release "$@"
app_dir="${WINDOW_TILER_APP_OUTPUT:-dist/Window Tiler.app}"
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { echo "Sparkle artifact is missing; resolve the pinned package first." >&2; exit 1; }
mkdir -p "$(dirname "$app_dir")"
stage="$(mktemp -d "$(dirname "$app_dir")/.windowtiler-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Window Tiler.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
cp ".build/release/WindowTiler" "$bundle/Contents/MacOS/WindowTiler"
strip -S "$bundle/Contents/MacOS/WindowTiler"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
# ditto retains the framework's version and helper symlinks.
ditto "$framework" "$bundle/Contents/Frameworks/Sparkle.framework"
# A real local identity keeps Accessibility trust across local rebuilds.
identity="${WINDOW_TILER_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
    echo "No Apple Development identity found; using an ad-hoc signature." >&2
    identity="-"
fi
Scripts/sign-app.sh "$bundle" "$identity"
if [[ -e "$app_dir" ]]; then
    [[ -d "$app_dir/Contents" && "$app_dir" == *.app ]] || { echo "Refusing to replace a non-app output." >&2; exit 1; }
    rm -rf "$app_dir"
fi
mv "$bundle" "$app_dir"
echo "$(cd "$(dirname "$app_dir")" && pwd)/$(basename "$app_dir")"
