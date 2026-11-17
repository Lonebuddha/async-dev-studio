#!/bin/sh
# The running app prepares a transaction, then starts this independent helper.
set -eu
# Terminal may send HUP when its command window closes. The updater must survive.
trap '' HUP
validate_app() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" = dev.asyncstudio.macos ] || return 1
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")" = AsyncDevStudio ] || return 1
    [ -x "$1/Contents/MacOS/AsyncDevStudio" ] || return 1
    /usr/bin/codesign --verify --deep --strict "$1"
}
require_newer_version() {
    [ -e "$target" ] || return 0
    previous=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")
    if ! /usr/bin/awk -v new="$version" -v old="$previous" 'BEGIN {
        n=split(new,a,"."); m=split(old,b,"."); limit=n>m?n:m
        for(i=1;i<=limit;i++) { if(a[i]+0>b[i]+0) exit 0; if(a[i]+0<b[i]+0) exit 1 }
        exit 1
    }'; then
        printf 'The installed app is already at this build or a newer one.\n' >&2
        return 1
    fi
}
target_running() {
    # Normalize both sides: different launch APIs preserve different /var aliases.
    /bin/ps -axo comm= | /usr/bin/awk '{ sub(/^[[:space:]]+/, ""); if ($0 ~ /\/AsyncDevStudio$/) print }' | (
        while IFS= read -r executable; do
            directory=$(CDPATH= cd -- "$(dirname -- "$executable")" 2>/dev/null && pwd -P) || continue
            if [ "$directory" = "$target/Contents/MacOS" ]; then exit 0; fi
        done
        exit 1
    )
}

case "${1:-}" in
--running-pids)
    # Launch Services may change the process name used by pgrep. Match executable paths.
    /bin/ps -axo pid=,comm= | /usr/bin/awk '$0 ~ /\/AsyncDevStudio$/ {print $1}'
    ;;
--prepare)
    [ "$#" -eq 4 ] || exit 2
    package=$2; target=$3; version=$4
    validate_app "$package"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$package/Contents/Info.plist")" = "$version" ]
    if [ -e "$target" ] || [ -L "$target" ]; then validate_app "$target"; fi
    require_newer_version
    /bin/mkdir -p "$(dirname -- "$target")"
    transaction=$(/usr/bin/mktemp -d "$(dirname -- "$target")/.async-dev-studio-update.XXXXXX")
    trap 'rm -rf -- "$transaction"' EXIT
    /usr/bin/ditto "$package" "$transaction/Async Dev Studio.app"
    validate_app "$transaction/Async Dev Studio.app"
    /bin/cp "$0" "$transaction/install-update.sh"
    /bin/chmod 700 "$transaction/install-update.sh"
    trap - EXIT
    printf '%s\n' "$transaction"
    ;;
--launch)
    [ "$#" -eq 8 ] || exit 2
    transaction=$2
    label="dev.asyncstudio.update.$(basename -- "$transaction")"
    printf '%s\n' "$label" > "$transaction/launchd.label"
    /bin/launchctl submit -l "$label" -o "$transaction/launcher.log" -e "$transaction/launcher.log" -- \
        /bin/sh "$0" --commit "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$label"
    # launchd owns the child, so closing Terminal or its parent app cannot reap it.
    attempts=0
    while [ ! -f "$transaction/helper.ready" ]; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 200 ]; then
            /bin/launchctl remove "$label" || true
            printf 'The update helper did not become ready. See %s/launcher.log\n' "$transaction" >&2
            exit 1
        fi
        /bin/sleep 0.02
    done
    /bin/cat "$transaction/helper.pid"
    ;;
