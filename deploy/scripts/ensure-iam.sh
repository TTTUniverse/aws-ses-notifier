#!/usr/bin/env bash
# Ensure Lambda execution IAM role exists with SQS + CloudWatch permissions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env

# If the caller already provided an existing role ARN (e.g. via the
# LAMBDA_ROLE_ARN secret/env var), skip role creation entirely and just
# reuse that role. This supports environments where the deploy user isn't
# allowed to create IAM roles.
if [[ -n "${LAMBDA_ROLE_ARN:-}" ]]; then
  echo "Using existing Lambda role: ${LAMBDA_ROLE_ARN}"
  echo "LAMBDA_ROLE_ARN=${LAMBDA_ROLE_ARN}"
  exit 0
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

# Create the role only if it doesn't already exist, so re-running this
# script is safe (idempotent).
if aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Lambda role already exists: ${ROLE_ARN}"
else
  echo "Creating Lambda execution role: ${LAMBDA_ROLE_NAME}"
  # Create the role using the trust policy that allows the Lambda service
  # to assume it (deploy/iam/lambda-trust-policy.json).
  if ! aws iam create-role \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document "file://${DEPLOY_DIR}/iam/lambda-trust-policy.json" \
    --description "Execution role for ${FUNCTION_NAME} (SQS trigger + CloudWatch Logs)"; then
    echo "ERROR: Failed to create IAM role '${LAMBDA_ROLE_NAME}'." >&2
    echo "  - Ensure deploy user has iam:CreateRole (see deploy/iam/github-actions-deploy-policy.json)" >&2
    echo "  - Or set LAMBDA_ROLE_ARN to an existing role and rerun." >&2
    exit 1
  fi

  # New IAM roles can take a few seconds to become available for use
  # (e.g. when passed to lambda:CreateFunction) — wait before continuing.
  echo "Waiting for role to propagate..."
  sleep 10
fi

# Attach (or refresh) the inline execution policy granting CloudWatch Logs
# and SQS permissions, so the Lambda can read its queues and write logs.
POLICY_NAME="${LAMBDA_ROLE_NAME}-execution"
aws iam put-role-policy \
  --role-name "${LAMBDA_ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${DEPLOY_DIR}/iam/lambda-execution-policy.json"

echo "Lambda role ready: ${ROLE_ARN}"
echo "LAMBDA_ROLE_ARN=${ROLE_ARN}"