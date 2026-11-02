#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenPulse"
BUNDLE_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cd "${ROOT_DIR}"
swift build -c release --product TokenPulseApp

rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/.build/release/TokenPulseApp" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.tokenpulse.studio</string>
    <key>CFBundleName</key>
    <string>TokenPulse Studio</string>
    <key>CFBundleDisplayName</key>
    <string>TokenPulse Studio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign by default so local Gatekeeper verification passes cleanly;
# When ready for Gate #3 release, pass SIGN_IDENTITY="Developer ID Application: ..."
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
codesign --verify --verbose=2 "${BUNDLE_DIR}"

echo "Packaged and verified: ${BUNDLE_DIR}"
