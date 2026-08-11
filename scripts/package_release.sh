#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Meetingnotes"
PROJECT="Meetingnotes.xcodeproj"
SCHEME="meetingnotes"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
BUILD_ROOT="${BUILD_ROOT:-$RUNNER_TEMP/meetingnotes-release}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
RELEASE_DIR="$BUILD_ROOT/release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

required_variables=(
  VERSION
  SIGNING_IDENTITY
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_PASSWORD
  SPARKLE_PRIVATE_KEY
  GITHUB_REPOSITORY
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required environment variable: $variable" >&2
    exit 1
  fi
done

project_version=$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" | sed 's/.*= \(.*\);/\1/')
if [[ "$project_version" != "$VERSION" ]]; then
  echo "Release version $VERSION does not match project version $project_version" >&2
  exit 1
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$RELEASE_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_CONTENTS="$SPARKLE_FRAMEWORK/Versions/B"

sign_component() {
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$1"
}

sign_component "$SPARKLE_CONTENTS/XPCServices/Installer.xpc"
if [[ -d "$SPARKLE_CONTENTS/XPCServices/Downloader.xpc" ]]; then
  codesign --force --timestamp --options runtime \
    --preserve-metadata=entitlements \
    --sign "$SIGNING_IDENTITY" \
    "$SPARKLE_CONTENTS/XPCServices/Downloader.xpc"
fi
sign_component "$SPARKLE_CONTENTS/Autoupdate"
sign_component "$SPARKLE_CONTENTS/Updater.app"
sign_component "$SPARKLE_FRAMEWORK"

codesign --force --timestamp --options runtime \
  --entitlements meetingnotes/meetingnotes.entitlements \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" 2>&1 | grep -q 'com.apple.security.app-sandbox'

ARCHIVE_NAME="$APP_NAME-$VERSION.zip"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

NOTARY_RESULT="$BUILD_ROOT/notary-result.json"
xcrun notarytool submit "$ARCHIVE_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait \
  --timeout 20m \
  --output-format json > "$NOTARY_RESULT"

NOTARY_STATUS=$(plutil -extract status raw -o - "$NOTARY_RESULT")
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  submission_id=$(plutil -extract id raw -o - "$NOTARY_RESULT")
  xcrun notarytool log "$submission_id" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" || true
  echo "Apple notarization failed with status: $NOTARY_STATUS" >&2
  exit 1
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

GENERATE_APPCAST=$(find "$DERIVED_DATA/SourcePackages/artifacts" -type f -name generate_appcast -print -quit)
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast tool was not found" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" "$RELEASE_DIR" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL" \
  --maximum-deltas 0 \
  -o "$RELEASE_DIR/appcast.xml"

grep -q "$DOWNLOAD_URL$ARCHIVE_NAME" "$RELEASE_DIR/appcast.xml"
grep -q 'sparkle:edSignature=' "$RELEASE_DIR/appcast.xml"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Built, Developer ID-signed, notarized, and stapled Meetingnotes %s. The GitHub release is ready to publish.\n' \
    "$VERSION" >> "$GITHUB_STEP_SUMMARY"
fi

echo "Signed and notarized release artifacts are ready in $RELEASE_DIR"
