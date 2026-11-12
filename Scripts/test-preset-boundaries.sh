#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
test_root=$(mktemp -d /tmp/windowtiler-boundary-tests.XXXXXX)
core_dir="$test_root/core"
mkdir -p "$core_dir"
# Build WindowTilerCore here rather than reading SwiftPM's build folder, whose layout differs between Swift versions.
swiftc -parse-as-library -module-name WindowTilerCore -emit-library -static \
  -emit-module -emit-module-path "$core_dir/WindowTilerCore.swiftmodule" \
  -o "$core_dir/libWindowTilerCore.a" Sources/WindowTilerCore/*.swift
service_sources=(Sources/WindowTilerApp/PresetWindowService.swift Sources/WindowTilerApp/PresetSpaceBridge.swift
  Sources/WindowTilerApp/PresetPrivateSymbol.swift Sources/WindowTilerApp/AppQuarantine.swift
  Sources/WindowTilerApp/EnhancedUIState.swift Sources/WindowTilerApp/Log.swift
  Sources/WindowTilerApp/WindowExclusions.swift Sources/WindowTilerApp/ProcessFacts.swift)
swiftc -I "$core_dir" -L "$core_dir" -lWindowTilerCore "${service_sources[@]}" Scripts/test-preset-discovery.swift \
  -o "$test_root/discovery" -framework AppKit -framework Carbon
"$test_root/discovery" | tee "$test_root/discovery.txt"
test_app="$test_root/PresetUITests.app"
mkdir -p "$test_app/Contents/MacOS"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>test</string>
<key>CFBundleIdentifier</key><string>local.WindowTiler.PresetUIRefreshTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -I "$core_dir" -L "$core_dir" -lWindowTilerCore Sources/WindowTilerApp/PresetPanel.swift Scripts/test-preset-ui.swift \
  -o "$test_app/Contents/MacOS/test" -framework AppKit -framework Carbon
codesign --force --sign - "$test_app" >/dev/null 2>&1
"$test_app/Contents/MacOS/test" | tee "$test_root/ui.txt"
printf 'Test results: %s\n' "$test_root"
