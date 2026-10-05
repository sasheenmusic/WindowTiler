#!/bin/bash
# Offline integration tests. All downloads, signatures, and app launches are
# fixtures; nothing in /Applications or the real user defaults is changed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-installer-tests.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
trap 'status=$?; if [[ $status -ne 0 && -f $test_root/output ]]; then cat "$test_root/output" >&2; fi; rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/fixture"
export MOCK_ROOT="$test_root" PATH="$test_root/bin:$PATH"

cat > "$test_root/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
url='' output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output=$2; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry) shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$MOCK_ROOT/downloads"
case "$url" in
    https://api.github.com/repos/sasheenmusic/WindowTiler/releases/latest) cp "$MOCK_ROOT/release.json" "$output" ;;
    https://github.com/sasheenmusic/WindowTiler/releases/download/v1.2.0/Window-Tiler-1.2.0.zip) cp "$MOCK_ROOT/release.zip" "$output" ;;
    https://github.com/sasheenmusic/WindowTiler/releases/download/v1.2.0/Window-Tiler-1.2.0.zip.sha256) cp "$MOCK_ROOT/checksum" "$output" ;;
    *) echo "Unexpected URL: $url" >&2; exit 1 ;;
esac
MOCK
cat > "$test_root/bin/codesign" <<'MOCK'
#!/bin/bash
for app in "$@"; do :; done
[[ -f "$app/Contents/signature-fixture" && ! -f "$app/Contents/invalid-signature" ]]
MOCK
cat > "$test_root/bin/open" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_ROOT/opened"
if [[ ${MOCK_OPEN_STARTS_PROCESS:-false} == true ]]; then touch "$MOCK_ROOT/running"; rm -f "$MOCK_ROOT/stopped"; fi
if [[ ${MOCK_FAIL_OPEN:-false} == true && ! -f $MOCK_ROOT/open-failed ]]; then
    touch "$MOCK_ROOT/open-failed"
    exit 1
fi
MOCK
cat > "$test_root/bin/pgrep" <<'MOCK'
#!/bin/bash
if { [[ ${MOCK_RUNNING:-false} == true ]] || [[ -e $MOCK_ROOT/running ]]; } && [[ ! -e $MOCK_ROOT/stopped ]]; then echo 987654; exit 0; fi
exit 1
MOCK
cat > "$test_root/bin/ps" <<'MOCK'
#!/bin/bash
if { [[ ${MOCK_RUNNING:-false} == true ]] || [[ -e $MOCK_ROOT/running ]]; } && [[ ! -e $MOCK_ROOT/stopped ]]; then
    printf '%s\n' "$MOCK_PROCESS_PATH"
fi
MOCK
cat > "$test_root/shell-hooks" <<'MOCK'
kill() {
    [[ $1 == -TERM && $2 == 987654 ]] || return 1
    printf '%s\n' "$2" >> "$MOCK_ROOT/signals"
    touch "$MOCK_ROOT/stopped"
}
MOCK
export BASH_ENV="$test_root/shell-hooks"
cat > "$test_root/bin/uname" <<'MOCK'
#!/bin/bash
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 1 ;; esac
MOCK
cat > "$test_root/bin/sw_vers" <<'MOCK'
#!/bin/bash
echo 13.0
MOCK
cat > "$test_root/bin/mv" <<'MOCK'
#!/bin/bash
if [[ ${MOCK_FAIL_MOVE:-false} == true && $1 == *'.windowtiler-install.'*'/Window Tiler.app' && ! -f $MOCK_ROOT/move-failed ]]; then
    touch "$MOCK_ROOT/move-failed"
    exit 1
fi
exec /bin/mv "$@"
MOCK
chmod +x "$test_root/bin/"*

make_app() {
    local app=$1 version=$2 identifier=${3:-com.windowtiler.app}
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleExecutable</key><string>WindowTiler</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
    printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/WindowTiler"
    chmod +x "$app/Contents/MacOS/WindowTiler"
    touch "$app/Contents/signature-fixture" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    ln -s B "$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
    ln -s Versions/Current/Sparkle "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
}
archive_app() {
    rm -f "$test_root/release.zip"
    ditto -c -k --norsrc --keepParent "$test_root/fixture/Window Tiler.app" "$test_root/release.zip"
    printf '%s  Window-Tiler-1.2.0.zip\n' "$(shasum -a 256 "$test_root/release.zip" | awk '{print $1}')" > "$test_root/checksum"
}
reset_case() {
    rm -rf "$test_root/fixture/Window Tiler.app" "$test_root/destination"
    rm -f "$test_root/downloads" "$test_root/opened" "$test_root/open-failed" "$test_root/move-failed" "$test_root/stopped" "$test_root/running" "$test_root/signals"
    mkdir -p "$test_root/destination"
    export MOCK_FAIL_OPEN=false MOCK_FAIL_MOVE=false MOCK_RUNNING=false MOCK_OPEN_STARTS_PROCESS=false
    export MOCK_PROCESS_PATH="$test_root/destination/Window Tiler.app/Contents/MacOS/WindowTiler"
    printf '{"tag_name":"v1.2.0"}\n' > "$test_root/release.json"
    make_app "$test_root/fixture/Window Tiler.app" 1.2.0
    archive_app
}
installed_version() { plutil -extract CFBundleShortVersionString raw -o - "$test_root/destination/Window Tiler.app/Contents/Info.plist"; }
run_installer() { bash "$repo/install.sh" --install-dir "$test_root/destination" > "$test_root/output" 2>&1; }
expect_failure() {
    if run_installer; then cat "$test_root/output"; echo 'Expected installer failure' >&2; exit 1; fi
    [[ ! -e $test_root/destination/.windowtiler-install.lock ]]
}
pass() { printf 'PASS: %s\n' "$1"; }

