#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
test_root=$(mktemp -d /tmp/windowtiler-session-tests.XXXXXX)
test_app="$test_root/PresetSessionTests.app"
mkdir -p "$test_app/Contents/MacOS"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>test</string>
<key>CFBundleIdentifier</key><string>local.WindowTiler.PresetSessionTests</string>
<key>CFBundleName</key><string>Preset Session Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3</string>
</dict></plist>
PLIST
core_dir="$test_root/core"
mkdir -p "$core_dir"
# Build WindowTilerCore here rather than reading SwiftPM's build folder, whose layout differs between Swift versions.
swiftc -parse-as-library -module-name WindowTilerCore -emit-library -static \
  -emit-module -emit-module-path "$core_dir/WindowTilerCore.swiftmodule" \
  -o "$core_dir/libWindowTilerCore.a" Sources/WindowTilerCore/*.swift
swiftc -I "$core_dir" -L "$core_dir" -lWindowTilerCore \
  Sources/WindowTilerApp/AppDelegate.swift Sources/WindowTilerApp/HotKey.swift Sources/WindowTilerApp/Log.swift \
  Scripts/test-preset-session.swift \
  -o "$test_app/Contents/MacOS/test" -framework AppKit -framework Carbon
codesign --force --sign - "$test_app" >/dev/null 2>&1
"$test_app/Contents/MacOS/test" | tee "$test_root/result.txt"
printf 'Test result: %s\n' "$test_root/result.txt"
