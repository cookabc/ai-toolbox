#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p dist
package_dir="$(mktemp -d "$project_root/dist/.package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
app_dir="$package_dir/AIToolbox.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

# The icon is pixel art: every slot of the iconset is drawn at a whole number of
# pixels per cell (USAGE_RENDER_ICON=1 swift test --filter testRenderAppIcon).
# Resampling one large PNG would blur the small sizes, so the slots are used as-is.
iconutil -c icns Assets/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"

cp "$binary_dir/AIToolbox" "$app_dir/Contents/MacOS/AIToolbox"
resource_bundle="$binary_dir/AIToolbox_AIToolbox.bundle"
# SwiftPM emits a macOS-style bundle (Contents/Resources) on current toolchains
# and a flat one on older releases; pick whichever actually holds the files.
resource_root="$resource_bundle"
if [[ -d "$resource_bundle/Contents/Resources" ]]; then
    resource_root="$resource_bundle/Contents/Resources"
fi
# The pixel font and its licence. The app falls back to the system font without
# it, so a missing file would ship silently — fail the build instead.
font="ark-pixel-12px-proportional-latin.woff2"
if [[ ! -f "$resource_root/$font" ]]; then
    printf 'Missing %s in %s\n' "$font" "$resource_root" >&2
    exit 1
fi
cp "$resource_root/$font" "$resource_root/ArkPixel-OFL.txt" "$app_dir/Contents/Resources/"

# The interface's only localization (see CFBundleLocalizations in Info.plist).
mkdir -p "$app_dir/Contents/Resources/en.lproj"
printf '/* The interface is English; see L10n.swift. */\n' \
    > "$app_dir/Contents/Resources/en.lproj/InfoPlist.strings"

cp Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
# Preserve the previous local build until its replacement has passed signing.
if [[ -e dist/AIToolbox.app ]]; then
    mv dist/AIToolbox.app "$package_dir/previous.app"
fi
if ! mv "$app_dir" dist/AIToolbox.app; then
    if [[ -e "$package_dir/previous.app" ]]; then
        mv "$package_dir/previous.app" dist/AIToolbox.app
    fi
    exit 1
fi
printf 'Built %s/dist/AIToolbox.app\n' "$project_root"
