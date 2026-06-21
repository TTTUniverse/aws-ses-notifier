#!/usr/bin/env bash
# Create/update SNS → SQS subscriptions with FilterPolicy (MessageBody scope)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Load AWS/Lambda settings from deploy/.env (or environment variables) and
# locate the projects config file (deploy/config/projects.json or the
# example template as fallback).
load_env
resolve_projects_config

# Number of projects defined in the config — each project maps to one
# SQS queue and one SNS subscription with its own message filter.
QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
echo "Configuring ${QUEUE_COUNT} SNS subscription(s) on ${SNS_TOPIC_ARN}..."

# Loop over every project (0-indexed) and ensure its SNS → SQS subscription
# exists and is configured with the correct filter policy.
for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  # Read this project's queue name and filter policy (the rules that decide
  # which SNS messages get delivered to this queue, e.g. by notificationType
  # or sender address) from the config file.
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  FILTER_POLICY="$(jq -c ".projects[${i}].filterPolicy" "${PROJECTS_CONFIG}")"
  # Look up the queue's ARN (required to identify it as an SNS subscription endpoint).
  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  echo "--- Subscription: ${SNS_TOPIC_NAME} → ${QUEUE_NAME} ---"
  echo "Filter policy: ${FILTER_POLICY}"

  # Check whether an SQS subscription to this queue already exists on the topic,
  # so we don't create a duplicate subscription on every deploy.
  EXISTING_ARN="$(aws sns list-subscriptions-by-topic \
    --topic-arn "${SNS_TOPIC_ARN}" \
    --region "${AWS_REGION}" \
    --query "Subscriptions[?Protocol=='sqs' && Endpoint=='${QUEUE_ARN}'].SubscriptionArn | [0]" \
    --output text)"

  if [[ "${EXISTING_ARN}" == "None" || -z "${EXISTING_ARN}" ]]; then
    # No existing subscription found — create a new one.
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
    # Subscription already exists — reuse it instead of creating a duplicate.
    SUB_ARN="${EXISTING_ARN}"
    echo "Subscription exists: ${SUB_ARN}"
  fi

  # Set FilterPolicyScope to MessageBody before FilterPolicy. New subscriptions
  # default to MessageAttributes, which rejects nested keys like mail.source.
  aws sns set-subscription-attributes \
    --subscription-arn "${SUB_ARN}" \
    --attribute-name FilterPolicyScope \
    --attribute-value MessageBody \
    --region "${AWS_REGION}"

  # Apply (or refresh) the FilterPolicy so only relevant messages
  # (matching this project's rules) get delivered to its queue.
  aws sns set-subscription-attributes \
    --subscription-arn "${SUB_ARN}" \
    --attribute-name FilterPolicy \
    --attribute-value "${FILTER_POLICY}" \
    --region "${AWS_REGION}"

  # SQS subscriptions normally auto-confirm immediately, but check the
  # PendingConfirmation status anyway and warn if it's stuck.
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