#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
EMAIL="${EMAIL:-}"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

while [[ -z "$EMAIL" || ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; do
  read -r -p "Enter notification email: " EMAIL < /dev/tty
done

echo
echo "============================================================"
echo " GCloudOps :: Monitor Resources with Google Cloud Observability"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Email:   $EMAIL"
echo

gcloud services enable monitoring.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

refresh_token() {
  TOKEN="$(gcloud auth print-access-token)"
}

refresh_token

BASE="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

api_get() {
  refresh_token
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "$1"
}

api_post() {
  refresh_token
  curl -fsS \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$2" \
    "$1"
}

api_patch() {
  refresh_token
  curl -fsS \
    -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$2" \
    "$1"
}

echo
echo "[1/6] Verifying nginxstack VMs..."

gcloud compute instances list \
  --project="$PROJECT_ID" \
  --filter='name~"^nginxstack-[123]$"' \
  --format='table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'

VM_COUNT="$(
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter='name~"^nginxstack-[123]$"' \
    --format='value(name)' | wc -l
)"

if [[ "$VM_COUNT" -ne 3 ]]; then
  echo "ERROR: Expected exactly 3 nginxstack VMs."
  exit 1
fi

# ============================================================
# TASK 2
# ============================================================

echo
echo "[2/6] Creating exact lab dashboard..."

cat >/tmp/dashboard.json <<'JSON'
{
  "displayName": "My Dashboard",
  "mosaicLayout": {
    "columns": 12,
    "tiles": [
      {
        "xPos": 0,
        "yPos": 0,
        "width": 12,
        "height": 8,
        "widget": {
          "title": "My Chart",
          "xyChart": {
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\"",
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "perSeriesAligner": "ALIGN_MEAN",
                      "crossSeriesReducer": "REDUCE_NONE"
                    }
                  }
                },
                "plotType": "LINE",
                "targetAxis": "Y1"
              }
            ],
            "yAxis": {
              "label": "CPU utilization",
              "scale": "LINEAR"
            }
          }
        }
      }
    ]
  }
}
JSON

DASHBOARDS="$(api_get "${BASE}/dashboards")"

DASHBOARD_NAME="$(
  printf '%s' "$DASHBOARDS" |
  python3 -c '
import json,sys
data=json.load(sys.stdin)
for d in data.get("dashboards", []):
    if d.get("displayName") == "My Dashboard":
        print(d.get("name",""))
        break
'
)"

if [[ -z "$DASHBOARD_NAME" ]]; then
  DASHBOARD_JSON="$(api_post "${BASE}/dashboards" /tmp/dashboard.json)"

  DASHBOARD_NAME="$(
    printf '%s' "$DASHBOARD_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"
else
  echo "My Dashboard already exists."
fi

if [[ -z "$DASHBOARD_NAME" ]]; then
  echo "ERROR: Dashboard creation failed."
  exit 1
fi

echo "Dashboard: $DASHBOARD_NAME"

echo
echo "Verifying dashboard configuration..."

DASHBOARD_VERIFY="$(api_get "https://monitoring.googleapis.com/v1/${DASHBOARD_NAME}")"

printf '%s' "$DASHBOARD_VERIFY" |
python3 -c '
import json,sys

d=json.load(sys.stdin)

assert d.get("displayName") == "My Dashboard", "wrong dashboard name"

text=json.dumps(d)

assert "My Chart" in text, "My Chart missing"
assert "compute.googleapis.com/instance/cpu/utilization" in text, "CPU utilization metric missing"
assert "gce_instance" in text, "VM Instance resource missing"

print("[PASS] My Dashboard")
print("[PASS] My Chart")
print("[PASS] VM Instance CPU utilization")
'

echo
echo "Waiting 20 seconds for Monitoring grader propagation..."
sleep 20

echo
echo "============================================================"
echo "TASK 2 READY"
echo "Click Check my progress: Create custom dashboard"
echo "============================================================"
read -r -p "Press ENTER after Task 2 passes..." _ < /dev/tty

# ============================================================
# TASK 3 - NOTIFICATION CHANNEL
# ============================================================

echo
echo "[3/6] Creating email notification channel..."

CHANNELS="$(api_get "${BASE}/notificationChannels")"

CHANNEL_NAME="$(
  printf '%s' "$CHANNELS" |
  python3 -c '
import json,sys,os
email=os.environ["EMAIL"]
data=json.load(sys.stdin)

for ch in data.get("notificationChannels", []):
    if (
        ch.get("type") == "email"
        and ch.get("labels", {}).get("email_address") == email
    ):
        print(ch.get("name",""))
        break
'
)"

if [[ -z "$CHANNEL_NAME" ]]; then

  cat >/tmp/channel.json <<EOF_JSON
{
  "type": "email",
  "displayName": "GCloudOps Email",
  "labels": {
    "email_address": "$EMAIL"
  },
  "enabled": true
}
EOF_JSON

  CHANNEL_JSON="$(api_post "${BASE}/notificationChannels" /tmp/channel.json)"

  CHANNEL_NAME="$(
    printf '%s' "$CHANNEL_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"
fi

if [[ -z "$CHANNEL_NAME" ]]; then
  echo "ERROR: Notification channel creation failed."
  exit 1
fi

echo "Notification channel: $CHANNEL_NAME"

# ============================================================
# TASK 3 - ALERT POLICY
# ============================================================

echo
echo "Creating My Alert Policy..."

