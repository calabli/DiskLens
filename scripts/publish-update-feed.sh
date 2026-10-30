#!/bin/bash
# Writes the release list the in-app updater reads to docs/updates/releases.json, which
# GitHub Pages serves without the API's rate limit. Run after publishing a release,
# then commit and push docs/updates (release.sh does all of this).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/updates
gh api "repos/calabli/DiskLens/releases?per_page=20" --jq '[.[] | select(.draft | not) | {
    tag_name, name, body, prerelease, draft, published_at, html_url,
    assets: [.assets[] | {name, size, browser_download_url}]
  }]' > docs/updates/releases.json
echo "Wrote docs/updates/releases.json ($(grep -o '"tag_name"' docs/updates/releases.json | wc -l | tr -d ' ') releases)"
