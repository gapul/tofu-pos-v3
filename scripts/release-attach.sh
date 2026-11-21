#!/bin/bash
# Attach build artifacts to the GitHub release of this commit (one release per commit, shared by
# the iOS and Android workflows). Usage: release-attach.sh <label> <file>...
set -euo pipefail
: "${GH_TOKEN:?}" "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}"
label=$1; shift
tag="build-${GITHUB_SHA:0:7}"
title="TOS build ${GITHUB_SHA:0:7}"
notes="$(git log -1 --format='%s' "$GITHUB_SHA")"
# The two workflows may race to create the same release; whoever loses just uploads.
gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1 \
  || gh release create "$tag" -R "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --title "$title" --notes "$notes" --prerelease 2>/dev/null \
  || true
gh release upload "$tag" -R "$GITHUB_REPOSITORY" --clobber "$@"
echo "attached $label to $tag"
