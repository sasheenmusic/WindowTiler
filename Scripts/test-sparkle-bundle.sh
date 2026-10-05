#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-sparkle-load.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Window Tiler.app"
ditto "${1:-dist/Window Tiler.app}" "$app"
cat > "$stage/main.swift" <<'SWIFT'
import Sparkle
print("PASS: ad-hoc app loads \(SPUUpdater.self)")
SWIFT
# Replace only this disposable copy's executable with a harmless loader probe.
# The production app is never started, so no settings or user windows change.
swiftc -F "$app/Contents/Frameworks" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$stage/main.swift" -o "$app/Contents/MacOS/WindowTiler"
Scripts/sign-app.sh "$app" -
"$app/Contents/MacOS/WindowTiler"