reset_case
run_installer
[[ $(installed_version) == 1.2.0 && -L "$test_root/destination/Window Tiler.app/Contents/Frameworks/Sparkle.framework/Versions/Current" ]]
[[ -s $test_root/opened ]]
pass 'new install preserves safe framework symlinks and opens the app'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
run_installer
[[ $(installed_version) == 1.2.0 ]]
[[ $(find "$test_root/destination" -mindepth 1 -maxdepth 1 -name '.windowtiler*' | wc -l | tr -d ' ') == 0 ]]
pass 'upgrade replaces the existing app and removes the backup'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_RUNNING=true
run_installer
[[ $(installed_version) == 1.2.0 && -e $test_root/stopped && -s $test_root/opened ]]
pass 'running target is stopped by exact executable path and restarted'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_RUNNING=true MOCK_PROCESS_PATH='/different/Window Tiler.app/Contents/MacOS/WindowTiler'
expect_failure
[[ $(installed_version) == 1.1.0 && ! -e $test_root/stopped && ! -e $test_root/opened ]]
pass 'running app from another folder is never stopped'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.2.0
run_installer
[[ $(wc -l < "$test_root/downloads" | tr -d ' ') == 1 && ! -e $test_root/opened ]]
pass 'current version does not download or restart'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.10.0
run_installer
[[ $(installed_version) == 1.10.0 && $(wc -l < "$test_root/downloads" | tr -d ' ') == 1 ]]
pass 'numeric version comparison never downgrades a newer app'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
plutil -replace LSMinimumSystemVersion -string 14.0 "$test_root/fixture/Window Tiler.app/Contents/Info.plist"
archive_app
expect_failure
[[ $(installed_version) == 1.1.0 && ! -e $test_root/stopped && ! -e $test_root/opened ]]
pass 'unsupported release leaves the existing app untouched'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
printf '%064d  Window-Tiler-1.2.0.zip\n' 0 > "$test_root/checksum"
expect_failure
[[ $(installed_version) == 1.1.0 && ! -e $test_root/opened ]]
pass 'bad checksum leaves the old app untouched'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
plutil -replace CFBundleIdentifier -string com.example.wrong "$test_root/fixture/Window Tiler.app/Contents/Info.plist"
archive_app
expect_failure
[[ $(installed_version) == 1.1.0 ]]
pass 'wrong download bundle is rejected'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
touch "$test_root/fixture/Window Tiler.app/Contents/invalid-signature"
archive_app
expect_failure
[[ $(installed_version) == 1.1.0 ]]
pass 'invalid download signature is rejected'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_FAIL_MOVE=true
expect_failure
[[ $(installed_version) == 1.1.0 ]]
pass 'replacement failure rolls back the previous app'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_FAIL_OPEN=true
expect_failure
[[ $(installed_version) == 1.1.0 ]]
pass 'launch failure rolls back the previous app'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_FAIL_OPEN=true MOCK_RUNNING=true
expect_failure
[[ $(installed_version) == 1.1.0 && $(wc -l < "$test_root/opened" | tr -d ' ') == 2 ]]
pass 'launch failure restores and reopens the previously running app'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
export MOCK_FAIL_OPEN=true MOCK_RUNNING=true MOCK_OPEN_STARTS_PROCESS=true
expect_failure
[[ $(installed_version) == 1.1.0 && $(wc -l < "$test_root/signals" | tr -d ' ') == 2 ]]
pass 'partially launched new process is stopped before rollback'

reset_case
export MOCK_FAIL_OPEN=true
expect_failure
[[ ! -e "$test_root/destination/Window Tiler.app" ]]
pass 'failed first launch removes the unaccepted new installation'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
rm "$test_root/fixture/Window Tiler.app/Contents/Frameworks/Sparkle.framework/Sparkle"
ln -s /tmp "$test_root/fixture/Window Tiler.app/Contents/Frameworks/Sparkle.framework/Sparkle"
archive_app
expect_failure
[[ $(installed_version) == 1.1.0 ]]
pass 'escaping symlink is rejected before extraction'

reset_case
make_app "$test_root/destination/Window Tiler.app" 1.1.0
printf '{"tag_name":"v1.2.0/../../bad"}\n' > "$test_root/release.json"
expect_failure
[[ $(wc -l < "$test_root/downloads" | tr -d ' ') == 1 && $(installed_version) == 1.1.0 ]]
pass 'invalid tag cannot change download URLs'
printf 'PASS: all installer checks\n'
