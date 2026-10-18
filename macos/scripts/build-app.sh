#!/bin/sh
set -eu
macos_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLANG_MODULE_CACHE_PATH="$macos_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
sh "$macos_root/scripts/prepare-dependencies.sh"
swift build --package-path "$macos_root" --disable-sandbox -c release --product AsyncDevStudio
binary_directory=$(swift build --package-path "$macos_root" --disable-sandbox -c release --show-bin-path)
app_path="$macos_root/.build/Async Dev Studio.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_directory/AsyncDevStudio" "$app_path/Contents/MacOS/AsyncDevStudio"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>AsyncDevStudio</string>
    <key>CFBundleIdentifier</key><string>dev.asyncstudio.macos</string>
    <key>CFBundleName</key><string>Async Dev Studio</string>
    <key>CFBundleDisplayName</key><string>Async Dev Studio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$app_path/Contents/Resources"
cp -f "$macos_root/ThirdParty/SwiftTerm-LICENSE.txt" "$app_path/Contents/Resources/SwiftTerm-LICENSE.txt"
/usr/bin/ditto "$binary_directory/AsyncDevStudioMacOS_TeamsPlugin.bundle" "$app_path/Contents/Resources/AsyncDevStudioMacOS_TeamsPlugin.bundle"
cp -f "$macos_root/ThirdParty/Teams-icon-source.txt" "$app_path/Contents/Resources/Teams-icon-source.txt"
codesign --force --sign - "$app_path"
# Prepare the complete bundle before replacing the installed application.
applications_directory="$HOME/Applications"
installed_app="$applications_directory/Async Dev Studio.app"
mkdir -p "$applications_directory"
if [ -e "$installed_app" ] || [ -L "$installed_app" ]; then
    installed_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist" 2>/dev/null || true)
    if [ -L "$installed_app" ] || [ ! -d "$installed_app" ] || [ "$installed_identifier" != "dev.asyncstudio.macos" ]; then
        printf '%s\n' "Cannot replace an unrelated file or application at $installed_app" >&2
        exit 1
    fi
fi
installation_stage=$(mktemp -d "$applications_directory/.async-dev-studio-install.XXXXXX")
restore_previous=false
cleanup_installation() {
    if [ "$restore_previous" = true ] && [ ! -e "$installed_app" ]; then
        if ! mv "$installation_stage/previous.app" "$installed_app"; then
            printf '%s\n' "Previous application retained at $installation_stage/previous.app" >&2
            return
        fi
    fi
    rm -rf "$installation_stage"
}
trap cleanup_installation EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto "$app_path" "$installation_stage/Async Dev Studio.app"
codesign --verify --deep --strict "$installation_stage/Async Dev Studio.app"
if [ -d "$installed_app" ]; then
    restore_previous=true
    mv "$installed_app" "$installation_stage/previous.app"
fi
mv "$installation_stage/Async Dev Studio.app" "$installed_app"
restore_previous=false
printf '%s\n' "$installed_app"
