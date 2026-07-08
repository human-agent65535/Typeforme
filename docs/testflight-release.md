# TestFlight Release

This runbook publishes the current iOS host app and keyboard extension to TestFlight.

## Rules

- Keep the iOS host and keyboard build numbers in lockstep in `iOS/TypeformeIOS.xcodeproj/project.pbxproj`.
- The current TestFlight marketing version is `0.1.523`. Do not bump `MARKETING_VERSION` for TestFlight-only builds; increment `CURRENT_PROJECT_VERSION` only.
- Do not reuse a build number that App Store Connect has already accepted.
- Do not create new TestFlight groups. Use the existing `External` group.
- Do not create a new App Store Connect version group unless the user explicitly asks for a marketing-version change.
- Use an App Store Connect supported Xcode. If using a beta Xcode, verify Apple's release notes first.
- Use the App Store Connect API key from 1Password only when needed. Do not store key material in the repo.

## Required IDs

- App Store Connect app id: `6786583730`
- Existing external beta group id: `4af9debc-eb0c-46f0-bcd4-58b9d220e92a`
- 1Password item: `Typeforme Apple Signing Materials 2026-07-02`
- 1Password section/file for upload API key: `AppStoreConnectAPI/p8`

## Build And Upload

Run from the repository root.

```sh
scripts/check-app-store-readiness.sh

OUT="dist/testflight/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
cp dist/testflight/20260707-165201/ExportOptions.plist "$OUT/ExportOptions.plist"

VERSION="$(rg -m1 'MARKETING_VERSION = ' iOS/TypeformeIOS.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')"
BUILD="$(rg -m1 'CURRENT_PROJECT_VERSION = ' iOS/TypeformeIOS.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')"
test "$VERSION" = "0.1.523" || {
  echo "error: TestFlight marketing version must remain 0.1.523; got $VERSION" >&2
  exit 1
}
ARCHIVE="$OUT/TypeformeIOS-$VERSION-$BUILD.xcarchive"

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project iOS/TypeformeIOS.xcodeproj \
  -scheme TypeformeIOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive >"$OUT/archive.log" 2>&1

APP="$ARCHIVE/Products/Applications/Typeforme.app"
KEYBOARD="$APP/PlugIns/TypeformeKeyboard.appex"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$KEYBOARD/Info.plist"
```

Fetch the API key only after the archive is verified:

```sh
op item get "Typeforme Apple Signing Materials 2026-07-02" --format=json > /tmp/typeforme-op-signing.json
op read 'op://Private/Typeforme Apple Signing Materials 2026-07-02/AppStoreConnectAPI/p8' > /tmp/typeforme-asc-api-key.p8
chmod 600 /tmp/typeforme-asc-api-key.p8

KEY_ID="$(/usr/bin/python3 - <<'PY'
import json
item=json.load(open('/tmp/typeforme-op-signing.json'))
print(next(f['value'] for f in item['fields'] if f.get('label')=='App Store Connect API Key ID'))
PY
)"
ISSUER_ID="$(/usr/bin/python3 - <<'PY'
import json
item=json.load(open('/tmp/typeforme-op-signing.json'))
print(next(f['value'] for f in item['fields'] if f.get('label')=='App Store Connect API Issuer ID'))
PY
)"

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/upload" \
  -allowProvisioningUpdates \
  -authenticationKeyPath /tmp/typeforme-asc-api-key.p8 \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  >"$OUT/export-upload-api-key.log" 2>&1
```

The upload is complete only when the log ends with `Upload succeeded`.

## Add To External Testing

Create a short-lived App Store Connect JWT from the temporary p8 file:

```sh
/usr/bin/python3 - <<'PY' > /tmp/typeforme-asc-token
import base64, json, subprocess, time
item=json.load(open('/tmp/typeforme-op-signing.json'))
key_id=next(f['value'] for f in item['fields'] if f.get('label')=='App Store Connect API Key ID')
issuer=next(f['value'] for f in item['fields'] if f.get('label')=='App Store Connect API Issuer ID')
now=int(time.time())
header={'alg':'ES256','kid':key_id,'typ':'JWT'}
payload={'iss':issuer,'iat':now-30,'exp':now+20*60,'aud':'appstoreconnect-v1'}
def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj,separators=(',',':')).encode()).rstrip(b'=').decode()
signing=f"{b64(header)}.{b64(payload)}".encode()
der=subprocess.check_output(['openssl','dgst','-sha256','-sign','/tmp/typeforme-asc-api-key.p8'], input=signing)
i=2
if der[1] & 0x80:
    i=2+(der[1]&0x7f)
parts=[]
for _ in range(2):
    if der[i] != 0x02:
        raise SystemExit('bad signature')
    i += 1
    n = der[i]
    i += 1
    val = der[i:i+n].lstrip(b'\x00')
    i += n
    parts.append(val.rjust(32,b'\x00'))
sig=base64.urlsafe_b64encode(parts[0]+parts[1]).rstrip(b'=').decode()
print(signing.decode()+'.'+sig)
PY
TOKEN="$(cat /tmp/typeforme-asc-token)"
```

Poll App Store Connect at a low frequency until the uploaded build is `VALID`:

```sh
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=6786583730&filter%5Bversion%5D=$BUILD&include=betaGroups,betaAppReviewSubmission&limit=5" \
  > /tmp/typeforme-build.json
```

When the target build is `VALID`, add it to the existing `External` group and submit Beta Review:

```sh
BUILD_ID="$(/usr/bin/python3 - <<'PY'
import json
j=json.load(open('/tmp/typeforme-build.json'))
print(j['data'][0]['id'])
PY
)"

/usr/bin/python3 - <<PY
import json
build_id='$BUILD_ID'
json.dump({'data':[{'type':'builds','id':build_id}]}, open('/tmp/typeforme-add-external.json','w'))
json.dump({'data':{'type':'betaAppReviewSubmissions','relationships':{'build':{'data':{'type':'builds','id':build_id}}}}}, open('/tmp/typeforme-submit-review.json','w'))
PY

curl -fsS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @/tmp/typeforme-add-external.json \
  'https://api.appstoreconnect.apple.com/v1/betaGroups/4af9debc-eb0c-46f0-bcd4-58b9d220e92a/relationships/builds'

curl -fsS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data @/tmp/typeforme-submit-review.json \
  'https://api.appstoreconnect.apple.com/v1/betaAppReviewSubmissions'
```

Confirm the final state includes the `External` group and a `betaAppReviewSubmission`, then delete temporary key material:

```sh
rm -f /tmp/typeforme-asc-api-key.p8 /tmp/typeforme-op-signing.json /tmp/typeforme-asc-token
```
