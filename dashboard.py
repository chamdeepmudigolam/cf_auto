"""
Flask dashboard + APScheduler for daily jobs.
Serves the quota dashboard on / and runs:
  - Morning: start apps (7 AM)
  - Daily: collect quota + send report (8 AM)
  - Nightly: stop non-prod apps (10 PM)
"""

import os
import json
import subprocess
import logging
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, render_template, jsonify
from apscheduler.schedulers.background import BackgroundScheduler

# ---------- Config ----------
APP_DIR = Path(__file__).parent.resolve()
REPORTS_DIR = APP_DIR / "reports"
LOGS_DIR = APP_DIR / "logs"
SCRIPTS_DIR = APP_DIR / "scripts"

STOP_HOUR = int(os.environ.get("STOP_APPS_HOUR", "22"))
START_HOUR = int(os.environ.get("START_APPS_HOUR", "7"))
REPORT_HOUR = int(os.environ.get("REPORT_HOUR", "8"))

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s: %(message)s")
log = logging.getLogger("monitor")

# ---------- Flask App ----------
app = Flask(__name__, template_folder=str(APP_DIR / "templates"))

def get_latest_report():
    """Read the latest report JSON"""
    try:
        reports = sorted(REPORTS_DIR.glob("quota-report-*.json"), reverse=True)
        if reports:
            with open(reports[0]) as f:
                data = json.load(f)
            data["_file"] = reports[0].name
            data["_timestamp"] = reports[0].stat().st_mtime
            return data
    except Exception as e:
        log.error(f"Error reading report: {e}")
    return None

def get_app_status():
    """Read the latest app lifecycle status"""
    status_file = REPORTS_DIR / "app-status.json"
    try:
        if status_file.exists():
            with open(status_file) as f:
                return json.load(f)
    except Exception as e:
        log.error(f"Error reading app status: {e}")
    return {"last_start": "N/A", "last_stop": "N/A", "apps_running": "unknown"}

@app.route("/")
def index():
    report = get_latest_report()
    app_status = get_app_status()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    if report:
        # Deduplicate orgs
        orgs = {}
        no_cf = []
        warnings = []

        for sa in report.get("subaccounts", []):
            if sa["status"] in ("no_cf_orgs", "cf_unreachable") or not sa.get("orgs"):
                no_cf.append(sa)
                continue
            for org in sa["orgs"]:
                guid = org["org_guid"]
                if guid not in orgs:
                    orgs[guid] = {"org": org, "region": sa["region"], "subs": []}
                orgs[guid]["subs"].append(sa["subaccount_name"])

                mem = org["memory"]
                si = org["service_instances"]
                rt = org["routes"]
                if mem["remaining_mb"] >= 0 and mem["remaining_mb"] < 1024:
                    warnings.append(f'{org["org_name"]}: Memory {mem["remaining_mb"]}MB left')
                if si["remaining"] >= 0 and si["remaining"] < 50:
                    warnings.append(f'{org["org_name"]}: SI {si["remaining"]} left')
                if rt["remaining"] >= 0 and rt["remaining"] < 20:
                    warnings.append(f'{org["org_name"]}: Routes {rt["remaining"]} left')

        warnings = list(dict.fromkeys(warnings))

        return render_template("dashboard.html",
            report=report,
            orgs=orgs,
            no_cf=no_cf,
            warnings=warnings,
            app_status=app_status,
            now=now,
            report_file=report.get("_file", ""),
            schedule={
                "start_hour": START_HOUR,
                "report_hour": REPORT_HOUR,
                "stop_hour": STOP_HOUR
            }
        )
    else:
        return render_template("dashboard.html",
            report=None, orgs={}, no_cf=[], warnings=[],
            app_status=app_status, now=now, report_file="",
            schedule={"start_hour": START_HOUR, "report_hour": REPORT_HOUR, "stop_hour": STOP_HOUR}
        )

@app.route("/health")
def health():
    return jsonify({"status": "ok", "time": datetime.now(timezone.utc).isoformat()})

@app.route("/api/report")
def api_report():
    report = get_latest_report()
    if report:
        return jsonify(report)
    return jsonify({"error": "no report available"}), 404

@app.route("/api/status")
def api_status():
    return jsonify(get_app_status())

# ---------- Scheduled Jobs ----------
def run_script(script_name, desc):
    """Run a bash script and log output"""
    script_path = SCRIPTS_DIR / script_name
    log.info(f"Running {desc}: {script_path}")
    try:
        result = subprocess.run(
            ["bash", str(script_path)],
            capture_output=True, text=True, timeout=300,
            cwd=str(APP_DIR),
            env={**os.environ, "PATH": f"{APP_DIR}/bin:{os.environ.get('PATH', '')}"}
        )
        if result.returncode == 0:
            log.info(f"{desc} completed successfully")
        else:
            log.error(f"{desc} failed (exit {result.returncode}): {result.stderr[:500]}")

        # Write log
        log_file = LOGS_DIR / f"{script_name.replace('.sh', '')}.log"
        with open(log_file, "a") as f:
            f.write(f"\n[{datetime.now()}] {'OK' if result.returncode == 0 else 'FAIL'}\n")
            if result.stdout:
                f.write(result.stdout[-2000:])
            if result.stderr:
                f.write(result.stderr[-1000:])
    except subprocess.TimeoutExpired:
        log.error(f"{desc} timed out after 300s")
    except Exception as e:
        log.error(f"{desc} error: {e}")

def job_daily_report():
    """Daily quota collection + send report via ANS"""
    log.info("=== DAILY REPORT JOB ===")
    run_script("scheduler.sh run-once", "Daily quota report")

def job_start_apps():
    """Morning: start all CF apps"""
    log.info("=== MORNING APP START JOB ===")
    run_script("start-apps.sh", "Start apps")

def job_stop_apps():
    """Night: stop non-prod CF apps"""
    log.info("=== NIGHTLY APP STOP JOB ===")
    run_script("stop-apps.sh", "Stop apps")

# ---------- Start Scheduler ----------
scheduler = BackgroundScheduler(timezone="UTC")
scheduler.add_job(job_start_apps, "cron", hour=START_HOUR, minute=0, id="start_apps")
scheduler.add_job(job_daily_report, "cron", hour=REPORT_HOUR, minute=0, id="daily_report")
scheduler.add_job(job_stop_apps, "cron", hour=STOP_HOUR, minute=0, id="stop_apps")
scheduler.start()

log.info(f"Scheduler started: start={START_HOUR}:00, report={REPORT_HOUR}:00, stop={STOP_HOUR}:00 UTC")
