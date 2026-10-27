#!/bin/zsh
# Builds a Developer ID-signed, notarized DMG of UM-ONE Bridge in dist/.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials umone-notary --apple-id <apple-id> --team-id U3T5TG2HFV
#
# Usage: scripts/release.sh [--skip-notarize]
set -euo pipefail

cd "${0:A:h}/.."
PROFILE="${NOTARY_PROFILE:-umone-notary}"
IDENTITY="Developer ID Application: Juan Pedro Huici (U3T5TG2HFV)"
SKIP_NOTARIZE=false
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

DERIVED=build/ReleaseDerivedData
APP="$DERIVED/Build/Products/Release/UM-ONE Bridge.app"

echo "==> Building Release"
rm -rf "$DERIVED"
# generic/platform=macOS builds a universal (arm64 + x86_64) binary.
xcodebuild -project UMONEBridge.xcodeproj -scheme UMONEBridge -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" clean build \
    | grep -E 'error:|warning:|BUILD' | grep -v 'Metadata extraction' || true
[[ -d "$APP" ]] || { echo "build failed"; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/UM-ONE Bridge")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "expected a universal binary, got: $ARCHS"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/UM-ONE-Bridge-$VERSION.dmg"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured first: with pipefail, `grep -q` closing the pipe early would fail the pipeline.
SIGNATURE=$(codesign -dv "$APP" 2>&1)
[[ "$SIGNATURE" == *"(runtime)"* ]] || { echo "hardened runtime missing"; exit 1; }
[[ "$SIGNATURE" == *"TeamIdentifier=U3T5TG2HFV"* ]] || { echo "not signed with team U3T5TG2HFV"; exit 1; }
# Notarization rejects the debugger entitlement Xcode injects into non-archive builds.
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
[[ "$ENTITLEMENTS" != *get-task-allow* ]] || { echo "com.apple.security.get-task-allow present; notarization would fail"; exit 1; }

echo "==> Creating $DMG"
mkdir -p dist
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "UM-ONE Bridge" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if $SKIP_NOTARIZE; then
    echo "==> Skipping notarization; $DMG is signed but Gatekeeper will warn on other Macs"
else
    echo "==> Notarizing (profile $PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"
