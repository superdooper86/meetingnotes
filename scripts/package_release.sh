#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Meetingnotes"
PROJECT="Meetingnotes.xcodeproj"
SCHEME="meetingnotes"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
BUILD_ROOT="${BUILD_ROOT:-$RUNNER_TEMP/meetingnotes-release}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
PENDING_DIR="$BUILD_ROOT/pending"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

required_variables=(
  VERSION
  SIGNING_IDENTITY
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_PASSWORD
  GITHUB_SHA
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
mkdir -p "$PENDING_DIR"

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

PRE_NOTARY_ZIP="$PENDING_DIR/$APP_NAME-pre-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"

xcrun notarytool submit "$PRE_NOTARY_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --output-format json > "$PENDING_DIR/notary-submission.json"

SUBMISSION_ID=$(plutil -extract id raw -o - "$PENDING_DIR/notary-submission.json")
echo "Notarization submitted: $SUBMISSION_ID"

GENERATE_APPCAST=$(find "$DERIVED_DATA/SourcePackages/artifacts" -type f -name generate_appcast -print -quit)
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast tool was not found" >&2
  exit 1
fi
cp "$GENERATE_APPCAST" "$PENDING_DIR/generate_appcast"

printf '%s' "$VERSION" > "$PENDING_DIR/version"
printf '%s' "$GITHUB_SHA" > "$PENDING_DIR/commit-sha"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Submitted Meetingnotes %s for Apple notarization.\n\nSubmission: `%s`\n\nThe finalize workflow will publish the release after Apple accepts it.\n' \
    "$VERSION" "$SUBMISSION_ID" >> "$GITHUB_STEP_SUMMARY"
fi

echo "Signed app and notarization metadata are ready in $PENDING_DIR"
