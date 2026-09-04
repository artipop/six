#!/bin/sh
# Builds the two JavaScript payloads advanced blocking needs, from the AdGuard libraries on npm,
# into six/Blocking/Payload/. The output is committed, so building six needs no Node at all —
# this script is run only when SafariConverterLib moves.
#
#   ./scripts/blocking-payload.sh
#
# The versions are not chosen here: SafariConverterLib states which @adguard/scriptlets and
# @adguard/extended-css its converter's output expects (`ContentBlockerConverterVersion`), and a
# scriptlet the library does not know by that name is a rule that silently does nothing. So the
# versions are read out of the checkout Xcode resolved, and written beside the payload as
# versions.json — which six compares against the linked library at launch.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/six/Blocking/Payload"

checkout=$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/six-*/SourcePackages/checkouts/SafariConverterLib 2>/dev/null | head -1)
versions="$checkout/Sources/ContentBlockerConverter/ContentBlockerConverterVersion.swift"
if [ ! -f "$versions" ]; then
    echo "No SafariConverterLib checkout — build six once so SwiftPM resolves it, then run this again." >&2
    exit 1
fi
read_version() {
    sed -n "s/.*static let $1 = \"\\([^\"]*\\)\".*/\\1/p" "$versions"
}
library=$(read_version library)
scriptlets=$(read_version scriptlets)
extended_css=$(read_version extendedCSS)
echo "SafariConverterLib $library — scriptlets $scriptlets, extended-css $extended_css"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/package.json" <<JSON
{
  "name": "six-blocking-payload",
  "private": true,
  "type": "module",
  "dependencies": {
    "@adguard/extended-css": "$extended_css",
    "@adguard/scriptlets": "$scriptlets"
  },
  "devDependencies": { "esbuild": "^0.25.0" }
}
JSON
cp "$root/scripts/blocking-payload/cosmetic.js" "$root/scripts/blocking-payload/scriptlets.js" "$work/"
(cd "$work" && npm install --silent --no-audit --no-fund)

mkdir -p "$out"
for entry in cosmetic scriptlets; do
    # Prefixed: these land flat in the app bundle's Resources, beside everyone else's.
    (cd "$work" && npx --no-install esbuild "$entry.js" \
        --bundle --format=iife --minify --target=safari17 \
        --legal-comments=none --outfile="$out/blocking-$entry.js")
done

cat > "$out/blocking-versions.json" <<JSON
{
  "library": "$library",
  "scriptlets": "$scriptlets",
  "extendedCss": "$extended_css"
}
JSON

ls -l "$out"
