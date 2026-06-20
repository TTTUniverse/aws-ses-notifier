#!/usr/bin/env bash
# Full deploy orchestrator: IAM → SQS → SNS subscriptions → Lambda → verify
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env

echo "========================================"
echo " SES Bounce Slack Notifier — Full Deploy"
echo "========================================"
echo ""

bash "${SCRIPT_DIR}/ensure-iam.sh"
echo ""

if [[ -z "${LAMBDA_ROLE_ARN:-}" ]]; then
  export LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
fi

bash "${SCRIPT_DIR}/ensure-sqs.sh"
echo ""

bash "${SCRIPT_DIR}/ensure-sns-subscriptions.sh"
echo ""

bash "${SCRIPT_DIR}/ensure-lambda.sh"
echo ""

bash "${SCRIPT_DIR}/verify.sh"
