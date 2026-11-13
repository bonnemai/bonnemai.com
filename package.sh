#!/usr/bin/env bash
set -euo pipefail

# Build the static site archive used for AWS/Amplify uploads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_PATH="${1:-${AWS_PACKAGE_OUTPUT:-$SCRIPT_DIR/aws-deployment.zip}}"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-deployment.XXXXXX")"
TEMP_ARCHIVE="$TEMP_DIR/archive.zip"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if ! command -v zip >/dev/null 2>&1; then
  echo "Error: required command 'zip' is not installed." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

(
  cd "$SCRIPT_DIR"
  zip -qr "$TEMP_ARCHIVE" . \
    -x '.git/*' \
    -x '.github/*' \
    -x '.agents/*' \
    -x '.claude/*' \
    -x '.codex/*' \
    -x '.venv/*' \
    -x '.DS_Store' \
    -x '.gitignore' \
    -x 'README.md' \
    -x 'deploy.sh' \
    -x 'package.sh' \
    -x '*.zip' \
    -x 'scripts/*' \
    -x 'ecr-lifecycle-policy*.json'
)

mv "$TEMP_ARCHIVE" "$OUTPUT_PATH"
trap - EXIT

echo "Created $OUTPUT_PATH"
echo "Contents:"
unzip -l "$OUTPUT_PATH"
