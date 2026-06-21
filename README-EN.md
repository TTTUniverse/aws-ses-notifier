# SES Bounce Slack Notifier — Deployment Guide

## Prerequisites
1. AWS CLI
2. jq

If you want to run this locally, you'll need to run the script manually — the file to run is `deploy/scripts/deploy.sh` (without going through GitHub Actions) — and you must first set up `deploy/.env` based on the `.env.example` template.

## Architecture

```text
SES (bounce/complaint)
  ↓
SNS Topic: ses-reputation-alerts
  ↓
  ├── Subscription + FilterPolicy (Project A — filtered by email/source)
  │     ↓
  │   SQS: ses-a-queue
  │
  └── Subscription + FilterPolicy (Project B — filtered by email/source)
        ↓
      SQS: ses-b-queue

ses-a-queue ─┐
ses-b-queue      ─┼──► Lambda: ses-bounce-slack-notifier (single shared codebase)
                     ↓
              Slack (per-project channel, via PROJECTS_CONFIG)
```

## Prerequisites on AWS Before Deploying (One-time Manual Setup)

1. **Create an SNS Topic** named `ses-reputation-alerts`
2. **Configure SES** to send Bounce/Complaint notifications to this topic (via Configuration Set or at the identity level)
3. **Verified identities** for the sender email addresses used in the AWS SNS Subscription filter policy

Note: Do **not** enable **Raw message delivery** on the subscription, since the Lambda parses the SNS envelope.

## Creating Credentials for GitHub Actions (One-time Manual Setup)

### 1) Create an IAM User

Menu path: **Access management → Users → Create user**

