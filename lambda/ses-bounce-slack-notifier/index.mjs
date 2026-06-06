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
 *   SLACK_WEBHOOK_URL  — Slack Incoming Webhook URL (required)
 *   SLACK_CHANNEL      — override channel, e.g. #ses-alerts (optional)
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
async function sendToSlack(payload) {
  if (!SLACK_WEBHOOK_URL) {
    throw new Error("SLACK_WEBHOOK_URL environment variable is not set");
  }

  const body = SLACK_CHANNEL
    ? { ...payload, channel: SLACK_CHANNEL }
    : payload;

  const response = await fetch(SLACK_WEBHOOK_URL, {
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

// ---------------------------------------------------------------------------
// Message builders
// ---------------------------------------------------------------------------

/**
 * สร้าง Slack Block Kit message สำหรับ bounce event
 * @param {SesNotification} notification
 */
function buildBounceMessage(notification) {
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
        type: "section",
        fields: [
          {
            type: "mrkdwn",
            text: `*Type*\n${bounce.bounceType} / ${bounce.bounceSubType}`,
          },
          {
            type: "mrkdwn",
            text: `*Time (TH)*\n${formatTime(bounce.timestamp)}`,
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
 */
function buildComplaintMessage(notification) {
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
 * @param {{ Records: Array<{ Sns: { Message: string, Subject?: string } }> }} event
 */
export async function handler(event) {
  log("debug", "Received event", event);

  const errors = [];

  for (const record of event.Records) {
    try {
      const snsMessage = record.Sns.Message;
      log("debug", "Processing SNS message", { snsMessage });

      /** @type {SesNotification} */
      let notification;
      try {
        notification = JSON.parse(snsMessage);
      } catch {
        log("info", "Skipping non-JSON SNS message", { snsMessage });
        continue;
      }

      const { notificationType } = notification;

      if (notificationType === "Bounce") {
        if (!notification.bounce) {
          log("info", "Bounce notification missing bounce field, skipping");
          continue;
        }
        const payload = buildBounceMessage(notification);
        await sendToSlack(payload);
        log("info", "Bounce notification sent to Slack", {
          bounceType: notification.bounce.bounceType,
          recipients: notification.bounce.bouncedRecipients.map(
            (r) => r.emailAddress,
          ),
        });
      } else if (notificationType === "Complaint") {
        if (!notification.complaint) {
          log("info", "Complaint notification missing complaint field, skipping");
          continue;
        }
        const payload = buildComplaintMessage(notification);
        await sendToSlack(payload);
        log("info", "Complaint notification sent to Slack", {
          feedbackType: notification.complaint.complaintFeedbackType,
          recipients: notification.complaint.complainedRecipients.map(
            (r) => r.emailAddress,
          ),
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
