#!/bin/bash
set -euo pipefail
umask 077
: "${ANDROID_KEYSTORE_BASE64:?}" "${ANDROID_KEYSTORE_PASSWORD:?}" "${ANDROID_SYNC_DEFAULT_JSON:?}" "${ANDROID_SYNC_DEFAULT_TEST_JSON:?}"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$RUNNER_TEMP/upload.jks"
cat > "$RUNNER_TEMP/signing.properties" <<PROPS
storeFile=$RUNNER_TEMP/upload.jks
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyAlias=tos-upload
keyPassword=$ANDROID_KEYSTORE_PASSWORD
PROPS
mkdir -p android/app/src/release/assets
printf '%s' "$ANDROID_SYNC_DEFAULT_JSON" > android/app/src/release/assets/sync-default.json
printf '%s' "$ANDROID_SYNC_DEFAULT_TEST_JSON" > android/app/src/release/assets/sync-default-test.json
python3 -c 'import json,sys; [json.load(open(f)) for f in sys.argv[1:]]' android/app/src/release/assets/sync-default*.json
# Same offset scheme as iOS; a retry gets a distinct code.
export TOS_VERSION_CODE=$((1000 + GITHUB_RUN_NUMBER * 10 + GITHUB_RUN_ATTEMPT))
export TOS_SIGNING_PROPERTIES="$RUNNER_TEMP/signing.properties"
(cd android && ./gradlew --no-daemon testDebugUnitTest bundleRelease)
jarsigner -verify android/app/build/outputs/bundle/release/app-release.aab >/dev/null
echo "versionCode $TOS_VERSION_CODE"
