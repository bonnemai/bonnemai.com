#!/usr/bin/env bash
set -euo pipefail

# Apply ECR lifecycle policy to a repository
#
# Usage: ./scripts/apply-ecr-lifecycle-policy.sh <repository-name> [policy-file]
#
# Examples:
#   ./scripts/apply-ecr-lifecycle-policy.sh my-app
#   ./scripts/apply-ecr-lifecycle-policy.sh my-app ecr-lifecycle-policy-aggressive.json

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <repository-name> [policy-file]" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 my-app" >&2
  echo "  $0 my-app ecr-lifecycle-policy-aggressive.json" >&2
  exit 1
fi

REPO_NAME="$1"
POLICY_FILE="${2:-ecr-lifecycle-policy.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# If policy file is relative, look in repo root
if [[ ! -f "$POLICY_FILE" ]]; then
  POLICY_FILE="$REPO_ROOT/$POLICY_FILE"
fi

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "Error: Policy file not found: $POLICY_FILE" >&2
  exit 1
fi

echo "Applying lifecycle policy from $POLICY_FILE to repository: $REPO_NAME"

# Check if repository exists
if ! aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1; then
  echo "Error: Repository '$REPO_NAME' not found" >&2
  echo "" >&2
  echo "Available repositories:" >&2
  aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
  exit 1
fi

# Apply the lifecycle policy
aws ecr put-lifecycle-policy \
  --repository-name "$REPO_NAME" \
  --lifecycle-policy-text "file://$POLICY_FILE"

echo "✓ Lifecycle policy applied successfully to $REPO_NAME"
echo ""
echo "To view the policy:"
echo "  aws ecr get-lifecycle-policy --repository-name $REPO_NAME"
echo ""
echo "To preview what would be deleted (dry run):"
echo "  aws ecr get-lifecycle-policy-preview --repository-name $REPO_NAME"
