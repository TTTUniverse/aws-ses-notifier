/**
 * Lambda: ses-bounce-slack-notifier
 *
 * รับ SNS notification จาก SES bounce/complaint events
 * แล้วส่งข้อความแจ้งเตือนไปยัง Slack Incoming Webhook
 * พร้อมรายละเอียดว่าอีเมล์ไหนบ้างที่ bounce หรือ complaint
 *
 * Flow:
 *   SES bounce/complaint
 *     └─► SNS Topic (ses-bounces-everythai / ses-complaints-everythai)
 *               └─► Lambda (this function)
 *                         └─► Slack Incoming Webhook
 *
 * Environment variables:
 *   SLACK_WEBHOOK_URL  — Slack Incoming Webhook URL (required, fallback)
 *   SLACK_CHANNEL      — override channel, e.g. #ses-alerts (optional)
 *   WEBHOOK_MAP        — JSON mapping queue -> { webhookUrl, channel, projectLabel } (optional)
 *   LOG_LEVEL          — "debug" | "info" (default: "info")
 */

// ---------------------------------------------------------------------------
// Types (inline — Lambda ไม่ได้ share lib/ กับ Next.js app)
// ---------------------------------------------------------------------------

/**
 * @typedef {"Bounce" | "Complaint" | "Delivery"} SesNotificationType
 *
 * @typedef {{
 *   notificationType: SesNotificationType,
 *   mail: {
 *     timestamp: string,
 *     messageId: string,
 *     source: string,
 *     destination: string[],
 *     commonHeaders?: { subject?: string, from?: string[], to?: string[] }
 *   },
 *   bounce?: {
 *     bounceType: "Undetermined" | "Permanent" | "Transient",
 *     bounceSubType: string,
 *     bouncedRecipients: Array<{
 *       emailAddress: string,
 *       action?: string,
 *       status?: string,
 *       diagnosticCode?: string
 *     }>,
 *     timestamp: string,
 *     feedbackId: string
 *   },
 *   complaint?: {
 *     complainedRecipients: Array<{ emailAddress: string }>,
 *     timestamp: string,
 *     feedbackId: string,
 *     complaintFeedbackType?: string
 *   }
 * }} SesNotification
 */

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const SLACK_WEBHOOK_URL = process.env.SLACK_WEBHOOK_URL;
const SLACK_CHANNEL = process.env.SLACK_CHANNEL;
const LOG_LEVEL = process.env.LOG_LEVEL ?? "info";
const RAW_WEBHOOK_MAP = process.env.WEBHOOK_MAP ?? process.env.SLACK_WEBHOOK_MAP;

/** @type {Record<string, { webhookUrl?: string, channel?: string, projectLabel?: string }>} */
const WEBHOOK_MAP = (() => {
  if (!RAW_WEBHOOK_MAP) return {};
  try {
    return JSON.parse(RAW_WEBHOOK_MAP);
  } catch {
    return {};
  }
})();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function log(level, message, data) {
  if (level === "debug" && LOG_LEVEL !== "debug") return;
  const entry = { level, message, ...(data ? { data } : {}) };
  console.log(JSON.stringify(entry));
}

/**
 * Format time as ISO 8601 string (e.g. 2026-05-10T21:36:14.169Z)
 * @param {string} isoString
 */
function formatTime(isoString) {
  try {
    return new Date(isoString).toISOString();
  } catch {
    return isoString;
  }
}

/**
 * Format Thai time from UTC ISO string
 * @param {string} isoString
 */
function formatThaiTime(isoString) {
  try {
    log("debug", "formatThaiTime", { isoString });
    return new Date(isoString).toLocaleString("th-TH", {
      timeZone: "Asia/Bangkok",
      dateStyle: "medium",
      timeStyle: "short",
    });
  } catch {
    return isoString;
  }
}

/**
 * ส่ง message ไปยัง Slack Incoming Webhook
 * @param {object} payload
 */
