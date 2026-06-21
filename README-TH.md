# SES Bounce Slack Notifier — Deployment Guide

## Prerequisites
1. AWS cli
2. jq

ถ้าต้องการรันผ่าน local ต้องใช้ script แบบ manual โดยไฟล์ที่รันคือ deploy/scripts/deploy.sh (ไม่ผ่าน GitHub Actions) และต้องตั้งค่า deploy/.env จากตัวอย่าง .env.example ก่อน


## สถาปัตยกรรม

```text
SES (bounce/complaint)
  ↓
SNS Topic: ses-reputation-alerts
  ↓
  ├── Subscription + FilterPolicy (Project A — filter ตาม email/source)
  │     ↓
  │   SQS: ses-a-queue
  │
  └── Subscription + FilterPolicy (Project B— filter ตาม email/source)
        ↓
      SQS: ses-b-queue

ses-a-queue ─┐
ses-b-queue      ─┼──► Lambda: ses-bounce-slack-notifier (โค้ดเดียว)
                     ↓
              Slack (channel ต่อโปรเจกต์ ผ่าน PROJECTS_CONFIG)
```


## สิ่งที่ต้องเตรียมบน AWS ก่อน Deploy (Manual ครั้งเดียว)
1. **สร้าง SNS Topic** ชื่อ `ses-reputation-alerts`
2. **ตั้งค่า SES** ให้ Bounce/Complaint notifications ส่งไป topic นี้ (Configuration Set หรือ Identity-level)
3. **Verified identities** สำหรับ sender email ที่ใช้ใน AWS SNS Subscription filter policy
หมายเหตุ: ไม่ต้องเปิด **Raw message delivery** บน subscription เพราะ Lambda parse SNS envelope

# สร้าง Credentials สำหรับ GitHub Actions (Manual ครั้งเดียว)
### 1) สร้าง IAM User
เส้นทางเมนู: **Access management → Users → Create user**

