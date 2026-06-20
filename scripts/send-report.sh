#!/bin/bash
##############################################################################
# send-report.sh
# HTML org summary table + detailed subaccount breakdown in <pre> body.
##############################################################################

set -euo pipefail

REPORT_FILE="${1:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [send] $1" >&2; }
die() { log "ERROR: $1"; exit 1; }

[ -n "$REPORT_FILE" ]           || die "Usage: $0 <report.json>"
[ -f "$REPORT_FILE" ]           || die "Report file not found: $REPORT_FILE"
[ -n "${ANS_CLIENT_ID:-}" ]     || die "ANS_CLIENT_ID not set"
[ -n "${ANS_CLIENT_SECRET:-}" ] || die "ANS_CLIENT_SECRET not set"
[ -n "${ANS_UAA_URL:-}" ]       || die "ANS_UAA_URL not set"
[ -n "${ANS_API_URL:-}" ]       || die "ANS_API_URL not set"
[ -n "${REPORT_EMAIL:-}" ]      || die "REPORT_EMAIL not set"

log "Report file = $REPORT_FILE ($(wc -c < "$REPORT_FILE") bytes)"

# ---------- OAuth ----------
log "Requesting OAuth token..."
TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${ANS_UAA_URL}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${ANS_CLIENT_ID}:${ANS_CLIENT_SECRET}" \
  -d "grant_type=client_credentials" 2>&1) || die "curl to UAA failed"

TOKEN_HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

if [ "$TOKEN_HTTP_CODE" != "200" ]; then
  die "OAuth failed (HTTP $TOKEN_HTTP_CODE): $TOKEN_BODY"
fi

