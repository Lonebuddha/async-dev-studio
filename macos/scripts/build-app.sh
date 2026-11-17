#!/bin/sh
set -eu
macos_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLANG_MODULE_CACHE_PATH="$macos_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
sh "$macos_root/scripts/prepare-dependencies.sh"
swift build --package-path "$macos_root" --disable-sandbox -c release --product AsyncDevStudio
binary_directory=$(swift build --package-path "$macos_root" --disable-sandbox -c release --show-bin-path)
# Every bundle has its own path, including build-only previews that may be running.
mkdir -p "$macos_root/.build/bundles"
build_directory=$(mktemp -d "$macos_root/.build/bundles/build.XXXXXX")
app_path="$build_directory/Async Dev Studio.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_directory/AsyncDevStudio" "$app_path/Contents/MacOS/AsyncDevStudio"
build_commit=$(git -C "$macos_root/.." rev-parse HEAD)
build_dirty=false
if [ -n "$(git -C "$macos_root/.." status --porcelain)" ]; then build_dirty=true; fi
build_version="$(date +%s).$$"
python3 - "$app_path/Contents/Info.plist" "$build_commit" "$build_dirty" "$build_version" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'AsyncDevStudio', 'CFBundleIdentifier': 'dev.asyncstudio.macos',
    'CFBundleName': 'Async Dev Studio', 'CFBundleDisplayName': 'Async Dev Studio',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': sys.argv[4], 'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True, 'StudioBuildCommit': sys.argv[2],
    'StudioBuildDirty': sys.argv[3] == 'true',
}))
PY
cp "$macos_root/ThirdParty/SwiftTerm-LICENSE.txt" "$app_path/Contents/Resources/SwiftTerm-LICENSE.txt"
/usr/bin/ditto "$binary_directory/AsyncDevStudioMacOS_TeamsPlugin.bundle" "$app_path/Contents/Resources/AsyncDevStudioMacOS_TeamsPlugin.bundle"
cp "$macos_root/ThirdParty/Teams-icon-source.txt" "$app_path/Contents/Resources/Teams-icon-source.txt"
cp "$macos_root/scripts/install-update.sh" "$app_path/Contents/Resources/install-update.sh"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path" > "$macos_root/.build/latest-app.txt"
if [ "${STUDIO_INSTALL_APP:-1}" = 0 ]; then printf '%s\n' "$app_path"; exit 0; fi
updates_directory="$HOME/Library/Application Support/AsyncDevStudio/Updates"
mkdir -p "$updates_directory/packages" "$updates_directory/ready"
chmod 700 "$updates_directory" "$updates_directory/packages" "$updates_directory/ready"
package_directory=$(mktemp -d "$updates_directory/packages/package.XXXXXX")
package="$package_directory/Async Dev Studio.app"
/usr/bin/ditto "$app_path" "$package"
codesign --verify --deep --strict "$package"
target="$HOME/Applications/Async Dev Studio.app"
manifest="$updates_directory/ready/$build_version.json"
result="$updates_directory/last-error.txt"
bootstrap="$package_directory/Install Update.command"
python3 - "$manifest" "$package" "$build_version" "$build_commit" "$build_dirty" "$bootstrap" "$target" "$result" <<'PY'
import json, os, shlex, sys, tempfile
from pathlib import Path
manifest, package, version, commit, dirty, bootstrap, target, result = sys.argv[1:]
with tempfile.NamedTemporaryFile(mode='w', dir=Path(manifest).parent, delete=False) as stream:
    json.dump(dict(version=version, commit=commit, dirty=dirty == 'true', packagePath=package), stream)
    temporary = stream.name
os.replace(temporary, manifest)
helper = str(Path(package) / 'Contents/Resources/install-update.sh')
command = ['/bin/sh', helper, '--bootstrap', package, target, version, manifest, result]
Path(bootstrap).write_text('#!/bin/sh\nexec ' + ' '.join(map(shlex.quote, command)) + '\n')
os.chmod(bootstrap, 0o700)
PY
if [ -n "$(/bin/sh "$macos_root/scripts/install-update.sh" --running-pids)" ]; then
    printf 'Update ready: %s\nUse File → Install Update & Restart in the app.\nFor an older app without that action, open: %s\n' "$build_commit" "$bootstrap"
else
    transaction=$(/bin/sh "$macos_root/scripts/install-update.sh" --prepare "$package" "$target" "$build_version")
    /bin/sh "$transaction/install-update.sh" --commit "$transaction" "$target" 0 "$manifest" "$build_version" /usr/bin/true "$result"
    printf '%s\n' "$target"
fi
