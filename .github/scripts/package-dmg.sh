#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package-dmg.sh --app <path> --notices <path> --output <path> --identity <identity> --version <version>

Packages a signed macOS app, third-party notices, and an Applications shortcut
into a read-only DMG, then signs and verifies the disk image.
EOF
}

app_path=""
notices_path=""
output_path=""
signing_identity=""
version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --notices)
      notices_path="$2"
      shift 2
      ;;
    --output)
      output_path="$2"
      shift 2
      ;;
    --identity)
      signing_identity="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$app_path" || -z "$notices_path" || -z "$output_path" || -z "$signing_identity" || -z "$version" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$app_path" || "${app_path##*.}" != "app" ]]; then
  echo "Expected an app bundle at: $app_path" >&2
  exit 2
fi

if [[ ! -f "$notices_path" ]]; then
  echo "Expected third-party notices at: $notices_path" >&2
  exit 2
fi

app_name="$(basename "$app_path")"
volume_name="Quorra ${version}"
staging_directory="$(mktemp -d)"

cleanup() {
  rm -rf "$staging_directory"
}
trap cleanup EXIT

mkdir -p "$(dirname "$output_path")"
rm -f "$output_path"

# ditto preserves the bundle's metadata and any symlinks when staging the app.
ditto "$app_path" "$staging_directory/$app_name"
ditto "$notices_path" "$staging_directory/THIRD_PARTY_NOTICES.md"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$output_path"

codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp \
  --identifier dev.ajbeck.quorra.dmg \
  "$output_path"

codesign --verify --verbose=4 "$output_path"