async function sendToSlack(payload, { webhookUrl, channel }) {
  const targetWebhook = webhookUrl ?? SLACK_WEBHOOK_URL;
  if (!targetWebhook) {
    throw new Error("Slack webhook URL is not configured");
  }

  const body = channel
    ? { ...payload, channel }
    : payload;

  const response = await fetch(targetWebhook, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Slack webhook failed: ${response.status} ${text}`);
  }

  log("debug", "Slack message sent", { status: response.status });
}

/**
 * ดึงชื่อ Queue จาก eventSourceARN
 * @param {{ eventSourceARN?: string }} record
 */
function getQueueName(record) {
  const arn = record?.eventSourceARN ?? "";
  const arnTail = arn.split(":").pop();
  if (!arnTail) return undefined;
  const parts = arnTail.split("/");
  return parts[parts.length - 1];
}

/**
 * เลือก Slack target ตาม Queue (fallback ไป global)
 * @param {string | undefined} queueName
 */
function resolveSlackTarget(queueName) {
  const entry = queueName ? WEBHOOK_MAP[queueName] : undefined;
  return {
    webhookUrl: entry?.webhookUrl ?? SLACK_WEBHOOK_URL,
    channel: entry?.channel ?? SLACK_CHANNEL,
    projectLabel: entry?.projectLabel ?? queueName ?? "unknown-project",
  };
}

/**
 * รองรับทั้ง SQS event (wrapped SNS) และ SNS event ตรง (กรณีเผื่อ trigger จาก SNS)
 * @param {{ body?: string, Sns?: { Message?: string } }} record
 * @returns {object | string | undefined}
 */
function extractSnsMessage(record) {
  if (!record) return undefined;

  // กรณี SNS → Lambda ตรง
  if (record.Sns?.Message) {
    return record.Sns.Message;
  }

  // กรณี SQS → Lambda (SNS envelope)
  if (record.body) {
    try {
      const parsed = JSON.parse(record.body);
      // ถ้าเป็น SNS envelope
      if (parsed?.Message) return parsed.Message;
      // ถ้าเป็น payload ตรง (เช่นส่ง raw SES notification)
      return parsed;
    } catch {
      return undefined;
    }
  }

  return undefined;
}

// ---------------------------------------------------------------------------
// Message builders
// ---------------------------------------------------------------------------

/**
 * สร้าง Slack Block Kit message สำหรับ bounce event
 * @param {SesNotification} notification
 * @param {{ projectLabel: string, queueName?: string }} meta
 */
function buildBounceMessage(notification, meta) {
  const { bounce, mail } = notification;
  const isHardBounce = bounce.bounceType === "Permanent";
  const emoji = isHardBounce ? "🔴" : "🟡";
  const bounceLabel = isHardBounce ? "Hard Bounce" : "Soft Bounce";

  const recipientLines = bounce.bouncedRecipients
    .map((r) => {
      const parts = [`• \`${r.emailAddress}\``];
      if (r.status) parts.push(`Status: ${r.status}`);
      if (r.diagnosticCode) parts.push(`Diagnostic: ${r.diagnosticCode}`);
      return parts.join("\n  ");
    })
    .join("\n");

  const emailSubject =
    mail.commonHeaders?.subject ?? "(no subject)";

  return {
    blocks: [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: `${emoji} SES ${bounceLabel} Detected`,
          emoji: true,
        },
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `Project: ${meta.projectLabel}`,
          },
          {
            type: "mrkdwn",
            text: `Queue: ${meta.queueName ?? "unknown"}`,
          },
        ],
      },
      {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: `*Type*\n${bounce.bounceType} / ${bounce.bounceSubType}`,
          },
          {
            type: "mrkdwn",
            text: `*Time (TH)*\n${formatThaiTime(bounce.timestamp)}`,
          },
          {
            type: "mrkdwn",
            text: `*Sent From*\n${mail.source}`,
          },
          {
            type: "mrkdwn",
            text: `*Email Subject*\n${emailSubject}`,
          },
        ],
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `*Bounced Addresses (${bounce.bouncedRecipients.length})*\n${recipientLines}`,
        },
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `Feedback ID: ${bounce.feedbackId} | Message ID: ${mail.messageId}`,
          },
        ],
      },
    ],
  };
}

/**
 * สร้าง Slack Block Kit message สำหรับ complaint event
 * @param {SesNotification} notification
 * @param {{ projectLabel: string, queueName?: string }} meta
 */
