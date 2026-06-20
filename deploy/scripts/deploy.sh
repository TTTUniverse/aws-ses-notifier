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

# Step 1: Ensure the Lambda execution IAM role exists (or reuse an existing
# one if LAMBDA_ROLE_ARN was provided).
bash "${SCRIPT_DIR}/ensure-iam.sh"
echo ""

# If ensure-iam.sh didn't already export LAMBDA_ROLE_ARN (e.g. because the
# role was just created in a separate subshell), default it here so later
# steps that need to pass the role to Lambda have a value to use.
if [[ -z "${LAMBDA_ROLE_ARN:-}" ]]; then
  export LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
fi

# Step 2: Create/update the per-project SQS queues and their access policies.
bash "${SCRIPT_DIR}/ensure-sqs.sh"
echo ""

# Step 3: Wire up SNS → SQS subscriptions with each project's filter policy,
# so SES notifications get routed to the correct queue.
bash "${SCRIPT_DIR}/ensure-sns-subscriptions.sh"
echo ""

# Step 4: Package and deploy the Lambda function itself, configure its
# environment variables, and attach the SQS triggers.
bash "${SCRIPT_DIR}/ensure-lambda.sh"
echo ""

# Step 5: Run a final verification pass to confirm every piece of
# infrastructure (Lambda, SNS, SQS, triggers) is correctly in place.
bash "${SCRIPT_DIR}/verify.sh"