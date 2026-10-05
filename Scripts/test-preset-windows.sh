#!/bin/bash
set -euo pipefail

# Run in the user's GUI session, outside an execution sandbox. This test only
# moves its disposable fixture. Pause existing WindowTiler processes first so
# their automatic tiling cannot respond to the fixture's window changes.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
for tiler_pid in $(pgrep -x WindowTiler || true); do
    tiler_state="$(ps -p "$tiler_pid" -o stat=)"
    if [[ "$tiler_state" != *T* ]]; then
        echo "Pause running WindowTiler apps before this fixture test."
        exit 1
    fi
done

fixture_app="$HOME/Applications/WindowTilerPresetRegressionFixture.app"
if [[ -e "$fixture_app" ]]; then
    echo "Test fixture path already exists; refusing to overwrite it."
    exit 1
fi
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-preset-test.XXXXXX")"
receipt_path="${1:-$task_dir/receipt.txt}"

cleanup() {
    if [[ -f "$fixture_app/Contents/fixture.pid" ]]; then
        fixture_pid="$(cat "$fixture_app/Contents/fixture.pid")"
        fixture_command="$(ps -p "$fixture_pid" -o comm= 2>/dev/null || true)"
        if [[ "$fixture_command" == "$fixture_app/Contents/MacOS/Fixture" ]]; then
            kill "$fixture_pid" 2>/dev/null || true
        fi
    fi
    if [[ -f "$fixture_app/Contents/Info.plist" ]]; then
        fixture_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$fixture_app/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$fixture_id" == com.windowtiler.preset-fixture ]]; then
            rm -rf "$fixture_app"
        fi
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$task_dir/Fixture.app/Contents/MacOS" "$task_dir/Harness.app/Contents/MacOS" "$HOME/Applications"
python3 - "$task_dir" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
for name, bundle in [('Fixture', 'com.windowtiler.preset-fixture'), ('Harness', 'com.windowtiler.preset-harness')]:
    with (root / f'{name}.app/Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': bundle, 'CFBundleName': name, 'CFBundleExecutable': name,
                      'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSHighResolutionCapable': True}, stream)
PY

cd "$repo_dir"
swiftc -emit-library -emit-module -module-name WindowTilerCore Sources/WindowTilerCore/*.swift \
    -emit-module-path "$task_dir/WindowTilerCore.swiftmodule" -o "$task_dir/libWindowTilerCore.dylib"
cp Scripts/PresetFixtures/Fixture.swift "$task_dir/main.swift"
swiftc "$task_dir/main.swift" -o "$task_dir/Fixture.app/Contents/MacOS/Fixture"
cp -R "$task_dir/Fixture.app" "$fixture_app"

# Capture is the real read-only implementation. Presets bind only the fixture.
# Restrict just gather's app list in a temporary source copy; otherwise an
# integration test of "gather all" would move the user's off-Space windows.
python3 - "$task_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = Path('Sources/WindowTilerApp/PresetWindowService.swift').read_text()
needle = 'for app in runningApps() where !app.isHidden {'
assert source.count(needle) == 1, 'Gather isolation must match exactly once'
source = source.replace(needle, 'for app in runningApps().filter({ $0.bundleIdentifier == "com.windowtiler.preset-fixture" }) where !app.isHidden {')
(root / 'PresetWindowService.swift').write_text(source)
PY
cp Scripts/PresetFixtures/Harness.swift "$task_dir/main.swift"
swiftc "$task_dir/PresetWindowService.swift" Sources/WindowTilerApp/PresetSpaceBridge.swift \
    Sources/WindowTilerApp/PresetPrivateSymbol.swift Sources/WindowTilerApp/AppQuarantine.swift \
    Sources/WindowTilerApp/EnhancedUIState.swift \
    Sources/WindowTilerApp/Log.swift "$task_dir/main.swift" -I "$task_dir" -L "$task_dir" \
    -lWindowTilerCore -Xlinker -rpath -Xlinker "$task_dir" \
    -o "$task_dir/Harness.app/Contents/MacOS/Harness"

"$task_dir/Harness.app/Contents/MacOS/Harness" > "$receipt_path" 2>&1
cat "$receipt_path"
echo "Receipt: $receipt_path"
if ! rg -q '^RESULT failures=0$' "$receipt_path" || rg -q '^(FAIL|BLOCKED)' "$receipt_path"; then
    exit 1
fi
