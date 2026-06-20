# BTP CF Quota Monitor

Automated monitoring of Cloud Foundry quota usage across **all subaccounts** in your SAP BTP global account. Sends a styled HTML email report every 7 days via SAP Alert Notification Service.

---

## What It Does

- Fetches **all subaccounts** from your BTP global account via Terraform
- Connects to CF API across **multiple regions** (ap11, br10, eu20, us20, us21)
- Collects quota for every CF org: **Memory, Service Instances, Routes** (total / used / remaining)
- **Deduplicates** shared orgs across subaccounts
- Sends a **styled HTML email** with summary table + detailed per-subaccount breakdown
- Flags resources running low with `!!` warnings
- Repeats automatically every 7 days

---

## Prerequisites

- SAP BTP global account with admin access
- SAP **Alert Notification Service (standard)** already provisioned in one subaccount with a **service key**
- SAP BAS dev space (Full Stack Cloud Application) — for local testing
- A CF space — for production deployment
- Git installed

---

## Quick Start

### Step 1 — Clone the repo

```bash
cd ~/projects
git clone https://github.com/YOUR_ORG/btp-cf-monitor.git
cd btp-cf-monitor
```

### Step 2 — Download binaries

```bash
mkdir -p bin

# Terraform
wget -q https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip
unzip -o terraform_1.7.5_linux_amd64.zip -d bin/
rm terraform_1.7.5_linux_amd64.zip

# jq
wget -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -O bin/jq

# Make executable
chmod +x bin/terraform bin/jq scripts/*.sh start.sh

# Verify
bin/terraform --version
bin/jq --version
```

### Step 3 — Get your ANS credentials

```bash
# Login to CF where your ANS instance lives
cf login -a https://api.cf.us10.hana.ondemand.com --sso

# Target the org/space with ANS
cf target -o YOUR_ORG -s YOUR_SPACE

# List service keys for your ANS instance
cf service-keys alert-notification

# View the key (use the key name from above)
cf service-key alert-notification YOUR_KEY_NAME
```

You will see JSON like this — note down the 4 values:

```json
{
  "url": "https://clm-sl-ans-live-ans-service-api.cfapps.us10.hana.ondemand.com",
  "client_id": "sb-5de9898a-...",
  "client_secret": "2202c933-...",
  "oauth_url": "https://yoursubdomain.authentication.us10.hana.ondemand.com/oauth/token..."
}
```

> **Important:** For `ans_uaa_url`, use only the base URL (without `/oauth/token?grant_type=...`).
> Example: `https://yoursubdomain.authentication.us10.hana.ondemand.com`

---

## Step 4 — Configure ANS Email Action (One-Time Setup)

Go to BTP Cockpit:

```
BTP Cockpit
  → Your ANS subaccount
  → Services → Instances and Subscriptions
  → Click on "alert-notification" instance
  → Click "Manage" (opens ANS dashboard)
```

### 4a. Create an Action

```
→ Actions tab → Create
  Name:        email-quota-report
  Type:        EMAIL
  Email:       your-email@company.com
  Use HTML:    ON  ← Toggle this ON
```

In the **Payload Template** field, paste this exactly (1015 chars):

```
<style>th{background:#07A;color:#fff;padding:5px}td{padding:5px;border-bottom:1px solid #ddd}table{width:100%;border-collapse:collapse}</style><b style="color:#07A;font-size:20px">{resource.tags.sa}</b> Subs <b style="color:#07A;font-size:20px">{resource.tags.oc}</b> Orgs <b style="color:red;font-size:20px">{resource.tags.wc}</b> Warn<table><tr><th>Org</th><th>Memory</th><th>Services</th><th>Routes</th></tr><tr><td>{resource.tags.o1}</td><td>{resource.tags.m1}</td><td>{resource.tags.s1}</td><td>{resource.tags.r1}</td></tr><tr><td>{resource.tags.o2}</td><td>{resource.tags.m2}</td><td>{resource.tags.s2}</td><td>{resource.tags.r2}</td></tr><tr><td>{resource.tags.o3}</td><td>{resource.tags.m3}</td><td>{resource.tags.s3}</td><td>{resource.tags.r3}</td></tr><tr><td>{resource.tags.o4}</td><td>{resource.tags.m4}</td><td>{resource.tags.s4}</td><td>{resource.tags.r4}</td></tr></table><pre style="font:11px monospace;background:#f5f5f5;padding:8px;white-space:pre-wrap">{body}</pre><small>{ans-disclaimer}</small>
```

