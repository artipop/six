#!/bin/sh
# Builds Savoia in Release and wraps it in a DMG you can drag into /Applications.
#
# There is no signing identity on this machine, so the app is signed ad-hoc ("Sign to Run Locally"),
# exactly as a Debug build is. That installs and runs fine here. Handing the DMG to someone else needs
# a Developer ID and notarisation — see docs/build.md.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"
version=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$root/Savoia.xcodeproj/project.pbxproj" | head -1)
dmg="$dist/savoia-$version.dmg"

echo "==> building Release"
xcodebuild -project "$root/Savoia.xcodeproj" -scheme Savoia -configuration Release \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath "$root/dist/DerivedData" \
    build

app="$root/dist/DerivedData/Build/Products/Release/Savoia.app"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }

echo "==> staging"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/Savoia.app"
ln -s /Applications "$stage/Applications"

# The mounted volume wears the app's icon.
icons="$stage/Savoia.iconset"
mkdir "$icons"
source="$root/Savoia/Assets.xcassets/IconLightWings.imageset/IconLightWings.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$source" --out "$icons/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$source" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$stage/.VolumeIcon.icns"
rm -r "$icons"

echo "==> $dmg"
mkdir -p "$dist"
rm -f "$dmg"
# Written read-write first: the custom-icon flag belongs on the mounted volume, and -srcfolder drops it.
scratch="$stage.rw.dmg"
hdiutil create -volname "Savoia $version" -srcfolder "$stage" -fs HFS+ -format UDRW -ov -quiet "$scratch"
mount=$(hdiutil attach "$scratch" -nobrowse -noverify -noautoopen | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)
SetFile -a C "$mount"
hdiutil detach "$mount" -quiet
hdiutil convert "$scratch" -format UDZO -o "$dmg" -quiet
rm -f "$scratch"

# And so does the file.
swift -e 'import AppKit; NSWorkspace.shared.setIcon(NSImage(contentsOfFile: CommandLine.arguments[1]), forFile: CommandLine.arguments[2])' \
    "$source" "$dmg" || true

echo
echo "$dmg"
ls -lh "$dmg" | awk '{print "    " $5}'
codesign -dv "$app" 2>&1 | sed -n 's/^/    /p'
