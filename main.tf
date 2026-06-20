##############################################################################
# BTP CF Quota Monitor — Global Account Level
# Uses existing ANS credentials (from CF service key or BTP binding)
##############################################################################

terraform {
  required_version = ">= 1.0"

  required_providers {
    btp = {
      source  = "SAP/btp"
      version = "~> 1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

# ---------- Provider ----------
provider "btp" {
  globalaccount = var.global_account_subdomain
  username      = var.btp_username
  password      = var.btp_password
}

# ---------- Data: list every subaccount ----------
data "btp_subaccounts" "all" {}

# ---------- Locals ----------
locals {
  active_subaccounts = [
    for sa in data.btp_subaccounts.all.values :
    {
      id     = sa.id
      name   = sa.name
      region = sa.region
    }
    if sa.state == "OK"
  ]
}

# ---------- Write subaccount list for scripts ----------
resource "local_file" "subaccount_list" {
  filename = "${path.module}/scripts/subaccounts.json"
  content  = jsonencode(local.active_subaccounts)
}

# ---------- Run initial quota collection + start scheduler ----------
resource "null_resource" "start_monitoring" {
  triggers = {
    subaccount_count = length(local.active_subaccounts)
  }

  provisioner "local-exec" {
    command     = "chmod +x scripts/*.sh && mkdir -p logs reports && bash scripts/scheduler.sh start 2>&1 | tee logs/terraform-apply.log"
    working_dir = path.module

    environment = {
      BTP_USERNAME      = var.btp_username
      BTP_PASSWORD      = var.btp_password
      CF_API_ENDPOINT   = var.cf_api_endpoint
      ANS_CLIENT_ID     = var.ans_client_id
      ANS_CLIENT_SECRET = var.ans_client_secret
      ANS_UAA_URL       = var.ans_uaa_url
      ANS_API_URL       = var.ans_api_url
      REPORT_EMAIL      = var.notification_email
      INTERVAL_DAYS     = tostring(var.report_interval_days)
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "bash scripts/scheduler.sh stop || true"
    working_dir = path.module
  }

  depends_on = [
    local_file.subaccount_list,
  ]
}