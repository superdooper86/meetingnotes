#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="${REPOSITORY:-superdooper86/meetingnotes}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Install GitHub CLI first: brew install gh" >&2
  exit 1
fi

gh auth status >/dev/null

read -r -p "Developer ID certificate (.p12) path: " certificate_path
if [[ ! -f "$certificate_path" ]]; then
  echo "Certificate not found: $certificate_path" >&2
  exit 1
fi

read -r -s -p "Certificate export password: " certificate_password
printf '\n'
read -r -p "Apple ID email: " apple_id
read -r -p "Apple Developer Team ID: " team_id
read -r -s -p "Apple app-specific password: " app_password
printf '\n'

base64 < "$certificate_path" | gh secret set APPLE_CERTIFICATE_P12 -R "$REPOSITORY"
printf '%s' "$certificate_password" | gh secret set APPLE_CERTIFICATE_PASSWORD -R "$REPOSITORY"
printf '%s' "$apple_id" | gh secret set APPLE_ID -R "$REPOSITORY"
printf '%s' "$team_id" | gh secret set APPLE_TEAM_ID -R "$REPOSITORY"
printf '%s' "$app_password" | gh secret set APPLE_APP_PASSWORD -R "$REPOSITORY"

unset certificate_password app_password
echo "Apple release secrets configured for $REPOSITORY."
