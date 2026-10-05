#!/bin/bash
set -euo pipefail
# Only disposable fixture apps participate in this test. Parent/operator pauses
# the installed tiler first; this script never stops or starts the real app.
cd "$(dirname "$0")/.."
for pid in $(pgrep -x WindowTiler || true); do
    [[ "$(ps -p "$pid" -o stat=)" == *T* ]] || { echo 'Pause installed Window Tiler before native fixtures.' >&2; exit 1; }
done
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-foreground.XXXXXX")"
receipt="${1:-$task_dir/receipt.txt}"
target_app="$HOME/Applications/WindowTilerForegroundTargetFixture.app"
cover_app="$HOME/Applications/WindowTilerForegroundCoverFixture.app"
[[ ! -e "$target_app" && ! -e "$cover_app" ]] || { echo 'Foreground fixture already exists; refusing to overwrite.' >&2; exit 1; }
cleanup() {
    local app pid command bundle
    for app in "$target_app" "$cover_app"; do
        [[ -f "$app/Contents/Info.plist" ]] || continue
        bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
        [[ "$bundle" == com.windowtiler.foreground-target-fixture || "$bundle" == com.windowtiler.foreground-cover-fixture ]] || continue
        if [[ -f "$app/Contents/fixture.pid" ]]; then
            pid="$(cat "$app/Contents/fixture.pid")"
            command="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
            [[ "$command" != "$app/Contents/MacOS/Fixture" ]] || kill "$pid" 2>/dev/null || true
        fi
        rm -rf "$app"
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$task_dir/Harness.app/Contents/MacOS" "$HOME/Applications"
python3 - "$task_dir" "$target_app" "$cover_app" <<'PY'
import pathlib, plistlib, sys
root, target, cover = map(pathlib.Path, sys.argv[1:])
for app, identifier, executable in [(target,'com.windowtiler.foreground-target-fixture','Fixture'),(cover,'com.windowtiler.foreground-cover-fixture','Fixture'),(root/'Harness.app','com.windowtiler.foreground-harness','Harness')]:
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier, CFBundleName=app.stem, CFBundleExecutable=executable, CFBundlePackageType='APPL', CFBundleVersion='1')))
source = pathlib.Path('Sources/WindowTilerApp/PresetWindowService.swift').read_text()
needle = '$0.activationPolicy == .regular && !$0.isTerminated'
assert source.count(needle) == 1, 'Discovery isolation must match once'
source = source.replace(needle, '(["com.windowtiler.foreground-target-fixture", "com.windowtiler.foreground-cover-fixture"].contains($0.bundleIdentifier ?? "")) && ' + needle)
(root/'PresetWindowService.swift').write_text(source)
PY
swiftc -emit-library -emit-module -module-name WindowTilerCore Sources/WindowTilerCore/*.swift \
    -emit-module-path "$task_dir/WindowTilerCore.swiftmodule" -o "$task_dir/libWindowTilerCore.dylib"
cp Scripts/PresetFixtures/Fixture.swift "$task_dir/main.swift"
swiftc "$task_dir/main.swift" -o "$task_dir/Fixture"
cp "$task_dir/Fixture" "$target_app/Contents/MacOS/Fixture"
cp "$task_dir/Fixture" "$cover_app/Contents/MacOS/Fixture"
cp Scripts/PresetFixtures/ForegroundHarness.swift "$task_dir/main.swift"
swiftc "$task_dir/PresetWindowService.swift" Sources/WindowTilerApp/PresetSpaceBridge.swift \
    Sources/WindowTilerApp/PresetPrivateSymbol.swift Sources/WindowTilerApp/AppQuarantine.swift \
    Sources/WindowTilerApp/EnhancedUIState.swift Sources/WindowTilerApp/Log.swift "$task_dir/main.swift" \
    -I "$task_dir" -L "$task_dir" -lWindowTilerCore -Xlinker -rpath -Xlinker "$task_dir" \
    -o "$task_dir/Harness.app/Contents/MacOS/Harness"
"$task_dir/Harness.app/Contents/MacOS/Harness" > "$receipt" 2>&1
cat "$receipt"
echo "Receipt: $receipt"
rg -q '^RESULT failures=0$' "$receipt" && ! rg -q '^(FAIL|BLOCKED)' "$receipt"
