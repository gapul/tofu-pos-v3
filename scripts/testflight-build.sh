#!/bin/bash
set -euo pipefail
umask 077
: "${IOS_P12_BASE64:?}" "${IOS_P12_PASSWORD:?}" "${IOS_PROFILE_BASE64:?}" "${IOS_SYNC_DEFAULT_JSON:?}"
export CI_KEYCHAIN="$RUNNER_TEMP/tos-ci.keychain-db"
keychain_password=$(openssl rand -hex 24)
printf '::add-mask::%s\n' "$keychain_password"
security create-keychain -p "$keychain_password" "$CI_KEYCHAIN"
security set-keychain-settings -lut 3600 "$CI_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$CI_KEYCHAIN"
security list-keychains -d user -s "$CI_KEYCHAIN" login.keychain-db
printf '%s' "$IOS_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/signing.p12"
printf '%s' "$IOS_PROFILE_BASE64" | base64 --decode > "$RUNNER_TEMP/profile.mobileprovision"
security import "$RUNNER_TEMP/signing.p12" -k "$CI_KEYCHAIN" -P "$IOS_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$CI_KEYCHAIN" >/dev/null
security cms -D -i "$RUNNER_TEMP/profile.mobileprovision" > "$RUNNER_TEMP/profile.plist"
profile_uuid=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$RUNNER_TEMP/profile.plist")
for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$RUNNER_TEMP/profile.mobileprovision" "$dir/$profile_uuid.mobileprovision"
done
mkdir -p ios/Config
printf '%s' "$IOS_SYNC_DEFAULT_JSON" > ios/Config/sync-default.json
python3 -c 'import json; json.load(open("ios/Config/sync-default.json"))'
(cd ios && xcodegen generate)
# Offset existing local builds; retries receive a distinct dotted build number.
build_number="$((1000 + GITHUB_RUN_NUMBER)).${GITHUB_RUN_ATTEMPT}"
xcodebuild -project ios/TofuPOS.xcodeproj -scheme TofuPOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$RUNNER_TEMP/TofuPOS.xcarchive" \
  CURRENT_PROJECT_VERSION="$build_number" DEVELOPMENT_TEAM=S3H296G6Q5 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" \
  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption=NO archive
python3 - <<'PY'
import os, plistlib
with open(os.environ['RUNNER_TEMP'] + '/ExportOptions.plist', 'wb') as f:
    plistlib.dump({'method': 'app-store-connect', 'teamID': 'S3H296G6Q5',
                  'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution',
                  'manageAppVersionAndBuildNumber': False,
                  'provisioningProfiles': {'dev.gapul.tofupos.v3': 'TOS App Store'}}, f)
PY
xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/TofuPOS.xcarchive" \
  -exportPath "$RUNNER_TEMP/export" -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist"
