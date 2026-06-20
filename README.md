# BTP CF Quota Monitor

Automated monitoring of Cloud Foundry quota usage across **all subaccounts** in your SAP BTP global account. Sends a styled HTML email report every 7 days via SAP Alert Notification Service.

## What It Does

```
terraform apply
    │
    ├── Fetches ALL subaccounts from global account (21 found for your account)
    ├── Looks up your EXISTING ANS instance + binding (no new instance created)
    ├── Groups subaccounts by region (us20, us21, eu20, ap11, br10)
    │
    ├── Per region: logs into CF API, collects quota for every org:
    │     • Memory: total / used / remaining (MB)
    │     • Service Instances: total / used / remaining
    │     • Routes: total / used / remaining
    │
    ├── Builds styled HTML email with color-coded warnings
    ├── Sends via ANS → email arrives in your inbox
    └── Scheduler repeats every 7 days in background
```

## Prerequisites

- SAP BTP global account admin access
- **Alert Notification Service (standard)** already provisioned in one subaccount
  with at least one **service binding** created
- SAP BAS dev space (Full Stack Cloud Application)
- CF CLI (pre-installed in BAS)

## Setup in BAS

### 1. Install Terraform (if not already)

```bash
wget -q https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip
unzip -o terraform_1.7.5_linux_amd64.zip
mkdir -p $HOME/bin && mv terraform $HOME/bin/
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
terraform --version
```

### 2. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
global_account_subdomain = "thomsonreuterstaxaccountingincformerlysabrixinc-07"
btp_username             = "your@email.com"
btp_password             = "your-password"
ans_subaccount_id        = "guid-of-subaccount-with-ans"
ans_instance_name        = "name-of-your-ans-instance"   # ← as shown in BTP Cockpit
notification_email       = "team@company.com"
report_interval_days     = 7
```

### 3. Find your ANS instance name

Go to **BTP Cockpit → your ANS subaccount → Services → Instances and Subscriptions**.
The "Name" column shows the instance name. Copy it exactly into `ans_instance_name`.

### 4. Run

```bash
chmod +x scripts/*.sh
terraform init
terraform plan      # preview
terraform apply     # deploy + send first report
```

## Stopping

```bash
./scripts/scheduler.sh stop
# or
terraform destroy
```

## Logs

```bash
tail -f logs/scheduler.log
tail -f logs/collect.log
tail -f logs/send.log
```

## File Structure

```
btp-cf-monitor/
├── main.tf                      # Provider, data sources, scheduler trigger
├── variables.tf                 # Input variables
├── outputs.tf                   # Output values
├── terraform.tfvars.example     # Template (safe to commit)
├── .gitignore                   # Excludes secrets
└── scripts/
    ├── collect-cf-quota.sh      # Multi-region CF quota collector
    ├── send-report.sh           # HTML builder + ANS sender
    └── scheduler.sh             # Start/stop/run-once controller
```

## Notes

- **Multi-region**: Auto-detects CF API per region (us20, us21, eu20, ap11, br10)
- **BAS sleep**: Dev spaces sleep after inactivity. For production, run via CI/CD.
- **No CAP app needed**: Entirely script-based.
- **No Terraform license needed**: Terraform CLI is free.
