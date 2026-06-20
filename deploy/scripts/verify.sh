#!/usr/bin/env bash
# Verify all infrastructure components are in place after deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env
resolve_projects_config

FAILURES=0

check() {
  local name="$1"
  local result="$2"
  if [[ "${result}" == "ok" ]]; then
    echo "✅ ${name}"
  else
    echo "❌ ${name}: ${result}"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== Deployment Verification ==="
echo "Region: ${AWS_REGION} | Function: ${FUNCTION_NAME} | Topic: ${SNS_TOPIC_NAME}"
echo ""

# 1. Lambda function state
LAMBDA_STATE="$(aws lambda get-function \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.[State,LastUpdateStatus,Runtime,Timeout]' \
  --output text 2>/dev/null || echo "NOT_FOUND")"

if [[ "${LAMBDA_STATE}" == "NOT_FOUND" ]]; then
  check "Lambda function exists" "function not found"
else
  STATE="$(echo "${LAMBDA_STATE}" | awk '{print $1}')"
  UPDATE_STATUS="$(echo "${LAMBDA_STATE}" | awk '{print $2}')"
  RUNTIME="$(echo "${LAMBDA_STATE}" | awk '{print $3}')"
  TIMEOUT="$(echo "${LAMBDA_STATE}" | awk '{print $4}')"

  if [[ "${STATE}" == "Active" && "${UPDATE_STATUS}" == "Successful" ]]; then
    check "Lambda Active + LastUpdateStatus=Successful" "ok"
  else
    check "Lambda Active + LastUpdateStatus=Successful" "State=${STATE}, LastUpdateStatus=${UPDATE_STATUS}"
  fi
  echo "   Runtime: ${RUNTIME}, Timeout: ${TIMEOUT}s"
fi

# 2. Lambda env vars
# ใช้ get-function (lambda:GetFunction) — deploy user มักไม่มี GetFunctionConfiguration
LAMBDA_ENV="$(aws lambda get-function \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.Environment.Variables' \
  --output json 2>/dev/null || echo 'null')"

if [[ "${LAMBDA_ENV}" == "null" || "${LAMBDA_ENV}" == "{}" ]]; then
  check "Lambda environment readable" "cannot read env — add lambda:GetFunction to deploy IAM policy"
else
  ENV_WEBHOOK_MAP="$(echo "${LAMBDA_ENV}" | jq -r '.WEBHOOK_MAP // empty')"
  SLACK_URL_SET="$(echo "${LAMBDA_ENV}" | jq -r '.SLACK_WEBHOOK_URL // empty')"

  if [[ -n "${ENV_WEBHOOK_MAP}" ]]; then
    MAP_KEYS="$(echo "${ENV_WEBHOOK_MAP}" | jq 'keys | length' 2>/dev/null || echo 0)"
    if [[ "${MAP_KEYS}" -gt 0 ]]; then
      check "WEBHOOK_MAP configured (${MAP_KEYS} queue(s))" "ok"
    else
      check "WEBHOOK_MAP configured (${MAP_KEYS} queue(s))" "empty map — set WEBHOOK_MAP secret or webhookUrl in PROJECTS_CONFIG"
    fi
  else
    check "WEBHOOK_MAP configured" "missing or empty"
  fi

  if [[ -n "${SLACK_URL_SET}" ]]; then
    check "SLACK_WEBHOOK_URL (fallback) set" "ok"
  else
    if [[ "${MAP_KEYS:-0}" -gt 0 ]]; then
      check "SLACK_WEBHOOK_URL (fallback) set" "ok (optional — WEBHOOK_MAP has entries)"
    else
      check "SLACK_WEBHOOK_URL (fallback) set" "missing — Lambda will fail without queue mapping"
    fi
  fi
fi

# 3. SNS topic
if aws sns list-subscriptions-by-topic --topic-arn "${SNS_TOPIC_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  check "SNS topic ${SNS_TOPIC_NAME}" "ok"
else
  check "SNS topic ${SNS_TOPIC_NAME}" "not found or access denied"
fi

# 4. Per-project: SQS queue, SNS subscription, Lambda trigger
QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
MAPPING_ARNS="$(aws lambda list-event-source-mappings \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'EventSourceMappings[?State==`Enabled`].EventSourceArn' \
  --output text 2>/dev/null || echo "")"

SUBSCRIPTIONS="$(aws sns list-subscriptions-by-topic \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}" \
  --output json 2>/dev/null || echo '{"Subscriptions":[]}')"

echo ""
echo "--- Per-project checks (${QUEUE_COUNT} project(s)) ---"

for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  PROJECT_LABEL="$(jq -r ".projects[${i}].projectLabel" "${PROJECTS_CONFIG}")"
  echo ""
  echo "Project: ${PROJECT_LABEL} (${QUEUE_NAME})"

  if aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    check "  SQS queue ${QUEUE_NAME}" "ok"
  else
    check "  SQS queue ${QUEUE_NAME}" "not found"
    continue
  fi

  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  SUB_ARN="$(echo "${SUBSCRIPTIONS}" | jq -r \
    --arg arn "${QUEUE_ARN}" \
    '.Subscriptions[] | select(.Protocol=="sqs" and .Endpoint==$arn) | .SubscriptionArn' | head -1)"

  if [[ -n "${SUB_ARN}" && "${SUB_ARN}" != "PendingConfirmation" ]]; then
    FILTER_SCOPE="$(aws sns get-subscription-attributes \
      --subscription-arn "${SUB_ARN}" \
      --region "${AWS_REGION}" \
      --query 'Attributes.FilterPolicyScope' \
      --output text 2>/dev/null || echo "")"
    if [[ "${FILTER_SCOPE}" == "MessageBody" ]]; then
      check "  SNS subscription + FilterPolicyScope=MessageBody" "ok"
    else
      check "  SNS subscription + FilterPolicyScope=MessageBody" "scope=${FILTER_SCOPE}"
    fi
  else
    check "  SNS subscription" "not found or pending"
  fi

  if echo "${MAPPING_ARNS}" | grep -q "${QUEUE_ARN}"; then
    check "  Lambda SQS trigger enabled" "ok"
  else
    check "  Lambda SQS trigger enabled" "missing"
  fi
done

# 5. No legacy SNS→Lambda subscription
FUNCTION_ARN="$(aws lambda get-function \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionArn' \
  --output text 2>/dev/null || echo "")"

LEGACY_COUNT=0
if [[ -n "${FUNCTION_ARN}" ]]; then
  LEGACY_COUNT="$(echo "${SUBSCRIPTIONS}" | jq -r \
    --arg arn "${FUNCTION_ARN}" \
    '[.Subscriptions[] | select(.Protocol=="lambda" and .Endpoint==$arn)] | length')"
fi

if [[ "${LEGACY_COUNT}" -eq 0 ]]; then
  check "No legacy SNS→Lambda direct subscription" "ok"
else
  check "No legacy SNS→Lambda direct subscription" "${LEGACY_COUNT} subscription(s) still exist"
fi

echo ""
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "=== All checks passed ==="
  exit 0
else
  echo "=== ${FAILURES} check(s) failed ==="
  exit 1
fi
