#!/bin/zsh
set -e
setopt pipefail
SCRIPTS=${0:A:h}
cd ${SCRIPTS:h}
PBX=Outputs.xcodeproj/project.pbxproj
CURRENT=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' $PBX | grep -o '[0-9]*$')
NEXT=$((CURRENT + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEXT;/g" $PBX
VERSION=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' $PBX | grep -o '[0-9.]*$')
echo "building $VERSION ($NEXT)"
$SCRIPTS/test_dsp.sh | tail -1
DERIVED="${TMPDIR:-/tmp}/OutputsRelease"
xcodebuild -project Outputs.xcodeproj -scheme Outputs -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED" DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=all COPY_PHASE_STRIP=YES clean build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v appintents
DERIVED="$DERIVED" python3 - <<'PY'
import json,glob,os,sys
keys=set()
for f in glob.glob(os.environ['DERIVED']+'/Build/Intermediates.noindex/**/*.stringsdata',recursive=True):
    for tb in json.load(open(f)).get('tables',{}).values():
        for e in tb: keys.add(e['key'])
cat=json.load(open('Outputs/Localizable.xcstrings'))['strings']
keys-=set(json.load(open('Outputs/InfoPlist.xcstrings'))['strings'])
missing=sorted(k for k in keys if k not in cat); stale=[k for k in cat if k not in keys]
untranslated=[k for k,v in cat.items() if set(v.get('localizations',{}))!={'ru','en'}]
print('strings: missing',len(missing),'stale',len(stale),'untranslated',len(untranslated))
if missing or stale or untranslated:
    print(missing, stale, untranslated); sys.exit(1)
PY
APP="$DERIVED/Build/Products/Release/Outputs.app"
echo "built: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
pkill -TERM -x Outputs || true
sleep 1
rm -rf /Applications/Outputs.app
ditto "$APP" /Applications/Outputs.app
open -g /Applications/Outputs.app
[ "$1" = --no-dmg ] || $SCRIPTS/make_dmg.sh $VERSION
