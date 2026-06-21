#!/usr/bin/env bash
# Shared helpers for deploy scripts
set -euo pipefail

# common.sh lives at deploy/scripts/lib/ — repo root is three levels up
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"

load_env() {
  if [[ -f "${DEPLOY_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${DEPLOY_DIR}/.env"
    set +a
    echo "Loaded ${DEPLOY_DIR}/.env"
  fi

  : "${AWS_REGION:?AWS_REGION is required}"
  : "${FUNCTION_NAME:=ses-bounce-slack-notifier}"
  : "${LAMBDA_RUNTIME:=nodejs22.x}"
  : "${LAMBDA_HANDLER:=index.handler}"
  : "${LAMBDA_MEMORY:=128}"
  : "${LAMBDA_TIMEOUT:=30}"
  : "${LAMBDA_ROLE_NAME:=ses-bounce-slack-notifier-role}"
  : "${SNS_TOPIC_NAME:=ses-reputation-alerts}"
  : "${LOG_LEVEL:=info}"
  : "${PROJECTS_CONFIG:=${DEPLOY_DIR}/config/projects.json}"

  if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  fi

  SNS_TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${SNS_TOPIC_NAME}"
}

resolve_projects_config() {
  if [[ -n "${PROJECTS_CONFIG_JSON:-}" ]]; then
    echo "${PROJECTS_CONFIG_JSON}" > /tmp/projects-config.json
    PROJECTS_CONFIG=/tmp/projects-config.json
    echo "Using PROJECTS_CONFIG_JSON from environment"
  elif [[ ! -f "${PROJECTS_CONFIG}" ]]; then
    if [[ -f "${DEPLOY_DIR}/config/projects.example.json" ]]; then
      PROJECTS_CONFIG="${DEPLOY_DIR}/config/projects.example.json"
      echo "WARNING: ${PROJECTS_CONFIG} not found — using example config"
    else
      echo "ERROR: projects config not found at ${PROJECTS_CONFIG}" >&2
      exit 1
    fi
  fi

  if ! jq empty "${PROJECTS_CONFIG}" 2>/dev/null; then
    echo "ERROR: invalid JSON in ${PROJECTS_CONFIG}" >&2
    exit 1
  fi
}

build_webhook_map() {
  jq -c '
    [.projects[] | {(.queueName): {webhookUrl, channel, projectLabel}}]
    | add // {}
  ' "${PROJECTS_CONFIG}"
}

validate_webhook_map_json() {
  local map_json="$1"
  local invalid
  invalid="$(echo "${map_json}" | jq -r '
    to_entries[]
    | select(.value.webhookUrl == null or (.value.webhookUrl | length) < 60
        or (.value.webhookUrl | test("\\.\\.\\.|/XXX/")))
    | .key
  ' 2>/dev/null || echo "invalid-json")"
  [[ -z "${invalid}" ]]
}

# Build WEBHOOK_MAP for the Lambda using only webhookUrl from PROJECTS_CONFIG
resolve_webhook_map() {
  local from_projects
  from_projects="$(build_webhook_map)"

  echo "Building WEBHOOK_MAP from ${PROJECTS_CONFIG}" >&2

  if ! validate_webhook_map_json "${from_projects}"; then
    echo "ERROR: No valid Slack webhook URLs in PROJECTS_CONFIG." >&2
    echo "  Add webhookUrl per project in PROJECTS_CONFIG (GitHub Secret or deploy/config/projects.json)" >&2
    echo "  URLs must be full https://hooks.slack.com/services/T.../B.../..." >&2
    echo "  Do NOT use placeholders like https://hooks.slack.com/services/..." >&2
    return 1
  fi
  echo "${from_projects}"
}

wait_for_lambda() {
  local label="${1:-Lambda update}"
  for i in $(seq 1 24); do
    local state
    state="$(aws lambda get-function \
      --function-name "${FUNCTION_NAME}" \
      --region "${AWS_REGION}" \
      --query 'Configuration.LastUpdateStatus' \
      --output text)"
    echo "[${i}/24] ${label}: ${state}"
    [[ "${state}" == "Successful" ]] && return 0
    [[ "${state}" == "Failed" ]] && { echo "Lambda update failed"; return 1; }
    sleep 5
  done
  echo "Timed out waiting for Lambda"
  return 1
}

wait_for_event_source_mapping() {
  local uuid="$1"
  local label="${2:-SQS trigger}"
  for i in $(seq 1 24); do
    local state
    state="$(aws lambda get-event-source-mapping \
      --uuid "${uuid}" \
      --region "${AWS_REGION}" \
      --query 'State' \
      --output text 2>/dev/null || echo "Unknown")"
    echo "[${i}/24] ${label}: ${state}"
    [[ "${state}" == "Enabled" ]] && return 0
    sleep 5
  done
  echo "Timed out waiting for event source mapping ${uuid}"
  return 1
}

get_queue_arn() {
  local queue_name="$1"
  aws sqs get-queue-url --queue-name "${queue_name}" --region "${AWS_REGION}" \
    --query 'QueueUrl' --output text | xargs -I{} aws sqs get-queue-attributes \
    --queue-url {} --attribute-names QueueArn --region "${AWS_REGION}" \
    --query 'Attributes.QueueArn' --output text
}

get_queue_url() {
  local queue_name="$1"
  aws sqs get-queue-url --queue-name "${queue_name}" --region "${AWS_REGION}" \
    --query 'QueueUrl' --output text
}

# Verify SNS topic is reachable (uses ListSubscriptionsByTopic — included in minimal deploy policy)
verify_sns_topic() {
  local err_file
  err_file="$(mktemp)"
  if aws sns list-subscriptions-by-topic \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --region "${AWS_REGION}" \
    2>"${err_file}" >/dev/null; then
    rm -f "${err_file}"
    return 0
  fi

  local err
  err="$(cat "${err_file}")"
  rm -f "${err_file}"

  if echo "${err}" | grep -qiE "AccessDenied|AuthorizationError|not authorized"; then
    echo "ERROR: Access denied reading SNS topic '${SNS_TOPIC_NAME}'" >&2
    echo "  ARN: ${SNS_TOPIC_ARN}" >&2
    echo "  Add sns:ListSubscriptionsByTopic (and related SNS actions) to deploy user IAM policy." >&2
    echo "  Copy full policy from: deploy/iam/github-actions-deploy-policy.json" >&2
  elif echo "${err}" | grep -qiE "NotFound|does not exist"; then
    echo "ERROR: SNS topic '${SNS_TOPIC_NAME}' not found in region ${AWS_REGION}" >&2
    echo "  ARN: ${SNS_TOPIC_ARN}" >&2
  else
    echo "ERROR: Failed to verify SNS topic '${SNS_TOPIC_NAME}'" >&2
    echo "  ${err}" >&2
  fi
  return 1
}