1. เปิด [AWS IAM Console](https://console.aws.amazon.com/iam)

2. เมนูด้านซ้าย ใต้หัวข้อ **Access management** คลิก **Users**

3. มุมขวาบนของตาราง Users คลิกปุ่ม **Create user**

4. หน้า **Specify user details**:
   - ช่อง **User name** — พิมพ์: `github-actions-lambda-deploy`
   - หัวข้อ **Provide user access to the AWS Management Console** — **ไม่ต้องเปิด** checkbox นี้
     (User นี้ใช้งานผ่าน API เท่านั้น ไม่ได้ login console)
   - คลิกปุ่ม **Next** มุมขวาล่าง

5. หน้า **Set permissions**:
   - ตัวเลือก **Permissions options** — เลือก **Attach policies directly**
   - ยังไม่ต้องเลือก policy ใดจากรายการ — เราจะ attach inline policy แยกต่างหากใน 2.2
   - คลิกปุ่ม **Next** มุมขวาล่าง

6. หน้า **Review and create**:
   - ตรวจสอบว่า **User name** แสดง `github-actions-lambda-deploy`
   - คลิกปุ่ม **Create user** มุมขวาล่าง

### 2) สร้าง Access Key
1. อยู่ที่หน้า User detail ของ `github-actions-lambda-deploy`
   (ถ้าออกมาแล้ว: เมนูซ้าย **Users** → คลิกชื่อ `github-actions-lambda-deploy`)

2. คลิกแท็บ **Security credentials** (อยู่แถวแท็บกลางหน้า ถัดจาก **Permissions**)

3. เลื่อนลงมาที่หัวข้อ **Access keys** — คลิกปุ่ม **Create access key**

4. หน้า **Access key best practices & alternatives**:
   - หัวข้อ **Use case** — เลือก **Application running outside AWS**
     (radio button ตัวที่ 3 ในรายการ)
   - Checkbox **I understand the above recommendation...** — เปิด checkbox นี้
   - คลิกปุ่ม **Next** มุมขวาล่าง

5. หน้า **Set description tag** (optional):
   - ช่อง **Description tag value** — พิมพ์: `github-actions-deploy` 
   - คลิกปุ่ม **Create access key** มุมขวาล่าง

### 3)  IAM Policy Create Customer managed Policy
เส้นทาง: **Policy → Create policy**

1. เปิดไฟล์ `deploy/iam/github-actions-deploy-policy.json` โดยแก้ไขตัวแปรตามตารางข้างล่างนี้ และให้นำเนื้อหาและแก้ไขเสร็จใส่ไปใส่ใน **Policy editor**
## ตารางจุดที่ต้องแก้

| # | Statement (Sid) | ค่าที่ต้องแก้ | ตัวอย่างเดิม |
|---|---|---|---|
| 1 | `LambdaDeploy` | region, account id, **function name** | `arn:aws:lambda:us-east-1:183248602306:function:ses-bounce-slack-notifier` |
| 2 | `SqsQueues` | region, account id | `arn:aws:sqs:us-east-1:183248602306:ses-*` (ส่วน `ses-*` คือ prefix ชื่อคิว — ถ้าเปลี่ยน prefix queueName ต้องแก้ตรงนี้ด้วย) |
| 3 | `SnsTopicManage` | region, account id, **SNS topic name** | `arn:aws:sns:us-east-1:183248602306:ses-reputation-alerts` |
| 4 | `LambdaExecutionRoleCreate` | account id, **role name** | `arn:aws:iam::183248602306:role/ses-bounce-slack-notifier-role` |
| 5 | `PassRoleNewLambdaRole` | account id, **role name** (ทั้ง `Resource` และเช็คให้ตรงกับ role name ที่ใช้จริง) | `arn:aws:iam::183248602306:role/ses-bounce-slack-notifier-role` |
| 6 | `PassRoleExistingLambdaRole` | account id, **role name** (มีคำต่อท้ายแบบสุ่ม `-ezuv100o`) | `arn:aws:iam::183248602306:role/service-role/ses-bounce-slack-notifier-role-ezuv100o` |

2. จากนั้นคลิกปุ่ม **Next**
3. ใส่ **Policy name** เป็น `deploy-ses-bounce-slack-notifier`
4. คลิกปุ่ม **Next** มุมขวาล่าง และกด **Save changes**

### 4) IAM Users Attach Customer managed Policy

1. อยู่ที่หน้า IAM Users ของ `github-actions-lambda-deploy`
2. คลิกแท็บ **Permissions** (อยู่แถวแท็บกลางหน้า ถัดจาก **Summary**)
3. คลิกปุ่ม **Add permissions** → เมนูย่อยจะปรากฏ เลือก **Add permissions**
4. หน้า **Attach policies directly**: Search หา `deploy-ses-bounce-slack-notifier` และคลืกปุ่ม  **Next** -> **Add permissions**


### 5) สร้าง Access Key → ใส่ GitHub Secrets
เส้นทาง: Repo → Settings → Secrets and variables → Actions → New repository secret

| Secret | คำอธิบาย |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key ของ deploy user |
| `AWS_SECRET_ACCESS_KEY` | Secret key |
| `AWS_REGION` | เช่น `us-east-1` |
| `AWS_ACCOUNT_ID` | (optional) Account ID 12 หลัก |
| `SLACK_WEBHOOK_URL` | (optional) Webhook fallback เมื่อคิวไม่มี mapping |
| `SLACK_CHANNEL` | (optional) Channel fallback |
| `LAMBDA_ROLE_ARN` | (optional) ถ้ามี role เดิมอยู่แล้ว ใส่ ARN ตรงนี้ — **ไม่ใส่ก็ได้** pipeline จะสร้าง role `ses-bounce-slack-notifier-role` ให้ (ต้องมีสิทธิ์ `iam:CreateRole` ใน policy ด้านบน) |
| `PROJECTS_CONFIG` | ✅ JSON ทั้งไฟล์ `projects.json` (pipeline สร้าง Lambda `WEBHOOK_MAP` จากค่านี้) |

# รายละเอียดไฟล์ `projects.json`
 
ไฟล์นี้คือ config หลักที่กำหนดว่าแต่ละโปรเจกต์ใช้ SQS queue ไหน, ส่ง Slack webhook ไปช่องไหน และกรองข้อความ SNS แบบไหน ใช้เป็นต้นทางในการสร้าง `WEBHOOK_MAP` ของ Lambda และสร้าง resource บน AWS (SQS queue, SNS subscription + filter policy)
 
## ตำแหน่งไฟล์
 
- ใช้งานจริง: `deploy/config/projects.json` (อยู่ใน `.gitignore` **ห้าม commit เข้า repo**)
- ตัวอย่าง/template: `deploy/config/projects.example.json` (commit ได้ ใช้เป็นแนวทาง)
- เวลา deploy ผ่าน GitHub Actions ไฟล์นี้จะถูกสร้างขึ้นจาก GitHub Secret ชื่อ `PROJECTS_CONFIG` 
- 
## ลำดับความสำคัญเวลา deploy (workflow จะเลือกตามนี้)
1. ถ้ามี GitHub Secret `PROJECTS_CONFIG` → ใช้ค่านี้ก่อนเสมอ (แนะนำสำหรับ production)
2. ถ้าไม่มี secret แต่มีไฟล์ `deploy/config/projects.json` ที่ commit ไว้ → ใช้ไฟล์นี้
3. ถ้าไม่มีทั้งสองอย่าง → fallback ไปใช้ `projects.example.json` (จะมี warning เตือนใน log)


## คำอธิบาย field
 
| Field | จำเป็นไหม | คำอธิบาย |
|---|---|---|
| `queueName` | ✅ จำเป็น | ชื่อ SQS queue ของโปรเจกต์นี้ **ต้องขึ้นต้นด้วย `ses-` เท่านั้น** (เพราะ IAM policy ของ deploy user นี้ (`deploy/iam/github-actions-deploy-policy.json`) จำกัดสิทธิ์ SQS ไว้ที่ pattern: arn:aws:sqs:<region>:<account-id>:ses-*) |
| `projectLabel` | ✅ จำเป็น | ชื่อแสดงผลของโปรเจกต์ ใช้โชว์ใน Slack message และ log |
| `webhookUrl` | ✅ จำเป็น | Slack Incoming Webhook URL ของโปรเจกต์นี้ (ต้องเป็น URL จริง ไม่ใช่ placeholder) |
| `channel` | ⭕ optional | Slack channel ที่จะ override ปลายทาง webhook เช่น `#test-ses` ถ้าไม่ใส่จะใช้ default ของ webhook นั้น |
| `filterPolicy` | ✅ จำเป็น | SNS filter policy กำหนดว่าข้อความ SES แบบไหนจะถูกส่งเข้าคิวนี้ |
 
### `filterPolicy` ย่อยอีกชั้น
 
| Field | คำอธิบาย |
|---|---|
| `notificationType` | array ของ type ที่ต้องการรับ เช่น `["Bounce", "Complaint"]` (ไม่รับ `Delivery` เพราะปริมาณมากเกินไป) |
| `mail.source` | array ของ sender email ที่ filter — ใช้แยกว่าข้อความ SES นี้เป็นของโปรเจกต์ไหน |
 
> Filter policy นี้ใช้ scope แบบ `MessageBody` (ตั้งโดยสคริปต์ `ensure-sns-subscriptions.sh` อัตโนมัติ) หมายความว่า SNS จะเช็คเนื้อหา JSON ของ SES notification เอง


# วิธีเพิ่ม Queue ของโปรเจกต์ใหม่ (ses-bounce-slack-notifier)

เมื่อมีโปรเจกต์ใหม่ที่ต้องการรับ SES Bounce/Complaint แจ้งเตือนไปยัง Slack channel ของตัวเอง ให้ทำตามขั้นตอนนี้

## 1. เพิ่ม entry ใหม่ใน `projects.json`

ไฟล์ที่ใช้งานจริงคือ `deploy/config/projects.json` (ไม่ commit เข้า repo — อยู่ใน `.gitignore`)
หากรันผ่าน GitHub Actions ไฟล์นี้จะถูกสร้างจาก GitHub Secret ชื่อ `PROJECTS_CONFIG`

เพิ่ม object ใหม่ใน array `projects` เช่น:

```json
{
  "queueName": "ses-newproject-queue",
  "projectLabel": "New Project",
  "webhookUrl": "https://hooks.slack.com/services/XXX/YYY/ZZZ",
  "channel": "#newproject-alerts",
  "filterPolicy": {
    "notificationType": ["Bounce", "Complaint"],
    "mail": {
      "source": ["sender@newproject.com"]
    }
  }
}
```

### กฎสำคัญของแต่ละ field

| Field | จำเป็น | ข้อกำหนด |
|---|---|---|
| `queueName` | ✅ | **ต้องขึ้นต้นด้วย `ses-`** เท่านั้น เพราะ IAM policy ของ deploy user จำกัดสิทธิ์ SQS ไว้ที่ pattern `arn:aws:sqs:<region>:<account-id>:ses-*` |
| `projectLabel` | ✅ | ชื่อแสดงผลในข้อความ Slack และ log |
| `webhookUrl` | ✅ | ต้องเป็น Slack Incoming Webhook URL จริง (ห้ามใส่ placeholder เช่น `.../XXX/YYY/ZZZ`) |
| `channel` | ⭕ optional | override channel ปลายทาง ถ้าไม่ใส่จะใช้ default ของ webhook นั้น |
| `filterPolicy` | ✅ | กำหนดว่า SES notification แบบไหนจะถูกส่งเข้าคิวนี้ (ดูด้านล่าง) |

### `filterPolicy` ย่อย

- `notificationType`: array เช่น `["Bounce", "Complaint"]` (ไม่ใส่ `Delivery` เพราะ volume สูงเกินไป)
- `mail.source`: array ของ sender email ที่ใช้แยกว่าข้อความนี้เป็นของโปรเจกต์ไหน

> Filter policy ใช้ scope แบบ `MessageBody` ซึ่งสคริปต์ `ensure-sns-subscriptions.sh` จะตั้งค่าให้อัตโนมัติ ไม่ต้องทำเอง

## 2. อัปเดต GitHub Secret `PROJECTS_CONFIG`

1. ไปที่ Repo → **Settings → Secrets and variables → Actions**
2. แก้ไข secret ชื่อ `PROJECTS_CONFIG`
3. ใส่เนื้อหา `projects.json` **ทั้งไฟล์** (รวมโปรเจกต์เดิม + โปรเจกต์ใหม่) เป็น JSON ที่ valid

> ถ้ารัน local แทน ให้แก้ไฟล์ `deploy/config/projects.json` ตรง ๆ (สร้างจาก `projects.example.json` เป็น template ได้)

## 3. ตรวจสอบ IAM policy ของ deploy user (เฉพาะกรณีจำเป็น)

ปกติไม่ต้องแก้ ถ้า `queueName` ใหม่ขึ้นต้นด้วย `ses-` เหมือนเดิม เพราะ policy ใน
`deploy/iam/github-actions-deploy-policy.json` (Sid: `SqsQueues`) ครอบคลุม pattern `ses-*` อยู่แล้ว

ต้องแก้เฉพาะกรณี:
- เปลี่ยน prefix ชื่อ queue ไม่ใช้ `ses-` แล้ว → ต้องอัปเดต Resource ARN ใน policy
- เปลี่ยน region หรือ account ใหม่


## 4. ตรวจสอบผลลัพธ์

- ดู GitHub Actions job summary หลัง deploy เสร็จ จะมีตาราง list queue ทั้งหมดรวมโปรเจกต์ใหม่
- หรือรัน `deploy/scripts/verify.sh` เอง (ถ้ารัน local) เพื่อเช็คทุก component แบบละเอียด

## 5. ตั้งค่า SES ฝั่ง Sender (ถ้ายังไม่มี)

ตรวจสอบว่า sender email ที่ใส่ใน `mail.source` ของ filter policy:
- เป็น verified identity บน SES แล้ว
- มีการตั้งค่าให้ Bounce/Complaint notification ส่งไปที่ SNS topic `ses-reputation-alerts` (ผ่าน Configuration Set หรือ identity-level notification)

---

**สรุปสั้น**: แก้ `projects.json` (เพิ่ม object โปรเจกต์ใหม่) → อัปเดต Secret `PROJECTS_CONFIG` → push เข้า `main` หรือรัน workflow manual → ตรวจสอบผลผ่าน Actions summary


## Trigger deploy ครั้งแรก
 workflow จะรันตอนอัตโนมัตเมื่อ push code เข้า main (เฉพาะไฟล์ lambda/... หรือ deploy/**) หรือสามารถกด Actions → Deploy Lambda → Run workflow (workflow_dispatch) เพื่อรัน manual ได้



 delete SQS, SNS