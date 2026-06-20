#!/usr/bin/env bash
# Ensure Lambda execution IAM role exists with SQS + CloudWatch permissions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env

if [[ -n "${LAMBDA_ROLE_ARN:-}" ]]; then
  echo "Using existing Lambda role: ${LAMBDA_ROLE_ARN}"
  echo "LAMBDA_ROLE_ARN=${LAMBDA_ROLE_ARN}"
  exit 0
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

if aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Lambda role already exists: ${ROLE_ARN}"
else
  echo "Creating Lambda execution role: ${LAMBDA_ROLE_NAME}"
  aws iam create-role \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document "file://${DEPLOY_DIR}/iam/lambda-trust-policy.json" \
    --description "Execution role for ${FUNCTION_NAME} (SQS trigger + CloudWatch Logs)"

  echo "Waiting for role to propagate..."
  sleep 10
fi

POLICY_NAME="${LAMBDA_ROLE_NAME}-execution"
aws iam put-role-policy \
  --role-name "${LAMBDA_ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${DEPLOY_DIR}/iam/lambda-execution-policy.json"

echo "Lambda role ready: ${ROLE_ARN}"
echo "LAMBDA_ROLE_ARN=${ROLE_ARN}"
