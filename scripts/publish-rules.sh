#!/bin/sh
# Signs the rule library and puts it in docs/rules, which GitHub Pages serves to
# the app. Bump "version" in cleanup-rules.json first: the app only takes a newer one.
# The signing key stays outside the repo ($DISKLENS_RULES_KEY, ~/.disklens/rules-signing.key by default).
set -e
cd "$(dirname "$0")/.."
KEY="${DISKLENS_RULES_KEY:-$HOME/.disklens/rules-signing.key}"
swift build -c release --product disklens >/dev/null
.build/release/disklens rules sign "$KEY" Sources/DiskLensCore/Resources/cleanup-rules.json docs/rules
echo "Commit and push docs/rules to publish."