--commit)
    { [ "$#" -eq 8 ] || [ "$#" -eq 9 ]; } || exit 2
    transaction=$2; target=$3; parent_pid=$4; manifest=$5; version=$6; opener=$7; result=$8
    job_label=${9:-}
    case "$parent_pid" in ''|*[!0-9]*) exit 2;; esac
    # ps reports the physical executable path (for example /private/var, not /var).
    target_parent=$(CDPATH= cd -- "$(dirname -- "$target")" && pwd -P)
    target="$target_parent/$(basename -- "$target")"
    package="$transaction/Async Dev Studio.app"
    backup="$transaction/previous.app"
    log="$transaction/install.log"
    exec >> "$log" 2>&1
    success=false; backed_up=false; installed=false; locked=false
    lock="$(dirname -- "$target")/.async-dev-studio-install.lock"
    finish() {
        if [ "$success" != true ]; then
            printf 'failed\n' > "$transaction/status.txt"
            # Never move a bundle once a process has started from it.
            if [ "$installed" = true ] && target_running; then
                message="Update could not finish safely. The previous application is retained at $backup."
            else
                if [ "$installed" = true ] && [ -d "$target" ]; then
                    /bin/mv "$target" "$transaction/failed.app" || true
                fi
                if [ "$backed_up" = true ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then
                    /bin/mv "$backup" "$target" || true
                fi
                if [ "$locked" = true ] && ! target_running && validate_app "$target"; then "$opener" -n "$target" || true; fi
                message="The update failed. The previous application was kept."
                if [ -d "$backup" ]; then message="The update failed. The previous application is retained at $backup."; fi
            fi
            /bin/mkdir -p "$(dirname -- "$result")"
            printf '%s\nDetails: %s\n' "$message" "$log" > "$result"
        fi
        if [ "$locked" = true ]; then /bin/rm -f "$lock/pid"; /bin/rmdir "$lock" || true; fi
        # submit jobs are removed explicitly, so this installer cannot be restarted.
        case "$job_label" in dev.asyncstudio.update.*) /bin/launchctl remove "$job_label" >/dev/null 2>&1 || true;; esac
    }
    trap finish EXIT
    trap 'exit 1' INT TERM
    printf '%s\n' "$$" > "$transaction/helper.pid"
    printf '%s\n' "$$" > "$transaction/helper.ready"
    printf 'Waiting for Async Dev Studio to quit (PID %s).\n' "$parent_pid"
    printf 'waiting\n' > "$transaction/status.txt"
    attempts=0
    while { [ "$parent_pid" -gt 0 ] && kill -0 "$parent_pid" 2>/dev/null; } || target_running; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 7200 ] || exit 1
        /bin/sleep 0.5
    done
    printf 'Application closed; verifying and installing build %s.\n' "$version"
    printf 'installing\n' > "$transaction/status.txt"
    # Recover a lock left by a crashed installer, but never interrupt a live one.
    if [ -d "$lock" ] && [ ! -L "$lock" ]; then
        owner=$(/bin/cat "$lock/pid" 2>/dev/null || true)
        case "$owner" in ''|*[!0-9]*) ;; *)
            if ! kill -0 "$owner" 2>/dev/null; then /bin/rm -f "$lock/pid"; /bin/rmdir "$lock" || true; fi;;
        esac
    fi
    /bin/mkdir "$lock"
    locked=true; printf '%s\n' "$$" > "$lock/pid"
    target_running && exit 1
    validate_app "$package"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$package/Contents/Info.plist")" = "$version" ]
    if [ -e "$target" ] || [ -L "$target" ]; then
        validate_app "$target"
        require_newer_version
        /bin/mv "$target" "$backup"; backed_up=true
    fi
    /bin/mv "$package" "$target"; installed=true
    validate_app "$target"
    "$opener" -n "$target"
    success=true
    /bin/rm -f "$manifest" "$result"
    # Retain the previous bundle for recovery; the next transaction has its own backup.
    printf 'installed\n' > "$transaction/status.txt"
    printf 'Installed %s\nPrevious bundle: %s\n' "$version" "$backup"
    ;;
--bootstrap)
    [ "$#" -eq 6 ] || exit 2
    package=$2; target=$3; version=$4; manifest=$5; result=$6
    pids=$(/bin/sh "$0" --running-pids)
    count=$(printf '%s\n' "$pids" | /usr/bin/awk 'NF {n++} END {print n+0}')
    [ "$count" -le 1 ] || { printf 'Close extra copies of Async Dev Studio and try again.\n' >&2; exit 1; }
    parent_pid=${pids:-0}
    printf 'Quit Async Dev Studio normally to install this update. Running commands will not be stopped automatically.\n'
    transaction=$(/bin/sh "$0" --prepare "$package" "$target" "$version")
    helper_pid=$(/bin/sh "$transaction/install-update.sh" --launch "$transaction" "$target" "$parent_pid" "$manifest" "$version" /usr/bin/open "$result")
    printf 'Updater is running independently in the background (PID %s).\n' "$helper_pid"
    printf 'Quit Async Dev Studio completely with Command-Q. The updated app will then reopen automatically.\n'
    printf 'You may close this command window. The new update menu appears after installation.\n'
    printf 'Installer status: %s/status.txt\n' "$transaction"
    printf 'Installer log: %s/install.log\n' "$transaction"
    ;;
*) printf 'Unknown update operation.\n' >&2; exit 2;;
esac
