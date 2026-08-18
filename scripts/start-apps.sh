#!/bin/bash
##############################################################################
# start-apps.sh — Start all CF apps across all regions
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/../reports"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$REPORT_DIR" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [start-apps] $1" | tee -a "$LOG_DIR/app-lifecycle.log"; }

REGIONS="${CF_REGIONS:-us10}"
STATUS_FILE="${REPORT_DIR}/app-status.json"
STARTED=0
FAILED=0
SKIPPED=0

log "Starting apps across regions: $REGIONS"

for region in $(echo "$REGIONS" | tr ',' ' '); do
    region=$(echo "$region" | tr -d ' ')
    CF_API="https://api.cf.${region}.hana.ondemand.com"

    log "Region: $region ($CF_API)"

    # Login
    if ! cf api "$CF_API" >/dev/null 2>&1; then
        log "  Cannot reach $CF_API — skipping"
        continue
    fi
    if ! cf auth "$BTP_USERNAME" "$BTP_PASSWORD" >/dev/null 2>&1; then
        log "  Auth failed for $region — skipping"
        continue
    fi

    # Get all apps
    APPS_JSON=$(cf curl "/v3/apps?per_page=200" 2>/dev/null || echo '{"resources":[]}')
    APP_COUNT=$(echo "$APPS_JSON" | jq '.resources | length')

    log "  Found $APP_COUNT apps"

    for i in $(seq 0 $((APP_COUNT - 1))); do
        APP_NAME=$(echo "$APPS_JSON" | jq -r ".resources[$i].name")
        APP_GUID=$(echo "$APPS_JSON" | jq -r ".resources[$i].guid")
        APP_STATE=$(echo "$APPS_JSON" | jq -r ".resources[$i].state")

        if [ "$APP_STATE" = "STOPPED" ]; then
            log "  Starting: $APP_NAME ($APP_GUID)"
            if cf curl -X POST "/v3/apps/${APP_GUID}/actions/start" >/dev/null 2>&1; then
                STARTED=$((STARTED + 1))
                log "    Started successfully"
            else
                FAILED=$((FAILED + 1))
                log "    Failed to start"
            fi
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    done
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log "Complete: started=$STARTED, failed=$FAILED, already_running=$SKIPPED"

# Write status
cat > "$STATUS_FILE" <<EOF
{
    "last_start": "$TIMESTAMP",
    "last_stop": $([ -f "$STATUS_FILE" ] && jq -r '.last_stop // "N/A"' "$STATUS_FILE" 2>/dev/null | jq -R . || echo '"N/A"'),
    "started_count": $STARTED,
    "failed_count": $FAILED,
    "skipped_count": $SKIPPED,
    "action": "start",
    "apps_running": "yes"
}
EOF

log "Done."
