#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${ROOT_DIR}/dist/TokenPulse-Studio-1.0.0.dmg"
PROFILE="${1:-notary-profile}"

echo "Submitting ${DMG_PATH} to Apple Notarization service using keychain profile '${PROFILE}'..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}"
echo "Notarized and stapled: ${DMG_PATH}"
