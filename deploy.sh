#!/usr/bin/env bash
set -euo pipefail

# Deploy static site to S3 and trigger an Amplify deployment for manual apps.

usage() {
  cat <<'USAGE'
Usage: deploy.sh [path]

Uploads the static site to the configured S3 bucket and triggers an AWS Amplify
start-deployment workflow. Pass an optional path to override the directory that
gets synced (defaults to the repository root).

Environment variables:
  S3_BUCKET               Target bucket name (default: bonnemai.com)
  AWS_AMPLIFY_APP_ID      Amplify app id (default: d3iwsh8gt9f3of)
  AWS_AMPLIFY_BRANCH      Amplify branch to deploy (default: main)
  SKIP_AMPLIFY            If set to 1, skip the Amplify deployment step
  DRY_RUN                 If set to 1, only print the aws/curl commands
USAGE
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      SYNC_SOURCE="$1"
      ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SOURCE="${SYNC_SOURCE:-$SCRIPT_DIR}"
S3_BUCKET="${S3_BUCKET:-bonnemai.com}"
APP_ID="${AWS_AMPLIFY_APP_ID:-d3iwsh8gt9f3of}"
BRANCH="${AWS_AMPLIFY_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_AMPLIFY="${SKIP_AMPLIFY:-0}"

ensure_amplify_branch() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] ensure Amplify branch '$BRANCH' exists"
    return
  fi

  if aws amplify get-branch --app-id "$APP_ID" --branch-name "$BRANCH" >/dev/null 2>&1; then
    return
  fi

  echo "Amplify branch '$BRANCH' not found; creating it..."
  if ! aws amplify create-branch --app-id "$APP_ID" --branch-name "$BRANCH" >/dev/null; then
    echo "Failed to create Amplify branch '$BRANCH'. Set AWS_AMPLIFY_BRANCH or create the branch in the Amplify console." >&2
    exit 1
  fi
}

if [[ "$DRY_RUN" != "1" ]]; then
  REQUIRED_CMDS=(aws)
  if [[ "$SKIP_AMPLIFY" != "1" ]]; then
    REQUIRED_CMDS+=(curl python3)
  fi
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: required command '$cmd' is not installed." >&2
      exit 1
    fi
  done
fi

if [[ "$DRY_RUN" != "1" ]]; then
  echo "Validating AWS credentials..."
  aws sts get-caller-identity >/dev/null
fi

AWS_SYNC_FLAGS=(
  "s3" "sync" "$SYNC_SOURCE" "s3://$S3_BUCKET" "--delete"
  "--exclude" ".git/*"
  "--exclude" ".github/*"
  "--exclude" "deploy.sh"
  "--exclude" "README.md"
  "--exclude" ".DS_Store"
)

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] aws ${AWS_SYNC_FLAGS[*]}"
else
  echo "Syncing $SYNC_SOURCE -> s3://$S3_BUCKET"
  aws "${AWS_SYNC_FLAGS[@]}"
fi

if [[ "$SKIP_AMPLIFY" == "1" ]]; then
  echo "Skipping Amplify deployment (SKIP_AMPLIFY=1)."
  exit 0
fi

ensure_amplify_branch

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] aws amplify create-deployment --app-id $APP_ID --branch-name $BRANCH"
  echo "[dry-run] PUT site-archive.zip -> <zipUploadUrl>"
  echo "[dry-run] aws amplify start-deployment --app-id $APP_ID --branch-name $BRANCH --job-id <jobId>"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCHIVE="$TMP_DIR/amplify-upload.zip"
EXCLUDES=(".git/*" ".github/*" "deploy.sh" "README.md" ".DS_Store")

python3 - "$SYNC_SOURCE" "$ARCHIVE" "${EXCLUDES[@]}" <<'PY'
import fnmatch
import sys
from pathlib import Path
import zipfile

root = Path(sys.argv[1]).resolve()
archive = Path(sys.argv[2])
patterns = sys.argv[3:]

with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
    for path in root.rglob("*"):
        rel = path.relative_to(root)
        rel_str = rel.as_posix()
        if any(fnmatch.fnmatch(rel_str, pattern) for pattern in patterns):
            continue
        if path.is_dir():
            continue
        zf.write(path, rel_str)
PY

echo "Requesting Amplify deployment slot..."
DEPLOYMENT_JSON="$(aws amplify create-deployment --app-id "$APP_ID" --branch-name "$BRANCH")"

UPLOAD_URL="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["zipUploadUrl"])' <<<"$DEPLOYMENT_JSON")"
JOB_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["jobId"])' <<<"$DEPLOYMENT_JSON")"

if [[ -z "$UPLOAD_URL" || -z "$JOB_ID" ]]; then
  echo "Failed to obtain upload URL or job ID from Amplify response:" >&2
  echo "$DEPLOYMENT_JSON" >&2
  exit 1
fi

echo "Uploading archive to Amplify..."
curl --fail --silent --show-error --request PUT --upload-file "$ARCHIVE" --header "Content-Type: application/zip" "$UPLOAD_URL"

echo "Starting Amplify deployment (job: $JOB_ID)..."
START_RESPONSE="$(aws amplify start-deployment --app-id "$APP_ID" --branch-name "$BRANCH" --job-id "$JOB_ID")"
echo "$START_RESPONSE"

STATUS="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["jobSummary"].get("status", ""))' <<<"$START_RESPONSE" 2>/dev/null || true)"
if [[ -n "$STATUS" ]]; then
  echo "Amplify deployment status: $STATUS"
fi

printf '\nDeployment complete.\n'
