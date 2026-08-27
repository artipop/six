#!/bin/sh
# Builds six in Release and wraps it in a DMG you can drag into /Applications.
#
# There is no signing identity on this machine, so the app is signed ad-hoc ("Sign to Run Locally"),
# exactly as a Debug build is. That installs and runs fine here. Handing the DMG to someone else needs
# a Developer ID and notarisation — see docs/build.md.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"
version=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$root/six.xcodeproj/project.pbxproj" | head -1)
dmg="$dist/six-$version.dmg"

echo "==> building Release"
xcodebuild -project "$root/six.xcodeproj" -scheme six -configuration Release \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath "$root/dist/DerivedData" \
    build

app="$root/dist/DerivedData/Build/Products/Release/six.app"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }

echo "==> staging"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/six.app"
ln -s /Applications "$stage/Applications"

echo "==> $dmg"
mkdir -p "$dist"
rm -f "$dmg"
hdiutil create -volname "six $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov -quiet "$dmg"

echo
echo "$dmg"
ls -lh "$dmg" | awk '{print "    " $5}'
codesign -dv "$app" 2>&1 | sed -n 's/^/    /p'