1. Open the [AWS IAM Console](https://console.aws.amazon.com/iam)
2. In the left sidebar, under **Access management**, click **Users**
3. In the top-right corner of the Users table, click **Create user**
4. On the **Specify user details** page:
   - **User name** field — type: `github-actions-lambda-deploy`
   - **Provide user access to the AWS Management Console** — leave this checkbox **unchecked**
     (This user is for API access only, not console login)
   - Click **Next** at the bottom right
5. On the **Set permissions** page:
   - Under **Permissions options** — select **Attach policies directly**
   - Don't select any policy from the list yet — we'll attach a customer-managed policy separately in step 3
   - Click **Next** at the bottom right
6. On the **Review and create** page:
   - Verify that **User name** shows `github-actions-lambda-deploy`
   - Click **Create user** at the bottom right

### 2) Create an Access Key

1. While on the User detail page for `github-actions-lambda-deploy`
   (if you navigated away: left menu **Users** → click on `github-actions-lambda-deploy`)
2. Click the **Security credentials** tab (in the middle tab row, next to **Permissions**)
3. Scroll down to the **Access keys** section — click **Create access key**
4. On the **Access key best practices & alternatives** page:
   - Under **Use case** — select **Application running outside AWS**
     (the 3rd radio button in the list)
   - Check the box **I understand the above recommendation...**
   - Click **Next** at the bottom right
5. On the **Set description tag** page (optional):
   - **Description tag value** field — type: `github-actions-deploy`
   - Click **Create access key** at the bottom right

### 3) Create a Customer-Managed IAM Policy

Path: **Policy → Create policy**

1. Open the file `deploy/iam/github-actions-deploy-policy.json`, edit the variables according to the table below, then paste the edited content into the **Policy editor**.

#### Table of values to update

| # | Statement (Sid) | Values to update | Original example |
|---|---|---|---|
| 1 | `LambdaDeploy` | region, account id, **function name** | `arn:aws:lambda:us-east-1:183248602306:function:ses-bounce-slack-notifier` |
| 2 | `SqsQueues` | region, account id | `arn:aws:sqs:us-east-1:183248602306:ses-*` (the `ses-*` part is the queue name prefix — if you change the `queueName` prefix, update it here too) |
| 3 | `SnsTopicManage` | region, account id, **SNS topic name** | `arn:aws:sns:us-east-1:183248602306:ses-reputation-alerts` |
| 4 | `LambdaExecutionRoleCreate` | account id, **role name** | `arn:aws:iam::183248602306:role/ses-bounce-slack-notifier-role` |
| 5 | `PassRoleNewLambdaRole` | account id, **role name** (both the `Resource` and verify it matches the actual role name used) | `arn:aws:iam::183248602306:role/ses-bounce-slack-notifier-role` |
| 6 | `PassRoleExistingLambdaRole` | account id, **role name** (has a random suffix `-ezuv100o`) | `arn:aws:iam::183248602306:role/service-role/ses-bounce-slack-notifier-role-ezuv100o` |

2. Click **Next**
3. Enter the **Policy name** as `deploy-ses-bounce-slack-notifier`
4. Click **Next** at the bottom right, then click **Save changes**

### 4) Attach the Customer-Managed Policy to the IAM User

1. Go to the IAM Users page for `github-actions-lambda-deploy`
2. Click the **Permissions** tab (in the middle tab row, next to **Summary**)
3. Click **Add permissions** → a submenu appears, select **Add permissions**
4. On the **Attach policies directly** page: search for `deploy-ses-bounce-slack-notifier`, then click **Next** → **Add permissions**

### 5) Create Access Key → Add to GitHub Secrets

Path: Repo → Settings → Secrets and variables → Actions → New repository secret

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key of the deploy user |
| `AWS_SECRET_ACCESS_KEY` | Secret key |
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | (optional) 12-digit account ID |
| `SLACK_WEBHOOK_URL` | (optional) Fallback webhook used when a queue has no mapping |
| `SLACK_CHANNEL` | (optional) Fallback channel |
| `LAMBDA_ROLE_ARN` | (optional) If you already have an existing role, put its ARN here — **otherwise leave it blank**, and the pipeline will create the role `ses-bounce-slack-notifier-role` for you (requires `iam:CreateRole` permission in the policy above) |
| `PROJECTS_CONFIG` | ✅ The entire `projects.json` file as JSON (the pipeline builds the Lambda's `WEBHOOK_MAP` from this value) |

## `projects.json` Reference

This file is the main config that determines which SQS queue each project uses, which Slack channel it notifies, and how SNS messages are filtered. It's the source used to build the Lambda's `WEBHOOK_MAP` and to provision AWS resources (SQS queue, SNS subscription + filter policy).

### File Location

- Runtime file: `deploy/config/projects.json` (listed in `.gitignore` — **must not be committed to the repo**)
- Example/template: `deploy/config/projects.example.json` (safe to commit, used as a reference)
- When deploying via GitHub Actions, this file is generated from the GitHub Secret `PROJECTS_CONFIG`

### Priority Order During Deploy

1. If the GitHub Secret `PROJECTS_CONFIG` exists → it is always used first (recommended for production)
2. If no secret is set but a committed `deploy/config/projects.json` exists → that file is used
3. If neither exists → falls back to `projects.example.json` (a warning is printed in the log)

### Field Reference

| Field | Required? | Description |
|---|---|---|
| `queueName` | ✅ Required | The SQS queue name for this project. **Must start with the `ses-` prefix** (because the deploy user's IAM policy — `deploy/iam/github-actions-deploy-policy.json` — scopes SQS permissions to the pattern: `arn:aws:sqs:<region>:<account-id>:ses-*`) |
| `projectLabel` | ✅ Required | Display name for the project — shown in Slack messages and logs |
| `webhookUrl` | ✅ Required | The Slack Incoming Webhook URL for this project (must be a real URL, not a placeholder) |
| `channel` | ⭕ Optional | Slack channel to override the webhook's default destination, e.g. `#test-ses`. If omitted, the webhook's own default channel is used |
| `filterPolicy` | ✅ Required | SNS filter policy that determines which SES messages get routed to this queue |

#### `filterPolicy` Sub-fields

| Field | Description |
|---|---|
| `notificationType` | Array of notification types to receive, e.g. `["Bounce", "Complaint"]` (`Delivery` is excluded — volume is too high) |
| `mail.source` | Array of sender email addresses used to filter — determines which project a given SES message belongs to |

> This filter policy uses `MessageBody` scope (set automatically by the `ensure-sns-subscriptions.sh` script), meaning SNS checks the JSON content of the SES notification itself.

## Triggering the First Deploy

The workflow runs automatically when code is pushed to `main` (only when files under `lambda/...` or `deploy/**` change), or you can trigger it manually via **Actions → Deploy Lambda → Run workflow** (workflow_dispatch).
