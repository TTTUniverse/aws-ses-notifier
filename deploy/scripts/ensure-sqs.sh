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

verify_sns_topic
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