cat >/tmp/alert-policy.json <<EOF_JSON
{
  "displayName": "My Alert Policy",
  "combiner": "AND",
  "enabled": true,
  "notificationChannels": [
    "$CHANNEL_NAME"
  ],
  "conditions": [
    {
      "displayName": "VM Instance CPU usage",
      "conditionThreshold": {
        "filter": "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/usage_time\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ]
      }
    },
    {
      "displayName": "VM Instance CPU utilization",
      "conditionThreshold": {
        "filter": "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_MEAN"
          }
        ]
      }
    }
  ]
}
EOF_JSON

POLICIES="$(api_get "${BASE}/alertPolicies")"

ALERT_POLICY_NAME="$(
  printf '%s' "$POLICIES" |
  python3 -c '
import json,sys
data=json.load(sys.stdin)

for p in data.get("alertPolicies", []):
    if p.get("displayName") == "My Alert Policy":
        print(p.get("name",""))
        break
'
)"

if [[ -z "$ALERT_POLICY_NAME" ]]; then

  POLICY_JSON="$(api_post "${BASE}/alertPolicies" /tmp/alert-policy.json)"

  ALERT_POLICY_NAME="$(
    printf '%s' "$POLICY_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"
fi

if [[ -z "$ALERT_POLICY_NAME" ]]; then
  echo "ERROR: Alert policy creation failed."
  exit 1
fi

echo "Alert policy: $ALERT_POLICY_NAME"

sleep 10

echo
echo "============================================================"
echo "TASK 3 READY"
echo "Click Check my progress: Create alerting policies"
echo "============================================================"
read -r -p "Press ENTER after Task 3 passes..." _ < /dev/tty

# ============================================================
# TASK 4 - RESOURCE GROUP
# ============================================================

echo
echo "[4/6] Creating VM instances group..."

GROUPS="$(api_get "${BASE}/groups")"

GROUP_NAME="$(
  printf '%s' "$GROUPS" |
  python3 -c '
import json,sys
data=json.load(sys.stdin)

for g in data.get("group", data.get("groups", [])):
    if g.get("displayName") == "VM instances":
        print(g.get("name",""))
        break
'
)"

if [[ -z "$GROUP_NAME" ]]; then

  cat >/tmp/group.json <<'JSON'
{
  "displayName": "VM instances",
  "filter": "resource.metadata.name=has_substring(\"nginx\")"
}
JSON

  GROUP_JSON="$(api_post "${BASE}/groups" /tmp/group.json)"

  GROUP_NAME="$(
    printf '%s' "$GROUP_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"
fi

if [[ -z "$GROUP_NAME" ]]; then
  echo "ERROR: Monitoring group creation failed."
  exit 1
fi

GROUP_ID="${GROUP_NAME##*/}"

echo "Group: $GROUP_NAME"
echo "Group ID: $GROUP_ID"

sleep 10

echo
echo "============================================================"
echo "TASK 4 READY"
echo "Click Check my progress: Create resource groups"
echo "============================================================"
read -r -p "Press ENTER after Task 4 passes..." _ < /dev/tty

# ============================================================
# TASK 5 - UPTIME CHECK
# ============================================================

echo
echo "[5/6] Creating My Uptime check..."

UPTIMES="$(api_get "${BASE}/uptimeCheckConfigs")"

UPTIME_NAME="$(
  printf '%s' "$UPTIMES" |
  python3 -c '
import json,sys
data=json.load(sys.stdin)

for u in data.get("uptimeCheckConfigs", []):
    if u.get("displayName") == "My Uptime check":
        print(u.get("name",""))
        break
'
)"

if [[ -z "$UPTIME_NAME" ]]; then

  cat >/tmp/uptime.json <<EOF_JSON
{
  "displayName": "My Uptime check",
  "period": "60s",
  "timeout": "10s",
  "resourceGroup": {
    "groupId": "$GROUP_ID",
    "resourceType": "INSTANCE"
  },
  "httpCheck": {
    "requestMethod": "GET",
    "path": "/",
    "port": 80,
    "useSsl": false
  }
}
EOF_JSON

  UPTIME_JSON="$(api_post "${BASE}/uptimeCheckConfigs" /tmp/uptime.json)"

  UPTIME_NAME="$(
    printf '%s' "$UPTIME_JSON" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"
fi

if [[ -z "$UPTIME_NAME" ]]; then
  echo "ERROR: Uptime check creation failed."
  exit 1
fi

echo "Uptime check: $UPTIME_NAME"

echo
echo "Waiting 60 seconds for uptime check propagation..."
sleep 60

echo
echo "============================================================"
echo "TASK 5 READY"
echo "Click Check my progress: Create uptime check"
echo "============================================================"
read -r -p "Press ENTER after Task 5 passes..." _ < /dev/tty

# ============================================================
# TASK 6
# ============================================================

echo
echo "[6/6] Disabling My Alert Policy..."

cat >/tmp/disable.json <<'JSON'
{
  "enabled": false
}
JSON

api_patch \
  "https://monitoring.googleapis.com/v3/${ALERT_POLICY_NAME}?updateMask=enabled" \
  /tmp/disable.json >/dev/null

echo
echo "============================================================"
echo " CBL012 AUTOMATION COMPLETE"
echo "============================================================"
echo "Dashboard:      My Dashboard"
echo "Chart:          My Chart"
echo "Alert policy:   My Alert Policy"
echo "Group:          VM instances"
echo "Uptime check:   My Uptime check"
echo "Alert enabled:  false"
echo "============================================================"
