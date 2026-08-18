#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${APP_DIR}/logs"
mkdir -p "$LOG_DIR" "${APP_DIR}/reports"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [startup] $1" | tee -a "$LOG_DIR/startup.log"; }

log "================================================"
log "BTP CF Quota Monitor + Dashboard Starting"
log "================================================"

# Setup PATH
export PATH="${APP_DIR}/bin:${PATH}"
chmod +x "${APP_DIR}/bin/"* 2>/dev/null || true
chmod +x "${APP_DIR}/scripts/"* 2>/dev/null || true

log "Terraform: $(bin/terraform --version 2>/dev/null | head -1 || echo 'not found')"
log "jq: $(bin/jq --version 2>/dev/null || echo 'not found')"

# Install CF CLI if needed
if ! command -v cf &>/dev/null; then
    log "Installing CF CLI..."
    curl -sL "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github" -o /tmp/cf-cli.tgz
    tar -xzf /tmp/cf-cli.tgz -C "${APP_DIR}/bin/" cf8 2>/dev/null || tar -xzf /tmp/cf-cli.tgz -C "${APP_DIR}/bin/" cf
    [ -f "${APP_DIR}/bin/cf8" ] && [ ! -f "${APP_DIR}/bin/cf" ] && mv "${APP_DIR}/bin/cf8" "${APP_DIR}/bin/cf"
    chmod +x "${APP_DIR}/bin/cf"
    rm -f /tmp/cf-cli.tgz
fi
log "CF CLI: $(cf --version 2>/dev/null || echo 'not found')"

# Create terraform.tfvars from env
log "Creating terraform.tfvars..."
cat > "${APP_DIR}/terraform.tfvars" <<EOF
global_account_subdomain = "${GLOBAL_ACCOUNT_SUBDOMAIN}"
btp_username             = "${BTP_USERNAME}"
btp_password             = "${BTP_PASSWORD}"
notification_email       = "${REPORT_EMAIL}"
cf_api_endpoint          = "${CF_API_ENDPOINT}"
report_interval_days     = 1
ans_client_id            = "${ANS_CLIENT_ID}"
ans_client_secret        = "${ANS_CLIENT_SECRET}"
ans_uaa_url              = "${ANS_UAA_URL}"
ans_api_url              = "${ANS_API_URL}"
EOF

# Terraform init + apply
log "Running terraform init..."
cd "${APP_DIR}"
bin/terraform init -input=false 2>&1 | tee -a "$LOG_DIR/terraform.log"

log "Running terraform apply..."
bin/terraform apply -auto-approve -input=false 2>&1 | tee -a "$LOG_DIR/terraform.log"

log "Terraform complete. Subaccounts: $(bin/jq 'length' scripts/subaccounts.json 2>/dev/null || echo '?')"

# Export env vars for scripts
export BTP_USERNAME="${BTP_USERNAME}"
export BTP_PASSWORD="${BTP_PASSWORD}"
export ANS_CLIENT_ID="${ANS_CLIENT_ID}"
export ANS_CLIENT_SECRET="${ANS_CLIENT_SECRET}"
export ANS_UAA_URL="${ANS_UAA_URL}"
export ANS_API_URL="${ANS_API_URL}"
export REPORT_EMAIL="${REPORT_EMAIL}"
export CF_API_ENDPOINT="${CF_API_ENDPOINT}"
export CF_REGIONS="${CF_REGIONS}"
export NON_PROD_SPACES="${NON_PROD_SPACES}"

# Run first daily report immediately
log "Running first daily report..."
bash scripts/scheduler.sh run-once 2>&1 | tee -a "$LOG_DIR/scheduler.log" || true

log "Starting Flask dashboard + scheduler..."
log "================================================"

# Start Flask + APScheduler (serves dashboard + runs daily jobs)
PORT="${PORT:-8080}"
exec gunicorn dashboard:app --bind "0.0.0.0:${PORT}" --workers 1 --threads 2 --timeout 120
