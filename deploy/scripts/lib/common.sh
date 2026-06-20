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
