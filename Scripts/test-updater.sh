#!/bin/bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
test_root=$(mktemp -d /tmp/windowtiler-updater-tests.XXXXXX)
test_app="$test_root/UpdaterTests.app"
framework_root="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p "$test_app/Contents/MacOS"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>test</string>
<key>CFBundleIdentifier</key><string>local.WindowTiler.UpdaterTests</string>
<key>CFBundleName</key><string>Updater Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUFeedURL</key><string>http://127.0.0.1:1/unused.xml</string>
</dict></plist>
PLIST
swiftc -F "$framework_root" Sources/WindowTilerApp/AppUpdater.swift Scripts/test-updater.swift \
  -o "$test_app/Contents/MacOS/test" -framework AppKit -framework Sparkle \
  -Xlinker -rpath -Xlinker "$framework_root"
codesign --force --sign - "$test_app" >/dev/null 2>&1
"$test_app/Contents/MacOS/test" | tee "$test_root/result.txt"
printf 'Test result: %s\n' "$test_root/result.txt"
