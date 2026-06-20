#!/usr/bin/env bash
# Package, create/update Lambda, set env vars, wire SQS triggers, remove legacy SNS trigger
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env
resolve_projects_config

LAMBDA_SRC="${ROOT_DIR}/lambda/ses-bounce-slack-notifier"
ZIP_FILE="${LAMBDA_SRC}/function.zip"

# Resolve Lambda role ARN
if [[ -z "${LAMBDA_ROLE_ARN:-}" ]]; then
  LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
fi

echo "Packaging Lambda from ${LAMBDA_SRC}..."
(cd "${LAMBDA_SRC}" && zip -q function.zip index.mjs)

WEBHOOK_MAP="$(resolve_webhook_map)"
MAP_KEY_COUNT="$(echo "${WEBHOOK_MAP}" | jq 'keys | length')"
echo "WEBHOOK_MAP keys: $(echo "${WEBHOOK_MAP}" | jq -r 'keys | join(", ")')"

if [[ -z "${SLACK_WEBHOOK_URL:-}" && "${MAP_KEY_COUNT}" -eq 0 ]]; then
  echo "ERROR: No Slack webhook configured." >&2
  echo "  Set GitHub Secret SLACK_WEBHOOK_URL and/or WEBHOOK_MAP" >&2
  echo "  Or include webhookUrl in PROJECTS_CONFIG projects[]" >&2
  exit 1
fi

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "SLACK_WEBHOOK_URL: set"
else
  echo "SLACK_WEBHOOK_URL: not set (using WEBHOOK_MAP per queue only)"
fi

if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Updating Lambda code: ${FUNCTION_NAME}"
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --region "${AWS_REGION}" >/dev/null
else
  echo "Creating Lambda function: ${FUNCTION_NAME}"
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --runtime "${LAMBDA_RUNTIME}" \
    --handler "${LAMBDA_HANDLER}" \
    --memory-size "${LAMBDA_MEMORY}" \
    --timeout "${LAMBDA_TIMEOUT}" \
    --role "${LAMBDA_ROLE_ARN}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --region "${AWS_REGION}" \
    --tags "ManagedBy=ses-bounce-slack-notifier" >/dev/null
fi

wait_for_lambda "Code update"

echo "Updating Lambda environment variables..."
ENV_VARS="$(jq -n \
  --arg slackUrl "${SLACK_WEBHOOK_URL:-}" \
  --arg slackChannel "${SLACK_CHANNEL:-}" \
  --arg webhookMap "${WEBHOOK_MAP}" \
  --arg logLevel "${LOG_LEVEL}" \
  '{
    Variables: {
      SLACK_WEBHOOK_URL: $slackUrl,
      SLACK_CHANNEL: $slackChannel,
      WEBHOOK_MAP: $webhookMap,
      LOG_LEVEL: $logLevel
    }
  }')"

ENV_FILE="$(mktemp)"
echo "${ENV_VARS}" > "${ENV_FILE}"
aws lambda update-function-configuration \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --environment "file://${ENV_FILE}" >/dev/null
rm -f "${ENV_FILE}"

wait_for_lambda "Configuration update"

FUNCTION_ARN="$(aws lambda get-function \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionArn' \
  --output text)"

# Remove legacy SNS → Lambda direct trigger (old architecture)
echo "Removing legacy SNS → Lambda direct subscription (if any)..."
LEGACY_SUBS="$(aws sns list-subscriptions-by-topic \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}" \
  --query "Subscriptions[?Protocol=='lambda' && Endpoint=='${FUNCTION_ARN}'].SubscriptionArn" \
  --output text || true)"

for sub in ${LEGACY_SUBS}; do
  if [[ -n "${sub}" && "${sub}" != "None" ]]; then
    echo "Unsubscribing legacy Lambda subscription: ${sub}"
    aws sns unsubscribe --subscription-arn "${sub}" --region "${AWS_REGION}"
  fi
done

aws lambda remove-permission \
  --function-name "${FUNCTION_NAME}" \
  --statement-id sns-invoke \
  --region "${AWS_REGION}" 2>/dev/null || true

# Ensure SQS event source mappings for each project queue
QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
echo "Ensuring ${QUEUE_COUNT} SQS trigger(s)..."

EXISTING_MAPPINGS="$(aws lambda list-event-source-mappings \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'EventSourceMappings[*].EventSourceArn' \
  --output text)"

for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  if echo "${EXISTING_MAPPINGS}" | grep -q "${QUEUE_ARN}"; then
    echo "SQS trigger exists: ${QUEUE_NAME}"
    continue
  fi

  echo "Creating SQS trigger: ${QUEUE_NAME}"
  aws lambda create-event-source-mapping \
    --function-name "${FUNCTION_NAME}" \
    --event-source-arn "${QUEUE_ARN}" \
    --batch-size 10 \
    --enabled \
    --region "${AWS_REGION}" >/dev/null
done

echo "Lambda deployment complete: ${FUNCTION_ARN}"
