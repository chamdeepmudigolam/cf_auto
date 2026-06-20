#!/bin/bash
##############################################################################
# start.sh - CF App startup script
# 1. Sets up PATH with bundled binaries
# 2. Installs CF CLI
# 3. Runs terraform apply (fetches subaccounts)
# 4. Starts the 7-day scheduler
##############################################################################

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${APP_DIR}/logs"
mkdir -p "$LOG_DIR" "${APP_DIR}/reports"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [startup] $1" | tee -a "$LOG_DIR/startup.log"; }

log "================================================"
log "BTP CF Quota Monitor - CF App Starting"
log "================================================"

# ---------- 1. Setup PATH ----------
export PATH="${APP_DIR}/bin:${PATH}"
chmod +x "${APP_DIR}/bin/"* 2>/dev/null || true
chmod +x "${APP_DIR}/scripts/"* 2>/dev/null || true

log "Terraform: $(terraform --version | head -1)"
log "jq: $(jq --version)"

# ---------- 2. Install CF CLI ----------
log "Installing CF CLI..."
if ! command -v cf &>/dev/null; then
    CF_CLI_URL="https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github"
    curl -sL "$CF_CLI_URL" -o /tmp/cf-cli.tgz
    tar -xzf /tmp/cf-cli.tgz -C "${APP_DIR}/bin/" cf8 2>/dev/null || tar -xzf /tmp/cf-cli.tgz -C "${APP_DIR}/bin/" cf
    # Rename cf8 to cf if needed
    if [ -f "${APP_DIR}/bin/cf8" ] && [ ! -f "${APP_DIR}/bin/cf" ]; then
        mv "${APP_DIR}/bin/cf8" "${APP_DIR}/bin/cf"
    fi
    chmod +x "${APP_DIR}/bin/cf"
    rm -f /tmp/cf-cli.tgz
fi
log "CF CLI: $(cf --version)"

# ---------- 3. Create terraform.tfvars from env ----------
log "Creating terraform.tfvars from environment..."
cat > "${APP_DIR}/terraform.tfvars" <<EOF
global_account_subdomain = "${GLOBAL_ACCOUNT_SUBDOMAIN}"
btp_username             = "${BTP_USERNAME}"
btp_password             = "${BTP_PASSWORD}"
notification_email       = "${REPORT_EMAIL}"
cf_api_endpoint          = "${CF_API_ENDPOINT}"
report_interval_days     = ${INTERVAL_DAYS}
ans_client_id            = "${ANS_CLIENT_ID}"
ans_client_secret        = "${ANS_CLIENT_SECRET}"
ans_uaa_url              = "${ANS_UAA_URL}"
ans_api_url              = "${ANS_API_URL}"
EOF

# ---------- 4. Terraform init + apply ----------
log "Running terraform init..."
cd "${APP_DIR}"
terraform init -input=false 2>&1 | tee -a "$LOG_DIR/terraform.log"

log "Running terraform apply..."
terraform apply -auto-approve -input=false 2>&1 | tee -a "$LOG_DIR/terraform.log"

log "Terraform apply complete."
log "Subaccounts: $(jq 'length' scripts/subaccounts.json 2>/dev/null || echo 'unknown')"

# ---------- 5. Start scheduler (runs forever) ----------
log "Starting scheduler (interval: ${INTERVAL_DAYS} days)..."
log "================================================"

# Export all env vars needed by scripts
export BTP_USERNAME="${BTP_USERNAME}"
export BTP_PASSWORD="${BTP_PASSWORD}"
export ANS_CLIENT_ID="${ANS_CLIENT_ID}"
export ANS_CLIENT_SECRET="${ANS_CLIENT_SECRET}"
export ANS_UAA_URL="${ANS_UAA_URL}"
export ANS_API_URL="${ANS_API_URL}"
export REPORT_EMAIL="${REPORT_EMAIL}"
export INTERVAL_DAYS="${INTERVAL_DAYS}"
export CF_API_ENDPOINT="${CF_API_ENDPOINT}"

# Run first report immediately
log "Running first report..."
bash scripts/scheduler.sh run-once 2>&1 | tee -a "$LOG_DIR/scheduler.log"

# Start the loop (keeps CF app alive)
INTERVAL_SECONDS=$((INTERVAL_DAYS * 86400))
log "Entering monitoring loop (every ${INTERVAL_SECONDS}s / ${INTERVAL_DAYS} days)"

while true; do
    log "Sleeping ${INTERVAL_SECONDS}s until next report..."
    sleep "$INTERVAL_SECONDS"

    log "Running scheduled report..."
    bash scripts/scheduler.sh run-once 2>&1 | tee -a "$LOG_DIR/scheduler.log"

    log "Report cycle complete."
done