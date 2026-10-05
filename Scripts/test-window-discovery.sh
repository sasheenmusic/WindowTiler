#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-discovery-test.XXXXXX")"
cd "$repo_dir"
python3 - "$task_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/WindowTilerApp/WindowTiler.swift').read_text()
replacements = {
    'NSWorkspace.shared.runningApplications': 'TestOS.runningApplications',
    'NSScreen.screens': 'TestOS.screens',
    'AXUIElementCreateApplication(': 'TestOS.createApplication(',
    'AXUIElementCopyAttributeValue(': 'TestOS.copyAttribute(',
    'AXUIElementIsAttributeSettable(': 'TestOS.isSettable(',
    'AXUIElementSetAttributeValue(': 'TestOS.mutation(',
    'CGWindowListCopyWindowInfo(': 'TestOS.cgList(',
    'windowServerID(element, &number)': 'TestOS.windowID(element, &number)',
}
for original, replacement in replacements.items():
    assert original in source, f'OS test seam missing: {original}'
    source = source.replace(original, replacement)
Path(sys.argv[1], 'WindowTiler.swift').write_text(source)
PY
swiftc -emit-library -emit-module -module-name WindowTilerCore Sources/WindowTilerCore/*.swift \
    -emit-module-path "$task_dir/WindowTilerCore.swiftmodule" -o "$task_dir/libWindowTilerCore.dylib"
cp Scripts/test-window-discovery.swift "$task_dir/main.swift"
swiftc "$task_dir/WindowTiler.swift" Sources/WindowTilerApp/AppQuarantine.swift \
    Sources/WindowTilerApp/EnhancedUIState.swift Sources/WindowTilerApp/Log.swift "$task_dir/main.swift" \
    -I "$task_dir" -L "$task_dir" -lWindowTilerCore -Xlinker -rpath -Xlinker "$task_dir" \
    -o "$task_dir/test-discovery"
"$task_dir/test-discovery"