Click **Save**.

### 4b. Create a Condition

```
→ Conditions tab → Create
  Name:        quota-report-events
  Condition:   eventType equals CF_QUOTA_REPORT
→ Save
```

### 4c. Create a Subscription

```
→ Subscriptions tab → Create
  Name:        weekly-quota-email
  Conditions:  quota-report-events
  Actions:     email-quota-report
  State:       ON
→ Save
```

---

## Step 5 — Run

Choose one of the two options below:

### Option A: Run locally in BAS (for testing)

```bash
cd ~/projects/btp-cf-monitor

# Create terraform.tfvars from example
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
vi terraform.tfvars
```

Fill in all values:

```hcl
global_account_subdomain = "your-global-account-subdomain"
btp_username             = "your@email.com"
btp_password             = "your-password"
notification_email       = "your@email.com"
cf_api_endpoint          = "https://api.cf.us10.hana.ondemand.com"
report_interval_days     = 7
ans_client_id            = "sb-xxxxx..."
ans_client_secret        = "xxxxx..."
ans_uaa_url              = "https://yoursubdomain.authentication.us10.hana.ondemand.com"
ans_api_url              = "https://clm-sl-ans-live-ans-service-api.cfapps.us10.hana.ondemand.com"
```

Then run:

```bash
export PATH=$PWD/bin:$PATH
terraform init
terraform apply
```

> **Note:** BAS dev spaces sleep after inactivity. The scheduler will stop when BAS sleeps. Use Option B for production.

### Option B: Deploy to CF (production — runs 24/7)

```bash
cd ~/projects/btp-cf-monitor

# Login to CF
cf login -a https://api.cf.us10.hana.ondemand.com --sso
cf target -o YOUR_ORG -s YOUR_SPACE

# Push the app (don't start yet)
cf push --no-start

# Set credentials securely via env vars
cf set-env btp-quota-monitor GLOBAL_ACCOUNT_SUBDOMAIN "your-global-account-subdomain"
cf set-env btp-quota-monitor BTP_USERNAME "your@email.com"
cf set-env btp-quota-monitor BTP_PASSWORD "your-password"
cf set-env btp-quota-monitor REPORT_EMAIL "your@email.com"
cf set-env btp-quota-monitor CF_API_ENDPOINT "https://api.cf.us10.hana.ondemand.com"
cf set-env btp-quota-monitor INTERVAL_DAYS "7"
cf set-env btp-quota-monitor ANS_CLIENT_ID 'sb-xxxxx...'
cf set-env btp-quota-monitor ANS_CLIENT_SECRET 'xxxxx...'
cf set-env btp-quota-monitor ANS_UAA_URL "https://yoursubdomain.authentication.us10.hana.ondemand.com"
cf set-env btp-quota-monitor ANS_API_URL "https://clm-sl-ans-live-ans-service-api.cfapps.us10.hana.ondemand.com"

# Start the app
cf start btp-quota-monitor

# Check logs
cf logs btp-quota-monitor --recent
```

---

## Step 6 — Verify

```bash
# Check app status
cf app btp-quota-monitor

# Watch logs
cf logs btp-quota-monitor --recent
```

You should see:

```
[startup] BTP CF Quota Monitor - CF App Starting
[startup] Terraform: Terraform v1.7.5
[startup] Running terraform apply...
[startup] Terraform apply complete.
[startup] Subaccounts: 21
[startup] Running first report...
[send] OAuth token acquired
[send] ANS HTTP: 202
[send] Event created: 3d212bc9-...
[send] Email to: your@email.com
[startup] Entering monitoring loop (every 604800s / 7 days)
```

