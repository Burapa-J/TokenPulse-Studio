#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenPulse"
VERSION="1.0.0"
DIST_DIR="${ROOT_DIR}/dist"
BUNDLE_DIR="${DIST_DIR}/${APP_NAME}.app"
STAGING_DIR="${DIST_DIR}/dmg-staging"
DMG_PATH="${DIST_DIR}/TokenPulse-Studio-${VERSION}.dmg"

cd "${ROOT_DIR}"

# 1. Detect Developer ID Application SHA-1 fingerprint (avoids ambiguous common-name error when multiple certs exist)
DETECTED_DEV_ID="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/ {print $2; exit}')"
SIGN_IDENTITY="${SIGN_IDENTITY:-${DETECTED_DEV_ID:--}}"

echo "Using signing identity: ${SIGN_IDENTITY}"

# 2. Build release binary and bundle .app
SIGN_IDENTITY="${SIGN_IDENTITY}" bash "${ROOT_DIR}/scripts/package_app.sh"

if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "Applying Hardened Runtime + Secure Timestamp with Developer ID..."
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"

# 3. Stage .dmg contents with /Applications drop-link
rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"
cp -R "${BUNDLE_DIR}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# 4. Create compressed UDZO .dmg installer
hdiutil create \
    -volname "TokenPulse Studio" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

# 5. Sign and verify the .dmg itself when Developer ID is available
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
    codesign --verify --verbose=2 "${DMG_PATH}"
fi

shasum -a 256 "${DMG_PATH}"
ls -lh "${DMG_PATH}"
echo "DMG Ready: ${DMG_PATH}"
