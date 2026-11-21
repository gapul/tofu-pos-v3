#!/bin/bash
# Publish a signed APK to the passphrase-protected download page (cloudflare-download).
# Usage: download-publish.sh <apk> <version-code>. Needs CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID.
set -euo pipefail
apk=$1 code=$2
dir="$(cd "$(dirname "$0")/../cloudflare-download" && pwd)"
rm -rf "$dir/public" && mkdir -p "$dir/public"
cp "$apk" "$dir/public/TOS.apk"
date=$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M')
sed -e "s/__VERSION__/$code/" -e "s/__DATE__/$date JST/" "$dir/page.html" > "$dir/public/index.html"
cd "$dir" && npx --yes wrangler@4.158.0 deploy
rm -f "$dir/public/TOS.apk"
