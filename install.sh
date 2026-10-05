#!/bin/bash
# Install or update the official Apple silicon release. macOS 13+, Bash 3.2.
set -euo pipefail

fail() { printf 'Window Tiler: %s\n' "$*" >&2; exit 1; }
install_dir=''
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && $1 == --install-dir && -n $2 ]] || fail 'Usage: bash install.sh [--install-dir DIRECTORY]'
    install_dir=$2
fi
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'This download requires an Apple silicon Mac.'
os_version=$(sw_vers -productVersion)
[[ ${os_version%%.*} -ge 13 ]] || fail 'macOS 13 or later is required.'

app_name='Window Tiler.app'
bundle_id='com.windowtiler.app'
valid_version() { [[ $1 =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]; }
normalize_os_version() {
    local version=$1
    [[ $version =~ ^[0-9]+\.[0-9]+$ ]] && version="$version.0"
    valid_version "$version" || return 1
    printf '%s\n' "$version"
}
not_newer() {
    local left right index
    IFS=. read -r -a left <<< "$1"
    IFS=. read -r -a right <<< "$2"
    for index in 0 1 2; do
        (( 10#${left[index]} > 10#${right[index]} )) && return 0
        (( 10#${left[index]} < 10#${right[index]} )) && return 1
    done
    return 0
}
plist_value() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist"; }
validate_app() {
    local app=$1 expected=${2:-} version minimum link destination parent physical
    [[ -d $app && ! -L $app && -f $app/Contents/Info.plist && ! -L $app/Contents/Info.plist ]] || return 1
    [[ $(plist_value "$app" CFBundleIdentifier) == "$bundle_id" ]] || return 1
    [[ $(plist_value "$app" CFBundleExecutable) == WindowTiler ]] || return 1
    [[ $(plist_value "$app" CFBundlePackageType) == APPL ]] || return 1
    version=$(plist_value "$app" CFBundleShortVersionString) || return 1
    valid_version "$version" || return 1
    [[ -z $expected || $version == "$expected" ]] || return 1
    minimum=$(plist_value "$app" LSMinimumSystemVersion) || return 1
    minimum=$(normalize_os_version "$minimum") || return 1
    not_newer "$(normalize_os_version "$os_version")" "$minimum" || return 1
    [[ -f $app/Contents/MacOS/WindowTiler && -x $app/Contents/MacOS/WindowTiler && ! -L $app/Contents/MacOS/WindowTiler ]] || return 1
    physical=$(cd "$app" && pwd -P) || return 1
    while IFS= read -r -d '' link; do
        destination=$(readlink "$link") || return 1
        case "$destination" in ''|/*) return 1 ;; esac
        case "/$destination/" in */../*) return 1 ;; esac
        parent=$(cd "$(dirname "$link")/$(dirname "$destination")" && pwd -P) || return 1
        [[ $parent == "$physical" || $parent == "$physical/"* ]] || return 1
        [[ -e $link ]] || return 1
    done < <(find "$app" -type l -print0)
    codesign --verify --deep --strict "$app" >/dev/null 2>&1
}

# Prefer the existing copy, even when another install directory is writable.
if [[ -z $install_dir ]]; then
    system_app="/Applications/$app_name"
    user_app="$HOME/Applications/$app_name"
    if [[ -e $system_app || -L $system_app ]]; then
        [[ ! -e $user_app && ! -L $user_app ]] || fail 'Two installed copies found. Remove the extra copy before updating.'
        install_dir=/Applications
    elif [[ -e $user_app || -L $user_app ]]; then
        install_dir="$HOME/Applications"
    elif [[ -w /Applications ]]; then
        install_dir=/Applications
    else
        install_dir="$HOME/Applications"
    fi
fi
mkdir -p "$install_dir" || fail 'Cannot create the install directory.'
install_dir=$(cd "$install_dir" && pwd -P)
[[ -w $install_dir ]] || fail "The install directory is not writable: $install_dir"
target="$install_dir/$app_name"
target_executable="$target/Contents/MacOS/WindowTiler"
current_version=''
if [[ -e $target || -L $target ]]; then
    validate_app "$target" || fail 'The existing app is not a valid Window Tiler installation. It was left untouched.'
    current_version=$(plist_value "$target" CFBundleShortVersionString)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/windowtiler-install.XXXXXX")
stage=''
backup=''
replacing=false
was_running=false
lock=''
stop_unaccepted_app() {
    local pid command attempts
    for pid in $(pgrep -u "$(id -u)" -x WindowTiler || true); do
        command=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        [[ $command == "$target_executable" ]] || continue
        kill -TERM "$pid" || return 1
        attempts=0
        while [[ $(ps -p "$pid" -o comm= 2>/dev/null || true) == "$target_executable" ]]; do
            (( attempts += 1 ))
            [[ $attempts -le 50 ]] || return 1
            sleep 0.1
        done
    done
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ $replacing == true ]] && { [[ -n $backup && -d $backup ]] || [[ -z $current_version && ! -e $stage/$app_name ]]; }; then
        if ! stop_unaccepted_app; then
            printf 'Window Tiler: cannot stop the new copy; keeping it and its backup at %s for recovery.\n' "$stage" >&2
            stage=''
            replacing=false
        fi
    fi
    if [[ $replacing == true ]]; then
        # The new copy was never accepted. Restore the previous directory.
        if [[ -n $backup && -d $backup ]]; then
            if [[ -e $target || -L $target ]]; then rm -rf "$target"; fi
            if mv "$backup" "$target"; then
                :
            else
                printf 'Window Tiler: rollback failed; the old app is at %s\n' "$backup" >&2
                stage='' # Preserve the backup for manual recovery.
            fi
        elif [[ -z $current_version && ! -e $stage/$app_name ]]; then
            if [[ -e $target || -L $target ]]; then rm -rf "$target"; fi
        fi
    fi
    if [[ $status -ne 0 && $was_running == true ]] && validate_app "$target" "$current_version"; then
        open "$target" >/dev/null 2>&1 || true
    fi
    [[ -z $stage ]] || rm -rf "$stage"
    [[ -z $lock ]] || rmdir "$lock" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$install_dir/.windowtiler-install.lock" || fail 'Another installer is running, or its lock remains in the install directory.'
lock="$install_dir/.windowtiler-install.lock"

fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --retry 2 "$1" -o "$2"; }
fetch 'https://api.github.com/repos/sasheenmusic/WindowTiler/releases/latest' "$work/release.json"
tag=$(plutil -extract tag_name raw -o - "$work/release.json") || fail 'Cannot read the latest release.'
[[ $tag == v* ]] && valid_version "${tag#v}" || fail 'The release version is invalid.'
version=${tag#v}
if [[ -n $current_version ]] && not_newer "$current_version" "$version"; then
    printf 'Window Tiler %s is already installed.\n' "$current_version"
    exit 0
fi
archive="Window-Tiler-$version.zip"
base="https://github.com/sasheenmusic/WindowTiler/releases/download/$tag"
fetch "$base/$archive" "$work/$archive"
fetch "$base/$archive.sha256" "$work/checksum"
expected=$(awk -v name="$archive" 'NF == 2 && $2 == name && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ { print tolower($1); count++ } END { if (NR != 1 || count != 1) exit 1 }' "$work/checksum") || fail 'The release checksum file is invalid.'
actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}')
[[ $actual == "$expected" ]] || fail 'The download checksum does not match. The existing app was left untouched.'

# Reject paths and link destinations that could escape extraction. Normal
# framework links are relative and remain inside the signed app bundle.
unzip -Z1 "$work/$archive" > "$work/entries" || fail 'The download is not a ZIP archive.'
[[ -s $work/entries ]] || fail 'The ZIP archive is empty.'
while IFS= read -r entry || [[ -n $entry ]]; do
    case "$entry" in
        "$app_name/"*) ;;
        '__MACOSX/'|"__MACOSX/$app_name/"*|"__MACOSX/._$app_name") ;;
        *) fail 'The ZIP archive contains an unexpected path.' ;;
    esac
    case "/${entry%/}/" in */../*|*/./*|*'//'*|*'\'*|*'?'*|*'*'*|*'['*) fail 'The ZIP archive contains an unsafe path.' ;; esac
done < "$work/entries"
unzip -Z -l "$work/$archive" > "$work/permissions"
awk '/^l/ { sub(/^([^ ]+ +){9}/, ""); print }' "$work/permissions" > "$work/links"
while IFS= read -r entry; do
    [[ $entry == "$app_name/Contents/Frameworks/"* ]] || fail 'The ZIP archive contains an unexpected symlink.'
    destination=$(unzip -p "$work/$archive" "$entry")
    case "$destination" in ''|/*) fail 'The ZIP archive contains an unsafe symlink.' ;; esac
    case "/$destination/" in */../*|*'\'*) fail 'The ZIP archive contains an unsafe symlink.' ;; esac
done < "$work/links"
ditto -x -k "$work/$archive" "$work/unpacked"
validate_app "$work/unpacked/$app_name" "$version" || fail 'The downloaded app failed validation. The existing app was left untouched.'

# Prepare on the destination volume before stopping the running app.
stage=$(mktemp -d "$install_dir/.windowtiler-install.XXXXXX")
ditto "$work/unpacked/$app_name" "$stage/$app_name"
validate_app "$stage/$app_name" "$version" || fail 'The staged app failed validation.'
backup="$stage/previous.app"
pids=$(pgrep -u "$(id -u)" -x WindowTiler || true)
for pid in $pids; do
    command=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    [[ -z $command || $command == "$target_executable" ]] || fail 'Window Tiler is running from a different folder. Quit it before installing.'
done
for pid in $pids; do
    command=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    if [[ $command == "$target_executable" ]]; then
        was_running=true
        kill -TERM "$pid" || fail 'Cannot stop the running app.'
    fi
done
for pid in $pids; do
    attempts=0
    while [[ $(ps -p "$pid" -o comm= 2>/dev/null || true) == "$target_executable" ]]; do
        (( attempts += 1 ))
        [[ $attempts -le 50 ]] || fail 'The running app did not quit. The installation was left untouched.'
        sleep 0.1
    done
done
replacing=true
if [[ -n $current_version ]]; then
    validate_app "$target" "$current_version" || fail 'The existing app changed during installation.'
    mv "$target" "$backup"
else
    [[ ! -e $target && ! -L $target ]] || fail 'An app appeared in the install directory. It was left untouched.'
fi
mv "$stage/$app_name" "$target"
validate_app "$target" "$version" || fail 'The installed app failed validation.'
open "$target" || fail 'The new app could not open. Restoring the previous installation.'
replacing=false
printf 'Installed Window Tiler %s in %s.\n' "$version" "$install_dir"
printf 'If macOS blocks opening, use System Settings → Privacy & Security → Open Anyway. Then enable Accessibility access.\n'