function buildComplaintMessage(notification, meta) {
  const { complaint, mail } = notification;

  const recipientLines = complaint.complainedRecipients
    .map((r) => `• \`${r.emailAddress}\``)
    .join("\n");

  const feedbackType = complaint.complaintFeedbackType ?? "unknown";
  const emailSubject = mail.commonHeaders?.subject ?? "(no subject)";

  return {
    blocks: [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: "🚨 SES Complaint (Spam Report) Detected",
          emoji: true,
        },
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `Project: ${meta.projectLabel}`,
          },
          {
            type: "mrkdwn",
            text: `Queue: ${meta.queueName ?? "unknown"}`,
          },
        ],
      },
      {
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: `*Feedback Type*\n${feedbackType}`,
          },
          {
            type: "mrkdwn",
            text: `*Time (TH)*\n${formatThaiTime(complaint.timestamp)}`,
          },
          {
            type: "mrkdwn",
            text: `*Sent From*\n${mail.source}`,
          },
          {
            type: "mrkdwn",
            text: `*Email Subject*\n${emailSubject}`,
          },
        ],
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text: `*Complained Addresses (${complaint.complainedRecipients.length})*\n${recipientLines}`,
        },
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: `Feedback ID: ${complaint.feedbackId} | Message ID: ${mail.messageId}`,
          },
        ],
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// Lambda handler
// ---------------------------------------------------------------------------

/**
 * @param {{
 *   Records: Array<{
 *     body: string,
 *     eventSourceARN?: string
 *   }>
 * }} event
 */
export async function handler(event) {
  log("debug", "Received event", { records: event?.Records?.length ?? 0 });

  const errors = [];

  for (const record of event.Records ?? []) {
    try {
      const queueName = getQueueName(record);
      const slackTarget = resolveSlackTarget(queueName);

      const snsMessage = extractSnsMessage(record);
      if (!snsMessage) {
        log("info", "Skipping record without SNS message", {
          queueName,
          bodySample: record.body?.slice(0, 200),
        });
        continue;
      }
      log("debug", "Processing SNS message from SQS", {
        queueName,
        hasMessage: Boolean(snsMessage),
      });

      /** @type {SesNotification} */
      let notification;
      try {
        notification =
          typeof snsMessage === "string" ? JSON.parse(snsMessage) : snsMessage;
      } catch {
        log("info", "Skipping non-JSON SNS message", { snsMessage });
        continue;
      }

      const { notificationType } = notification;
      const meta = {
        projectLabel: slackTarget.projectLabel ?? queueName ?? "unknown-project",
        queueName,
      };

      if (notificationType === "Bounce") {
        if (!notification.bounce) {
          log("info", "Bounce notification missing bounce field, skipping");
          continue;
        }
        const payload = buildBounceMessage(notification, meta);
        await sendToSlack(payload, slackTarget);
        log("info", "Bounce notification sent to Slack", {
          bounceType: notification.bounce.bounceType,
          recipients: notification.bounce.bouncedRecipients.map(
            (r) => r.emailAddress,
          ),
          project: meta.projectLabel,
        });
      } else if (notificationType === "Complaint") {
        if (!notification.complaint) {
          log("info", "Complaint notification missing complaint field, skipping");
          continue;
        }
        const payload = buildComplaintMessage(notification, meta);
        await sendToSlack(payload, slackTarget);
        log("info", "Complaint notification sent to Slack", {
          feedbackType: notification.complaint.complaintFeedbackType,
          recipients: notification.complaint.complainedRecipients.map(
            (r) => r.emailAddress,
          ),
          project: meta.projectLabel,
        });
      } else {
        // Delivery notifications — ไม่ส่งไป Slack (volume สูงเกินไป)
        log("debug", "Skipping delivery notification");
      }
    } catch (err) {
      log("info", "Error processing record", {
        error: err instanceof Error ? err.message : String(err),
      });
      errors.push(err);
    }
  }

  if (errors.length > 0) {
    throw new Error(
      `Failed to process ${errors.length} record(s): ${errors.map((e) => e.message).join(", ")}`,
    );
  }

  return { statusCode: 200, body: "OK" };
}
