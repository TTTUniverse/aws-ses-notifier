#!/usr/bin/env bash
# Create SQS queues per project and attach policy allowing SNS topic to publish
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Load AWS/Lambda settings and locate the projects config file.
load_env
resolve_projects_config

echo "SNS Topic ARN: ${SNS_TOPIC_ARN}"
echo "AWS Region: ${AWS_REGION}"

# Make sure the SNS topic actually exists and is readable before trying to
# create queues / attach policies for it — fail fast with a clear error
# instead of failing deep inside the loop below.
verify_sns_topic
echo "SNS topic verified: ${SNS_TOPIC_NAME}"

# Number of projects in the config — one SQS queue is provisioned per project.
QUEUE_COUNT="$(jq '.projects | length' "${PROJECTS_CONFIG}")"
echo "Provisioning ${QUEUE_COUNT} SQS queue(s)..."

# Loop over every project and ensure its dedicated SQS queue exists with the
# correct policy allowing the SNS topic to publish into it.
for i in $(seq 0 $((QUEUE_COUNT - 1))); do
  QUEUE_NAME="$(jq -r ".projects[${i}].queueName" "${PROJECTS_CONFIG}")"
  PROJECT_LABEL="$(jq -r ".projects[${i}].projectLabel" "${PROJECTS_CONFIG}")"

  echo "--- Queue: ${QUEUE_NAME} (${PROJECT_LABEL}) ---"

  # Create the queue only if it doesn't already exist, so re-running this
  # script is safe (idempotent) and won't error out on existing queues.
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

  # Build the queue's access policy: allow the SNS service to send messages
  # into this queue, but only when the message originates from our specific
  # SNS topic (enforced via the aws:SourceArn condition) — this prevents
  # any other SNS topic in the account from publishing to this queue.
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

  # Write the policy to a temp file (set-queue-attributes expects a file
  # reference for the Policy attribute) and apply it to the queue.
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