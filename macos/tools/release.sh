#!/bin/bash
# Build a release: fresh binary -> app bundle -> signed+notarized DMG -> zip.
#   usage: macos/tools/release.sh          (uses version from Info.plist)
#
# Signing/notarizing needs one-time setup:
#   1. A "Developer ID Application" cert in the keychain (Xcode > Settings >
#      Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notarization credentials stored once:
#      xcrun notarytool store-credentials amux-notary \
#        --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   3. Export SIGN_IDENTITY to match `security find-identity -v -p codesigning`.
#
# Without a matching identity in the keychain, this falls back to ad-hoc
# signing (unsigned-for-others, fine for local testing only).
set -euo pipefail
cd "$(dirname "$0")/.."

# Set SIGN_IDENTITY in your environment to the identity from
#   security find-identity -v -p codesigning
# Left empty, the build falls back to ad-hoc signing (fine locally, blocked by
# Gatekeeper on other people's machines).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-amux-notary}"

swift build -c release
# git does not keep empty directories, so a fresh checkout has no MacOS folder
mkdir -p dist/Amux.app/Contents/MacOS
cp .build/release/amux dist/Amux.app/Contents/MacOS/amux
rm -rf dist/Amux.app/Contents/Resources/amux_amux.bundle
cp -R .build/release/amux_amux.bundle dist/Amux.app/Contents/Resources/
# also drop the icons straight into Resources: SwiftPM emits the bundle without
# an Info.plist, so nothing may rely on it resolving as a real Bundle
rm -rf dist/Amux.app/Contents/Resources/agent-icons
cp -R Sources/amux/Resources/agent-icons dist/Amux.app/Contents/Resources/

if [ -n "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "signing with: $SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp -s "$SIGN_IDENTITY" dist/Amux.app
    SIGNED=1
else
    echo "warning: no Developer ID identity set, falling back to ad-hoc signing"
    echo "         (Gatekeeper will block this build on other people's Macs)"
    codesign --force --deep -s - dist/Amux.app
    SIGNED=0
fi

VER=$(defaults read "$PWD/dist/Amux.app/Contents/Info.plist" CFBundleShortVersionString)
STAGE=$(mktemp -d)
cp -R dist/Amux.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/amux-$VER.dmg" "dist/amux-$VER-macos.zip"
hdiutil create -volname "amux $VER" -srcfolder "$STAGE" -ov -format UDZO -quiet "dist/amux-$VER.dmg"
rm -rf "$STAGE"

if [ "$SIGNED" = "1" ]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "notarizing (this calls out to Apple and can take a few minutes)..."
        xcrun notarytool submit "dist/amux-$VER.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "dist/amux-$VER.dmg"
    else
        echo "warning: no notarytool credentials stored as '$NOTARY_PROFILE' — skipping notarization"
        echo "         run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id you@example.com --team-id TEAMID --password <app-specific-password>"
    fi
fi

( cd dist && zip -q -r "amux-$VER-macos.zip" "amux-$VER.dmg" )

echo "built dist/amux-$VER.dmg and dist/amux-$VER-macos.zip"
echo "next: git tag v$VER && git push origin v$VER"
echo "      gh release create v$VER dist/amux-$VER-macos.zip --title \"amux $VER\" --notes-file NOTES.md"
