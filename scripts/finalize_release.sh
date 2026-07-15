#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Meetingnotes"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
PENDING_DIR="${PENDING_DIR:-$RUNNER_TEMP/meetingnotes-pending}"
WORK_ROOT="${WORK_ROOT:-$RUNNER_TEMP/meetingnotes-finalize}"
APP_PATH="$WORK_ROOT/$APP_NAME.app"
RELEASE_DIR="$WORK_ROOT/release"
VERSION_PATH="$PENDING_DIR/version"
COMMIT_SHA_PATH="$PENDING_DIR/commit-sha"
SUBMISSION_PATH="$PENDING_DIR/notary-submission.json"
PRE_NOTARY_ZIP="$PENDING_DIR/$APP_NAME-pre-notary.zip"

required_variables=(
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_PASSWORD
  SPARKLE_PRIVATE_KEY
  GH_TOKEN
  GITHUB_REPOSITORY
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required environment variable: $variable" >&2
    exit 1
  fi
done

for path in "$VERSION_PATH" "$COMMIT_SHA_PATH" "$SUBMISSION_PATH" "$PRE_NOTARY_ZIP" "$PENDING_DIR/generate_appcast"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing release submission artifact: $path" >&2
    exit 1
  fi
done

VERSION=$(<"$VERSION_PATH")
COMMIT_SHA=$(<"$COMMIT_SHA_PATH")
SUBMISSION_ID=$(plutil -extract id raw -o - "$SUBMISSION_PATH")
TAG="v$VERSION"

if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Release already exists: $TAG"
  exit 0
fi

STATUS_PATH="$WORK_ROOT/notary-status.json"
rm -rf "$WORK_ROOT"
mkdir -p "$RELEASE_DIR"

notary_info_succeeded=false
for attempt in 1 2 3; do
  if xcrun notarytool info "$SUBMISSION_ID" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --output-format json > "$STATUS_PATH"; then
    notary_info_succeeded=true
    break
  fi
  echo "Notary status check failed ($attempt/3); retrying"
  sleep 15
done

if [[ "$notary_info_succeeded" != true ]]; then
  echo "Unable to query Apple notarization status after three attempts" >&2
  exit 1
fi

NOTARY_STATUS=$(plutil -extract status raw -o - "$STATUS_PATH")
echo "Notarization status for $SUBMISSION_ID: $NOTARY_STATUS"

case "$NOTARY_STATUS" in
  "In Progress")
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      printf 'Apple is still processing Meetingnotes %s. Submission: `%s`. The scheduled workflow will check again.\n' \
        "$VERSION" "$SUBMISSION_ID" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
    ;;
  Accepted)
    ;;
  Invalid|Rejected)
    xcrun notarytool log "$SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" || true
    exit 1
    ;;
  *)
    echo "Unexpected notarization status: $NOTARY_STATUS" >&2
    exit 1
    ;;
esac

ditto -x -k "$PRE_NOTARY_ZIP" "$WORK_ROOT"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Signed app was not found after extracting $PRE_NOTARY_ZIP" >&2
  exit 1
fi

APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")
if [[ "$APP_VERSION" != "$VERSION" ]]; then
  echo "Signed app version $APP_VERSION does not match release version $VERSION" >&2
  exit 1
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

ARCHIVE_NAME="$APP_NAME-$VERSION.zip"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

GENERATE_APPCAST="$PENDING_DIR/generate_appcast"
chmod +x "$GENERATE_APPCAST"
DOWNLOAD_URL="https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" "$RELEASE_DIR" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL" \
  --maximum-deltas 0 \
  -o "$RELEASE_DIR/appcast.xml"

grep -q "$DOWNLOAD_URL$ARCHIVE_NAME" "$RELEASE_DIR/appcast.xml"
grep -q 'sparkle:edSignature=' "$RELEASE_DIR/appcast.xml"

gh release \
  create "$TAG" \
  "$ARCHIVE_PATH" \
  "$RELEASE_DIR/appcast.xml" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$COMMIT_SHA" \
  --title "Meetingnotes $VERSION" \
  --generate-notes

echo "Published Meetingnotes $VERSION"
