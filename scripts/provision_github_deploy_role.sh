#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the IAM role used by GitHub Actions to sync the static site to S3.
#
# Required:
#   - AWS CLI configured with credentials that can manage IAM resources.
# Customise via environment variables before running:
#   ROLE_NAME         Name for the IAM role (default: github-deploy-static-site)
#   BUCKET_NAME       Target S3 bucket (default: bonnemai.com)
#   GITHUB_REPO       GitHub repo in owner/name form (auto-detected from git remote, fallback: olivierbonnemaison/web_site)
#   GITHUB_BRANCH     Branch that may assume the role (default: main)
#
# Example:
#   ROLE_NAME=web-site-deployer BUCKET_NAME=mybucket ./scripts/provision_github_deploy_role.sh

ROLE_NAME=${ROLE_NAME:-github-deploy-static-site}
BUCKET_NAME=${BUCKET_NAME:-bonnemai.com}

DEFAULT_REPO=""
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REMOTE_URL=$(git config --get remote.origin.url || true)
  if [[ -n "${REMOTE_URL:-}" ]]; then
    DEFAULT_REPO=$(REMOTE_URL="$REMOTE_URL" python3 - <<'PY'
import os

remote = os.environ.get("REMOTE_URL", "").strip()
path = ""
if remote.startswith("git@github.com:"):
    path = remote.split(":", 1)[1]
elif remote.startswith("https://github.com/"):
    path = remote.split("https://github.com/", 1)[1]

if path.endswith(".git"):
    path = path[:-4]

print(path, end="")
PY
)
  fi
fi

DEFAULT_REPO=${DEFAULT_REPO:-olivierbonnemaison/web_site}
GITHUB_REPO=${GITHUB_REPO:-$DEFAULT_REPO}
GITHUB_BRANCH=${GITHUB_BRANCH:-main}

cleanup() {
  [[ -n "${ASSUME_ROLE_DOC:-}" && -f "$ASSUME_ROLE_DOC" ]] && rm -f "$ASSUME_ROLE_DOC"
  [[ -n "${INLINE_POLICY_DOC:-}" && -f "$INLINE_POLICY_DOC" ]] && rm -f "$INLINE_POLICY_DOC"
}
trap cleanup EXIT

echo "Using GitHub repo: $GITHUB_REPO (branch: $GITHUB_BRANCH)"
echo "Determining AWS account..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

existing_oidc=$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions.githubusercontent.com`)].Arn' \
  --output text)

if [[ "$existing_oidc" == "None" || -z "$existing_oidc" ]]; then
  echo "Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "Created OIDC provider: $OIDC_PROVIDER_ARN"
else
  echo "Using existing OIDC provider: $existing_oidc"
fi

ASSUME_ROLE_DOC=$(mktemp)
cat >"$ASSUME_ROLE_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:ref:refs/heads/${GITHUB_BRANCH}"
        }
      }
    }
  ]
}
EOF

DESCRIPTION="Role assumed by GitHub Actions to deploy ${GITHUB_REPO}@${GITHUB_BRANCH} to s3://${BUCKET_NAME}"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Updating trust policy for role $ROLE_NAME..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$ASSUME_ROLE_DOC"
else
  echo "Creating role $ROLE_NAME..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$ASSUME_ROLE_DOC" \
    --description "$DESCRIPTION" >/dev/null
fi

INLINE_POLICY_DOC=$(mktemp)
cat >"$INLINE_POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "AllowObjectReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF

echo "Attaching inline policy DeployStaticSite to $ROLE_NAME..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name DeployStaticSite \
  --policy-document "file://$INLINE_POLICY_DOC"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

cat <<EOM

Role ready: $ROLE_ARN

Add this value to your GitHub repository secret AWS_DEPLOY_ROLE_ARN and rerun the workflow.

If you need to allow additional branches or actions, re-run this script with updated GITHUB_BRANCH or edit the trust policy manually.
EOM
