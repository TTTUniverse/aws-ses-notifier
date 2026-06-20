#!/usr/bin/env bash
# Create SQS queues per project and attach policy allowing SNS topic to publish
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

load_env
resolve_projects_config

echo "SNS Topic ARN: ${SNS_TOPIC_ARN}"
echo "AWS Region: ${AWS_REGION}"

# Verify SNS topic exists (and deploy user has permission)
SNS_CHECK_ERR="$(mktemp)"
if ! aws sns get-topic-attributes \
  --topic-arn "${SNS_TOPIC_ARN}" \
  --region "${AWS_REGION}" \
  2>"${SNS_CHECK_ERR}" >/dev/null; then
  SNS_ERR="$(cat "${SNS_CHECK_ERR}")"
  rm -f "${SNS_CHECK_ERR}"

  if echo "${SNS_ERR}" | grep -qi "AccessDenied"; then
    echo "ERROR: Access denied reading SNS topic '${SNS_TOPIC_NAME}'" >&2
    echo "  ARN: ${SNS_TOPIC_ARN}" >&2
    echo "  Deploy user needs sns:GetTopicAttributes (and sns:SetSubscriptionAttributes) on this topic." >&2
    echo "  Update IAM inline policy — see deploy/iam/github-actions-deploy-policy.json" >&2
  elif echo "${SNS_ERR}" | grep -qi "NotFound"; then
    echo "ERROR: SNS topic '${SNS_TOPIC_NAME}' not found in region ${AWS_REGION}" >&2
    echo "  ARN: ${SNS_TOPIC_ARN}" >&2
    echo "  Create the topic or fix SNS_TOPIC_NAME / AWS_REGION." >&2
  else
    echo "ERROR: Failed to verify SNS topic '${SNS_TOPIC_NAME}'" >&2
    echo "  ${SNS_ERR}" >&2
  fi
  exit 1
fi
rm -f "${SNS_CHECK_ERR}"
echo "SNS topic verified: ${SNS_TOPIC_NAME}"

QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
echo "Provisioning ${QUEUE_COUNT} SQS queue(s)..."

for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  PROJECT_LABEL="$(jq -r ".projects[${i}].projectLabel" "${PROJECTS_CONFIG}")"

  echo "--- Queue: ${QUEUE_NAME} (${PROJECT_LABEL}) ---"

  if aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    echo "Queue exists: ${QUEUE_NAME}"
  else
    echo "Creating queue: ${QUEUE_NAME}"
    aws sqs create-queue \
      --queue-name "${QUEUE_NAME}" \
      --region "${AWS_REGION}" \
      --attributes '{
        "VisibilityTimeout": "60",
        "MessageRetentionPeriod": "1209600",
        "ReceiveMessageWaitTimeSeconds": "0"
      }' \
      --tags "Project=${PROJECT_LABEL},ManagedBy=ses-bounce-slack-notifier"
  fi

  QUEUE_URL="$(get_queue_url "${QUEUE_NAME}")"
  QUEUE_ARN="$(get_queue_arn "${QUEUE_NAME}")"

  POLICY="$(jq -n \
    --arg queueArn "${QUEUE_ARN}" \
    --arg topicArn "${SNS_TOPIC_ARN}" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Sid: "AllowSnsPublish",
        Effect: "Allow",
        Principal: { Service: "sns.amazonaws.com" },
        Action: "sqs:SendMessage",
        Resource: $queueArn,
        Condition: { ArnEquals: { "aws:SourceArn": $topicArn } }
      }]
    }')"

  ATTR_FILE="$(mktemp)"
  jq -n --arg policy "$(echo "${POLICY}" | jq -c .)" '{Policy: $policy}' > "${ATTR_FILE}"
  aws sqs set-queue-attributes \
    --queue-url "${QUEUE_URL}" \
    --region "${AWS_REGION}" \
    --attributes "file://${ATTR_FILE}"
  rm -f "${ATTR_FILE}"

  echo "Queue policy updated: ${QUEUE_NAME} (${QUEUE_ARN})"
done

echo "SQS provisioning complete."
