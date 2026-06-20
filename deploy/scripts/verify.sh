#!/usr/bin/env bash
# Verify all infrastructure components are in place after deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env
resolve_projects_config

# Running total of failed checks — used to decide the script's exit code.
FAILURES=0

# Helper that prints a ✅/❌ line for a single check and increments
# FAILURES when the check did not pass ("ok").
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
# Confirm the Lambda function exists and is healthy: State should be
# "Active" and the last code/config update should have finished
# ("LastUpdateStatus=Successful"). Also surface the runtime and timeout
# for a quick sanity check.
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
# Use get-function (lambda:GetFunction) instead of GetFunctionConfiguration —
# the deploy user's IAM policy often only grants the former. Check that
# WEBHOOK_MAP has at least one queue mapped, and that either a per-queue
# webhook or the global SLACK_WEBHOOK_URL fallback is configured.
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
      check "WEBHOOK_MAP configured (${MAP_KEYS} queue(s))" "empty map — add webhookUrl in PROJECTS_CONFIG"
    fi
  else
    check "WEBHOOK_MAP configured" "missing or empty"
  fi

  # SLACK_WEBHOOK_URL is only a fallback — it's fine to be unset as long as
  # WEBHOOK_MAP already covers at least one queue.
  if [[ -n "${SLACK_URL_SET}" ]]; then
    check "SLACK_WEBHOOK_URL (fallback) set" "ok"
  elif [[ "${MAP_KEYS:-0}" -gt 0 ]]; then
    check "SLACK_WEBHOOK_URL (fallback) not set" "ok"
    echo "   optional — WEBHOOK_MAP has ${MAP_KEYS} queue(s)"
  else
    check "SLACK_WEBHOOK_URL (fallback) set" "missing — set webhookUrl in PROJECTS_CONFIG or SLACK_WEBHOOK_URL"
  fi
fi

# 3. SNS topic
# Confirm the SNS topic exists and is reachable with current credentials.
if aws sns list-subscriptions-by-topic --topic-arn "${SNS_TOPIC_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  check "SNS topic ${SNS_TOPIC_NAME}" "ok"
else
  check "SNS topic ${SNS_TOPIC_NAME}" "not found or access denied"
fi

# 4. Per-project: SQS queue, SNS subscription, Lambda trigger
# For every project in the config, verify the full chain end-to-end:
#   SQS queue exists → SNS subscription exists with FilterPolicyScope=MessageBody
#   → Lambda has an enabled SQS trigger pointing at that queue.
QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"

# Pre-fetch the Lambda's enabled event source mappings and the topic's
# subscriptions once, outside the loop, to avoid redundant API calls per project.
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

  # 4a. Does the SQS queue exist at all? If not, skip the remaining checks
  # for this project since they all depend on the queue's ARN.
  if aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    check "  SQS queue ${QUEUE_NAME}" "ok"
  else
    check "  SQS queue ${QUEUE_NAME}" "not found"
    continue
  fi

  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  # 4b. Is there an SNS subscription pointing at this queue, and is its
  # FilterPolicyScope correctly set to MessageBody (required for the
  # filter policy to match against the SES notification JSON)?
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

  # 4c. Does the Lambda have an enabled SQS trigger (event source mapping)
  # wired to this specific queue's ARN?
  if echo "${MAPPING_ARNS}" | grep -q "${QUEUE_ARN}"; then
    check "  Lambda SQS trigger enabled" "ok"
  else
    check "  Lambda SQS trigger enabled" "missing"
  fi
done

# 5. No legacy SNS→Lambda subscription
# The architecture used to subscribe the Lambda directly to the SNS topic.
# That direct subscription has since been replaced by SNS → SQS → Lambda,
# so confirm no leftover direct subscription still exists (which would
# cause duplicate Slack notifications).
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
# Final result: exit 0 only if every check above passed; otherwise exit 1
# so CI (GitHub Actions) reports the deploy as failed/needing attention.
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "=== All checks passed ==="
  exit 0
else
  echo "=== ${FAILURES} check(s) failed ==="
  exit 1
fi