Check your email inbox for the quota report.

---

## Day-to-Day Operations

```bash
# View recent logs
cf logs btp-quota-monitor --recent

# Force immediate report (restart triggers fresh run)
cf restart btp-quota-monitor

# Stop monitoring
cf stop btp-quota-monitor

# Start monitoring
cf start btp-quota-monitor

# Update code after git pull
git pull
cf push

# Change report interval to 14 days
cf set-env btp-quota-monitor INTERVAL_DAYS "14"
cf restart btp-quota-monitor

# Change email recipient
cf set-env btp-quota-monitor REPORT_EMAIL "new@email.com"
cf restart btp-quota-monitor

# Update password
cf set-env btp-quota-monitor BTP_PASSWORD "new-password"
cf restart btp-quota-monitor

# Delete app completely
cf delete btp-quota-monitor -f
```

---

## Adding More Email Recipients

Go to ANS dashboard:

```
→ Actions → Create
  Name:        email-quota-report-2
  Type:        EMAIL
  Email:       second.person@company.com
  Use HTML:    ON
  Payload Template:  (paste the same template from Step 4a)
→ Save

→ Subscriptions → weekly-quota-email → Edit
→ Add action: email-quota-report-2
→ Save
```

> **Note:** The new recipient will receive a **confirmation email** from SAP. They must click the confirmation link before reports will be delivered to them.

---

## File Structure

```
btp-cf-monitor/
├── manifest.yml               # CF deployment config
├── start.sh                   # CF app startup script
├── main.tf                    # Terraform: provider + subaccount discovery
├── variables.tf               # Terraform: input variables
├── outputs.tf                 # Terraform: output values
├── terraform.tfvars.example   # Template config (safe to commit)
├── terraform.tfvars           # Your actual config (NEVER commit)
├── .gitignore                 # Excludes secrets and state files
├── README.md                  # This file
├── bin/                       # Downloaded binaries (gitignored)
│   ├── terraform
│   └── jq
├── scripts/
│   ├── collect-cf-quota.sh    # Multi-region CF quota collector
│   ├── send-report.sh         # HTML report builder + ANS sender
│   └── scheduler.sh           # Start/stop/run-once controller
├── logs/                      # Runtime logs (gitignored)
└── reports/                   # Generated JSON reports (gitignored)
```

---

## Email Report Format

The email has two sections:

**Section 1 — Rendered HTML Table (org summary):**
- Stats bar: subaccount count, unique orgs, warning count
- HTML table with blue headers showing per-org quota (Memory, Services, Routes)
- Warning flags (`!!`) on low resources

**Section 2 — Detailed Breakdown (`<pre>` block):**
- Per-subaccount quota tables grouped by region
- ASCII usage bars showing consumption visually
- Warning summary

---

## How It Works

```
terraform apply / cf push
       │
       ├── Terraform fetches ALL subaccounts from BTP global account
       ├── Writes subaccounts.json (21 subaccounts across 5 regions)
       │
       ├── collect-cf-quota.sh runs:
       │     ├── Groups subaccounts by region
       │     ├── Logs into each region's CF API
       │     ├── Collects quota per org: memory, services, routes
       │     └── Outputs JSON report
       │
       ├── send-report.sh runs:
       │     ├── Deduplicates orgs (4 unique from 21 subaccounts)
       │     ├── Builds HTML table data as ANS resource tags
       │     ├── Builds detailed text report as event body
       │     ├── Gets OAuth token from ANS
       │     └── Sends event to ANS API (HTTP 202)
       │
       ├── ANS processes the event:
       │     ├── Matches condition: eventType = CF_QUOTA_REPORT
       │     ├── Renders Payload Template with tag values
       │     └── Sends HTML email to configured recipients
       │
       └── Scheduler sleeps 7 days, then repeats
```




