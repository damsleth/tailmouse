#!/bin/sh
# Build the Mac app signed with Developer ID, have Apple notarize it, staple
# the ticket and zip it: build/Tailmouse-<version>.zip, ready to hand out.
# Needs, once per machine:
#   - a "Developer ID Application" certificate for the team in Config/Local.xcconfig
#     (Xcode > Settings > Accounts > Manage Certificates; paid membership only)
#   - xcrun notarytool store-credentials tailmouse --apple-id <you> --team-id <team>
#     (asks for an app-specific password from account.apple.com)
# Usage: scripts/release.sh   (NOTARY_PROFILE=<name> to use another profile)
set -eu
cd "$(dirname "$0")/.."
profile=${NOTARY_PROFILE:-tailmouse}
security find-identity -v -p codesigning | grep -q '"Developer ID Application' || {
  echo "No Developer ID Application certificate in the keychain. See the top of $0." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || {
  echo "No notarytool profile \"$profile\". See the top of $0." >&2; exit 1; }

xcodegen generate --quiet
# Manual signing: automatic signing picks Apple Development, which Gatekeeper
# refuses on other Macs. The timestamp is required for notarization.
xcodebuild -project Tailmouse.xcodeproj -scheme TailmouseMac -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Developer ID Application' \
  OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet
app=build/Build/Products/Release/Tailmouse.app
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
zip=build/Tailmouse-$version.zip

ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
# Zip again: the first zip went to Apple without the ticket.
rm "$zip" && ditto -c -k --keepParent "$app" "$zip"
spctl -a -vv "$app"
echo "$zip"
