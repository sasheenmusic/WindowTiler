#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
test_root=$(mktemp -d /tmp/windowtiler-boundary-tests.XXXXXX)
if ! swift build --disable-sandbox > "$test_root/build.log" 2>&1; then
  cat "$test_root/build.log"
  exit 1
fi
build_root=$(swift build --disable-sandbox --show-bin-path)
service_sources=(Sources/WindowTilerApp/PresetWindowService.swift Sources/WindowTilerApp/PresetSpaceBridge.swift
  Sources/WindowTilerApp/PresetPrivateSymbol.swift Sources/WindowTilerApp/AppQuarantine.swift
  Sources/WindowTilerApp/EnhancedUIState.swift Sources/WindowTilerApp/Log.swift)
swiftc -I "$build_root/Modules" "${service_sources[@]}" Scripts/test-preset-discovery.swift \
  "$build_root/WindowTilerCore.build/PresetModels.swift.o" "$build_root/WindowTilerCore.build/ScreenGeometryEngine.swift.o" \
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
swiftc -I "$build_root/Modules" Sources/WindowTilerApp/PresetPanel.swift Scripts/test-preset-ui.swift \
  "$build_root/WindowTilerCore.build/PresetModels.swift.o" -o "$test_app/Contents/MacOS/test" -framework AppKit -framework Carbon
codesign --force --sign - "$test_app" >/dev/null 2>&1
"$test_app/Contents/MacOS/test" | tee "$test_root/ui.txt"
printf 'Test results: %s\n' "$test_root"
