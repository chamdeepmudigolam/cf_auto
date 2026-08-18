#!/bin/bash
##############################################################################
# stop-apps.sh — Stop non-prod CF apps at night
##############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/../reports"
LOG_DIR="${SCRIPT_DIR}/../logs"
mkdir -p "$REPORT_DIR" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [stop-apps] $1" | tee -a "$LOG_DIR/app-lifecycle.log"; }

REGIONS="${CF_REGIONS:-us10}"
NON_PROD="${NON_PROD_SPACES:-dev,staging,test,qa,uat,demo,sandbox}"
STATUS_FILE="${REPORT_DIR}/app-status.json"
STOPPED=0
FAILED=0
SKIPPED=0
PROD_SKIPPED=0

log "Stopping non-prod apps across regions: $REGIONS"
log "Non-prod space keywords: $NON_PROD"

is_non_prod_space() {
    local space_name="$1"
    local lower_name=$(echo "$space_name" | tr '[:upper:]' '[:lower:]')
    for keyword in $(echo "$NON_PROD" | tr ',' ' '); do
        keyword=$(echo "$keyword" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        if echo "$lower_name" | grep -qi "$keyword"; then
            return 0
        fi
    done
    return 1
}

for region in $(echo "$REGIONS" | tr ',' ' '); do
    region=$(echo "$region" | tr -d ' ')
    CF_API="https://api.cf.${region}.hana.ondemand.com"

    log "Region: $region ($CF_API)"

    if ! cf api "$CF_API" >/dev/null 2>&1; then
        log "  Cannot reach $CF_API — skipping"
        continue
    fi
    if ! cf auth "$BTP_USERNAME" "$BTP_PASSWORD" >/dev/null 2>&1; then
        log "  Auth failed for $region — skipping"
        continue
    fi

    # Get all apps with space info
    APPS_JSON=$(cf curl "/v3/apps?per_page=200" 2>/dev/null || echo '{"resources":[]}')
    APP_COUNT=$(echo "$APPS_JSON" | jq '.resources | length')

    log "  Found $APP_COUNT apps"

    for i in $(seq 0 $((APP_COUNT - 1))); do
        APP_NAME=$(echo "$APPS_JSON" | jq -r ".resources[$i].name")
        APP_GUID=$(echo "$APPS_JSON" | jq -r ".resources[$i].guid")
        APP_STATE=$(echo "$APPS_JSON" | jq -r ".resources[$i].state")
        SPACE_GUID=$(echo "$APPS_JSON" | jq -r ".resources[$i].relationships.space.data.guid")

        # Get space name
        SPACE_NAME=$(cf curl "/v3/spaces/${SPACE_GUID}" 2>/dev/null | jq -r '.name // "unknown"')

        # Skip the monitor app itself
        if [ "$APP_NAME" = "btp-quota-monitor" ]; then
            log "  Skipping self: $APP_NAME"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Only stop non-prod apps
        if is_non_prod_space "$SPACE_NAME"; then
            if [ "$APP_STATE" = "STARTED" ]; then
                log "  Stopping: $APP_NAME (space: $SPACE_NAME)"
                if cf curl -X POST "/v3/apps/${APP_GUID}/actions/stop" >/dev/null 2>&1; then
                    STOPPED=$((STOPPED + 1))
                    log "    Stopped successfully"
                else
                    FAILED=$((FAILED + 1))
                    log "    Failed to stop"
                fi
            else
                SKIPPED=$((SKIPPED + 1))
            fi
        else
            PROD_SKIPPED=$((PROD_SKIPPED + 1))
            log "  Skipping prod app: $APP_NAME (space: $SPACE_NAME)"
        fi
    done
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log "Complete: stopped=$STOPPED, failed=$FAILED, skipped=$SKIPPED, prod_protected=$PROD_SKIPPED"

# Write status
cat > "$STATUS_FILE" <<EOF
{
    "last_start": $([ -f "$STATUS_FILE" ] && jq -r '.last_start // "N/A"' "$STATUS_FILE" 2>/dev/null | jq -R . || echo '"N/A"'),
    "last_stop": "$TIMESTAMP",
    "stopped_count": $STOPPED,
    "failed_count": $FAILED,
    "skipped_count": $SKIPPED,
    "prod_protected": $PROD_SKIPPED,
    "action": "stop",
    "apps_running": "non-prod stopped"
}
EOF

log "Done."
