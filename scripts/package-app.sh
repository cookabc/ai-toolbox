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
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources" "$package_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$package_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" Assets/AppIcon.png --out "$package_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$package_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cp "$binary_dir/AIUsage" "$app_dir/Contents/MacOS/AIToolbox"
resource_bundle="$binary_dir/AIUsage_AIUsage.bundle"
if [[ -d "$resource_bundle" ]]; then
    cp "$resource_bundle"/BrandClaude.svg "$app_dir/Contents/Resources/"
    cp "$resource_bundle"/BrandCodex.svg "$app_dir/Contents/Resources/"
fi
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
