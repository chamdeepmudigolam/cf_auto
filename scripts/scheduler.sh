#!/bin/bash
##############################################################################
# scheduler.sh
# Controls the periodic quota collection + email cycle.
#
# Usage:
#   ./scheduler.sh start       — run first collection, then repeat every N days
#   ./scheduler.sh stop        — kill the running scheduler
#   ./scheduler.sh run-once    — collect + send one time, then exit
#
# Required env vars (passed by Terraform null_resource):
#   BTP_USERNAME, BTP_PASSWORD, ANS_CLIENT_ID, ANS_CLIENT_SECRET,
#   ANS_UAA_URL, ANS_API_URL, REPORT_EMAIL, INTERVAL_DAYS
##############################################################################

set -euo pipefail

ACTION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PID_FILE="${PROJECT_DIR}/scheduler.pid"
LOG_DIR="${PROJECT_DIR}/logs"
REPORT_DIR="${PROJECT_DIR}/reports"

mkdir -p "$LOG_DIR" "$REPORT_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $1" | tee -a "$LOG_DIR/scheduler.log"; }

# ---------- run one collection + send cycle ----------
run_cycle() {
  local report_file="${REPORT_DIR}/quota-report-$(date +%Y%m%d-%H%M%S).json"

  log "Starting quota collection..."
  if bash "${SCRIPT_DIR}/collect-cf-quota.sh" > "$report_file" 2>> "$LOG_DIR/collect.log"; then
    log "Collection complete. Report: $report_file"

    # Verify report is valid JSON
    if jq empty "$report_file" 2>/dev/null; then
      log "Sending report via ANS..."
      bash "${SCRIPT_DIR}/send-report.sh" "$report_file" 2>> "$LOG_DIR/send.log"
      log "Report sent successfully."
    else
      log "ERROR: Report is not valid JSON — skipping send"
    fi
  else
    log "ERROR: Collection script failed (exit $?)"
  fi

  # Clean up old reports (keep last 10)
  local count
  count=$(ls -1 "$REPORT_DIR"/quota-report-*.json 2>/dev/null | wc -l)
  if [ "$count" -gt 10 ]; then
    ls -1t "$REPORT_DIR"/quota-report-*.json | tail -n +11 | xargs rm -f
    log "Cleaned up old reports (kept last 10)"
  fi
}

# ---------- start ----------
do_start() {
  # Check if already running
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      log "Scheduler already running (PID $old_pid). Stop first."
      return 0
    else
      log "Stale PID file found. Cleaning up."
      rm -f "$PID_FILE"
    fi
  fi

  local interval_seconds=$(( ${INTERVAL_DAYS:-7} * 86400 ))
  log "Starting scheduler: every ${INTERVAL_DAYS:-7} days (${interval_seconds}s)"
  log "Report email: ${REPORT_EMAIL:-not set}"

  # Run first cycle immediately
  run_cycle

  # Background loop for subsequent cycles
  (
    while true; do
      log "Sleeping ${interval_seconds}s until next cycle..."
      sleep "$interval_seconds"

      # Check if we should still be running
      if [ ! -f "$PID_FILE" ]; then
        log "PID file removed — exiting scheduler loop"
        break
      fi

      run_cycle
    done
  ) >> "$LOG_DIR/scheduler.log" 2>&1 &

  local bg_pid=$!
  echo "$bg_pid" > "$PID_FILE"
  log "Scheduler started in background (PID $bg_pid)"
  log "To stop: ./scheduler.sh stop"
}

# ---------- stop ----------
do_stop() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      log "Scheduler stopped (PID $pid)"
    else
      log "Process $pid not running"
    fi
    rm -f "$PID_FILE"
  else
    log "No scheduler running (no PID file)"
  fi
}

# ---------- run once ----------
do_run_once() {
  log "Running single quota collection + send cycle"
  run_cycle
  log "Single cycle complete"
}

# ---------- main ----------
case "$ACTION" in
  start)    do_start ;;
  stop)     do_stop ;;
  run-once) do_run_once ;;
  *)
    echo "Usage: $0 {start|stop|run-once}"
    echo ""
    echo "  start     — run now, then repeat every INTERVAL_DAYS"
    echo "  stop      — stop the background scheduler"
    echo "  run-once  — collect and send one report, then exit"
    exit 1
    ;;
esac
