#!/bin/bash
set -euo pipefail
[[ $# -eq 2 || ( $# -eq 3 && $3 == --public ) ]] || { echo "Usage: sign-app.sh app-path signing-identity [--public]" >&2; exit 1; }
app="$1"
identity="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ ${3:-} == --public ]]; then
    identity=$(python3 "$script_dir/public-signing-policy.py" identity --signing-identity "$identity")
    sign=(codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$identity")
else
    sign=(codesign --force --timestamp=none --preserve-metadata=entitlements --sign "$identity")
    if [[ "$identity" != "-" ]]; then sign+=(--options runtime); fi
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
version="$framework/Versions/Current"
[[ -f "$app/Contents/Info.plist" && -L "$version" ]] || { echo "Missing app or versioned Sparkle framework." >&2; exit 1; }
# Sign inner code first, preserving the helper entitlements.
for component in "$version/XPCServices/Downloader.xpc" "$version/XPCServices/Installer.xpc" "$version/Updater.app" "$version/Autoupdate" "$framework" "$app"; do
    [[ -e "$component" ]] || { echo "Missing Sparkle component: $component" >&2; exit 1; }
    "${sign[@]}" "$component"
done
codesign --verify --deep --strict "$app"
if [[ ${3:-} == --public ]]; then python3 "$script_dir/public-signing-policy.py" verify "$app"; fi
