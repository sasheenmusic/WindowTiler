#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
swift build --disable-sandbox >/dev/null
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
build_root=$(swift build --disable-sandbox --show-bin-path)
swiftc -I "$build_root/Modules" \
  Sources/WindowTilerApp/AppDelegate.swift Sources/WindowTilerApp/HotKey.swift Sources/WindowTilerApp/Log.swift \
  Scripts/test-preset-session.swift \
  "$build_root/WindowTilerCore.build/PresetModels.swift.o" \
  "$build_root/WindowTilerCore.build/RowPlan.swift.o" \
  "$build_root/WindowTilerCore.build/TilingLimits.swift.o" \
  -o "$test_app/Contents/MacOS/test" -framework AppKit -framework Carbon
codesign --force --sign - "$test_app" >/dev/null 2>&1
"$test_app/Contents/MacOS/test" | tee "$test_root/result.txt"
printf 'Test result: %s\n' "$test_root/result.txt"