TOKEN=$(echo "$TOKEN_BODY" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "Empty access_token"
log "OAuth token acquired"

# ---------- Build event ----------
EVENT_JSON=$(python3 - "$REPORT_FILE" "$REPORT_EMAIL" <<'PYEOF'
import json, sys, time

with open(sys.argv[1]) as f:
    report = json.load(f)

generated_at = report["generated_at"]
total_sa = report["total_subaccounts"]

# Deduplicate orgs for HTML table
orgs_map = {}
no_cf = []
warnings = []

for sa in report["subaccounts"]:
    if sa["status"] in ("no_cf_orgs", "cf_unreachable") or not sa["orgs"]:
        no_cf.append(sa)
        continue
    for org in sa["orgs"]:
        guid = org["org_guid"]
        if guid not in orgs_map:
            orgs_map[guid] = {"org": org, "region": sa["region"], "subs": []}
        orgs_map[guid]["subs"].append(sa["subaccount_name"])

        mem = org["memory"]
        si = org["service_instances"]
        rt = org["routes"]
        if mem["remaining_mb"] >= 0 and mem["remaining_mb"] < 1024:
            w = f'{org["org_name"]}: Memory {mem["remaining_mb"]}MB left'
            if w not in warnings: warnings.append(w)
        if si["remaining"] >= 0 and si["remaining"] < 50:
            w = f'{org["org_name"]}: SI {si["remaining"]} left'
            if w not in warnings: warnings.append(w)
        if rt["remaining"] >= 0 and rt["remaining"] < 20:
            w = f'{org["org_name"]}: Routes {rt["remaining"]} left'
            if w not in warnings: warnings.append(w)

orgs_list = list(orgs_map.values())

# --- Tags for HTML table (org summary) ---
def fmt_quota_short(total, used, remaining, low_thresh):
    if remaining == -1:
        return f"{used:,} / Unlim"
    pct = int(used * 100 / total) if total > 0 else 0
    flag = " !!" if remaining < low_thresh else ""
    return f"{used:,} / {total:,} ({remaining:,} left){flag}"

tags = {
    "ans:detailsLink": "https://cockpit.btp.cloud.sap",
    "reportType": "weekly_quota",
    "sa": str(total_sa),
    "oc": str(len(orgs_list)),
    "wc": str(len(warnings))
}

for i in range(4):
    idx = i + 1
    if i < len(orgs_list):
        data = orgs_list[i]
        org = data["org"]
        subs = sorted(set(data["subs"]))
        mem = org["memory"]
        si = org["service_instances"]
        rt = org["routes"]
        tags[f"o{idx}"] = f'{org["org_name"]} ({data["region"]}, {len(subs)} subs)'
        tags[f"m{idx}"] = fmt_quota_short(mem["total_mb"], mem["used_mb"], mem["remaining_mb"], 1024)
        tags[f"s{idx}"] = fmt_quota_short(si["total"], si["used"], si["remaining"], 50)
        tags[f"r{idx}"] = fmt_quota_short(rt["total"], rt["used"], rt["remaining"], 20)
    else:
        for k in [f"o{idx}", f"m{idx}", f"s{idx}", f"r{idx}"]:
            tags[k] = "-"

# --- Body: detailed per-subaccount breakdown ---
out = []
p = out.append

p(f"Report: {generated_at}")
p("")

if warnings:
    p("!! WARNINGS:")
    for w in warnings:
        p(f"   >> {w}")
    p("")

p("+" + "=" * 68 + "+")
p("|  DETAILED QUOTA BY SUBACCOUNT                                      |")
p("+" + "=" * 68 + "+")

# Group subaccounts by region
regions = {}
for sa in report["subaccounts"]:
    r = sa["region"]
    if r not in regions:
        regions[r] = []
    regions[r].append(sa)

for region in sorted(regions.keys()):
    sa_list = regions[region]
    p("")
    p(f"+--- Region: {region} " + "-" * (55 - len(region)) + "+")
    p("")

    for sa in sa_list:
        sa_name = sa["subaccount_name"]
        sa_id = sa["subaccount_id"][:8] + "..."
        status = sa["status"]

        p(f"  {sa_name}")
        p(f"  ID: {sa_id}")

        if status in ("no_cf_orgs", "cf_unreachable"):
            p(f"  Status: No CF environment")
            p("")
            continue

        for org in sa["orgs"]:
            mem = org["memory"]
            si = org["service_instances"]
            rt = org["routes"]

            p(f"  Org: {org['org_name']}")
            p(f"  +--------------------+----------+----------+--------+-------+")
            p(f"  | Resource           |    Total |     Used |   Left | Usage |")
            p(f"  +--------------------+----------+----------+--------+-------+")

            for label, total, used, rem, low_t in [
                ("Memory (MB)", mem["total_mb"], mem["used_mb"], mem["remaining_mb"], 1024),
                ("Service Inst", si["total"], si["used"], si["remaining"], 50),
                ("Routes", rt["total"], rt["used"], rt["remaining"], 20),
            ]:
                if rem == -1:
                    p(f"  | {label:<18} | {'Unlim':>8} | {used:>8,} | {'Unlim':>6} |    -- |")
                else:
                    pct = int(used * 100 / total) if total > 0 else 0
                    flag = "!!" if rem < low_t else "  "
                    p(f"  | {label:<18} | {total:>8,} | {used:>8,} | {rem:>6,} | {pct:>3}%{flag}|")

            p(f"  +--------------------+----------+----------+--------+-------+")

            # Usage bars
            for label, total, used, rem, low_t in [
                ("Mem", mem["total_mb"], mem["used_mb"], mem["remaining_mb"], 1024),
                ("SI", si["total"], si["used"], si["remaining"], 50),
                ("Rts", rt["total"], rt["used"], rt["remaining"], 20),
            ]:
                if rem == -1:
                    p(f"  {label:<4} [....................] Unlimited")
                else:
                    pct = int(used * 100 / total) if total > 0 else 0
                    f = min(pct * 20 // 100, 20)
                    bar = "#" * f + "." * (20 - f)
                    mk = "!!" if rem < low_t else "ok"
                    p(f"  {label:<4} [{bar}] {pct:>3}% {mk}")

        p("")

# No CF subaccounts
if no_cf:
    p("+" + "-" * 68 + "+")
    p(f"|  WITHOUT CF ENVIRONMENT ({len(no_cf)})" + " " * (43 - len(str(len(no_cf)))) + "|")
    p("+" + "-" * 68 + "+")
    for sa in no_cf:
        p(f"  - {sa['subaccount_name']} ({sa['region']})")
    p("")

# Footer
p("+" + "=" * 68 + "+")
if warnings:
    p(f"|  !! {len(warnings)} WARNING(S) - see !! marks above" + " " * (35 - len(str(len(warnings)))) + "|")
else:
    p("|  All resources within normal limits.                                |")
p("+" + "=" * 68 + "+")

body_text = "\n".join(out)

# --- Build event ---
event = {
    "eventType": "CF_QUOTA_REPORT",
    "eventTimestamp": int(time.time()),
    "severity": "WARNING" if warnings else "INFO",
    "category": "NOTIFICATION",
    "subject": f"BTP CF Quota Report - {generated_at}",
    "body": body_text,
    "resource": {
        "resourceName": "cf-quota-monitor",
        "resourceType": "monitoring",
        "tags": tags
    }
}

print(json.dumps(event))
PYEOF
)

log "Event JSON built"

# ---------- Send ----------
SEVERITY=$(echo "$EVENT_JSON" | jq -r '.severity')
log "Sending to ANS (severity: $SEVERITY)..."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "${ANS_API_URL}/cf/producer/v1/resource-events" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$EVENT_JSON" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

log "ANS HTTP: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  EVENT_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null || echo "")
  log "Event created: ${EVENT_ID:-accepted}"
  log "Email to: $REPORT_EMAIL"
else
  log "Response: $RESPONSE_BODY"
  die "ANS failed (HTTP $HTTP_CODE)"
fi

log "Done."