#!/bin/zsh
set -e
setopt pipefail
VERSION=$1
SCRIPTS=${0:A:h}
cd ${SCRIPTS:h}
STAGE="${TMPDIR:-/tmp}/OutputsDMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto /Applications/Outputs.app "$STAGE/Outputs.app"
ln -s /Applications "$STAGE/Applications"
rm -f Outputs-$VERSION.dmg
hdiutil create -volname "Outputs $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov Outputs-$VERSION.dmg -quiet
rm -rf "$STAGE"
hdiutil verify Outputs-$VERSION.dmg 2>&1 | tail -1
MP=$(hdiutil attach Outputs-$VERSION.dmg -nobrowse -readonly | awk -F'\t' '/\/Volumes/{print $NF}')
diff -r "$MP/Outputs.app" /Applications/Outputs.app && echo identical
echo "paths in binary: $(strings -a "$MP/Outputs.app/Contents/MacOS/Outputs" | grep -c '/Users/')"
hdiutil detach "$MP" -quiet
