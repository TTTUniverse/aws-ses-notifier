#!/usr/bin/env bash
# Create/update SNS → SQS subscriptions with FilterPolicy (MessageBody scope)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env
resolve_projects_config

QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
echo "Configuring ${QUEUE_COUNT} SNS subscription(s) on ${SNS_TOPIC_ARN}..."

for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  FILTER_POLICY="$(jq -c ".projects[${i}].filterPolicy" "${PROJECTS_CONFIG}")"
  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  echo "--- Subscription: ${SNS_TOPIC_NAME} → ${QUEUE_NAME} ---"
  echo "Filter policy: ${FILTER_POLICY}"

  EXISTING_ARN="$(aws sns list-subscriptions-by-topic \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --region "${AWS_REGION}" \
    --query "Subscriptions[?Protocol=='sqs' && Endpoint=='${QUEUE_ARN}'].SubscriptionArn | [0]" \
    --output text)"

  if [[ "${EXISTING_ARN}" == "None" || -z "${EXISTING_ARN}" ]]; then
    echo "Creating SNS subscription..."
    SUB_ARN="$(aws sns subscribe \
      --topic-arn "${SNS_TOPIC_ARN}" \
      --protocol sqs \
      --notification-endpoint "${QUEUE_ARN}" \
      --return-subscription-arn \
      --region "${AWS_REGION}" \
      --query 'SubscriptionArn' \
      --output text)"
    echo "Created subscription: ${SUB_ARN}"
  else
    SUB_ARN="${EXISTING_ARN}"
    echo "Subscription exists: ${SUB_ARN}"
  fi

  # Update filter policy + scope (idempotent)
  aws sns set-subscription-attributes \
    --subscription-arn "${SUB_ARN}" \
    --attribute-name FilterPolicy \
    --attribute-value "${FILTER_POLICY}" \
    --region "${AWS_REGION}"

  aws sns set-subscription-attributes \
    --subscription-arn "${SUB_ARN}" \
    --attribute-name FilterPolicyScope \
    --attribute-value MessageBody \
    --region "${AWS_REGION}"

  SUB_STATUS="$(aws sns get-subscription-attributes \
    --subscription-arn "${SUB_ARN}" \
    --region "${AWS_REGION}" \
    --query 'Attributes.PendingConfirmation' \
    --output text)"

  if [[ "${SUB_STATUS}" == "true" ]]; then
    echo "WARNING: Subscription ${SUB_ARN} is pending confirmation (SQS auto-confirms normally)"
  else
    echo "Subscription confirmed: ${SUB_ARN}"
  fi
done

echo "SNS subscriptions configured."
