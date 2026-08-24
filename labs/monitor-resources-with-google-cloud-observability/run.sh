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

BASE_V1="https://monitoring.googleapis.com/v1/projects/${PROJECT_ID}"
BASE_V3="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

token() {
  gcloud auth print-access-token
}

api_get() {
  curl -fsS \
    -H "Authorization: Bearer $(token)" \
    "$1"
}

api_post() {
  curl -fsS \
    -X POST \
    -H "Authorization: Bearer $(token)" \
    -H "Content-Type: application/json" \
    -d @"$2" \
    "$1"
}

api_delete() {
  curl -fsS \
    -X DELETE \
    -H "Authorization: Bearer $(token)" \
    "$1"
}

echo
echo "============================================================"
echo " GCloudOps :: Cloud Observability"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Email:   $EMAIL"
echo

gcloud services enable monitoring.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# ============================================================
# TASK 1
# ============================================================

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
  echo "ERROR: Expected nginxstack-1, nginxstack-2 and nginxstack-3."
  exit 1
fi

# ============================================================
# TASK 2 - DASHBOARD
# ============================================================

echo
echo "[2/6] Creating My Dashboard..."

api_get "${BASE_V1}/dashboards" > /tmp/dashboards.json

python3 - <<'PY' >/tmp/dashboard-delete.txt
import json
with open("/tmp/dashboards.json") as f:
    data=json.load(f)
for d in data.get("dashboards", []):
    if d.get("displayName") == "My Dashboard":
        print(d["name"])
PY

while read -r NAME; do
  [[ -z "$NAME" ]] && continue
  api_delete "https://monitoring.googleapis.com/v1/${NAME}" >/dev/null
done < /tmp/dashboard-delete.txt

cat >/tmp/my-dashboard.json <<'JSON'
{
  "displayName": "My Dashboard",
  "dashboardFilters": [],
  "labels": {},
  "mosaicLayout": {
    "columns": 48,
    "tiles": [
      {
        "xPos": 0,
        "yPos": 0,
        "width": 24,
        "height": 16,
        "widget": {
          "title": "My Chart",
          "xyChart": {
            "chartOptions": {
              "mode": "COLOR"
            },
            "dataSets": [
              {
                "minAlignmentPeriod": "60s",
                "plotType": "LINE",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                  "apiSource": "DEFAULT_CLOUD",
                  "timeSeriesFilter": {
                    "aggregation": {
                      "alignmentPeriod": "60s",
                      "crossSeriesReducer": "REDUCE_NONE",
                      "groupByFields": [],
                      "perSeriesAligner": "ALIGN_MEAN"
                    },
                    "filter": "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\"",
                    "secondaryAggregation": {
                      "alignmentPeriod": "60s",
                      "crossSeriesReducer": "REDUCE_NONE",
                      "groupByFields": [],
                      "perSeriesAligner": "ALIGN_NONE"
                    }
                  },
                  "outputFullDuration": false
                }
              }
            ],
            "thresholds": [],
            "yAxis": {
              "label": "",
              "scale": "LINEAR"
            }
          }
        }
      }
    ]
  }
}
JSON

api_post "${BASE_V1}/dashboards" /tmp/my-dashboard.json \
  | tee /tmp/created-dashboard.json

echo
echo "[PASS] My Dashboard / My Chart created."
sleep 20

echo
echo "============================================================"
echo "TASK 2"
echo "Click Check my progress: Create custom dashboard"
echo "============================================================"
read -r -p "Press ENTER after Task 2 passes..." _ < /dev/tty

# ============================================================
# TASK 3 - NOTIFICATION CHANNEL
# ============================================================

echo
echo "[3/6] Creating notification channel..."

api_get "${BASE_V3}/notificationChannels" > /tmp/channels.json

CHANNEL_NAME="$(
python3 - "$EMAIL" <<'PY'
import json,sys
email=sys.argv[1]

with open("/tmp/channels.json") as f:
    data=json.load(f)

for c in data.get("notificationChannels", []):
    if (
        c.get("type") == "email"
        and c.get("labels", {}).get("email_address") == email
    ):
        print(c["name"])
        break
PY
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

  api_post "${BASE_V3}/notificationChannels" /tmp/channel.json \
    > /tmp/created-channel.json

  CHANNEL_NAME="$(
    python3 - <<'PY'
import json
with open("/tmp/created-channel.json") as f:
    print(json.load(f)["name"])
PY
  )"
fi

echo "Channel: $CHANNEL_NAME"

# ============================================================
# TASK 3 - ALERT POLICY
# ============================================================

echo
echo "Creating My Alert Policy..."

api_get "${BASE_V3}/alertPolicies" > /tmp/policies.json

python3 - <<'PY' >/tmp/policy-delete.txt
import json
with open("/tmp/policies.json") as f:
    data=json.load(f)
for p in data.get("alertPolicies", []):
    if p.get("displayName") == "My Alert Policy":
        print(p["name"])
PY

while read -r POLICY; do
  [[ -z "$POLICY" ]] && continue
  api_delete "https://monitoring.googleapis.com/v3/${POLICY}" >/dev/null
done < /tmp/policy-delete.txt

cat >/tmp/my-alert-policy.json <<EOF_JSON
{
  "displayName": "My Alert Policy",
  "combiner": "AND",
  "enabled": true,
  "notificationChannels": [
    "$CHANNEL_NAME"
  ],
  "conditions": [
    {
      "displayName": "VM Instance - CPU usage",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/usage_time\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    },
    {
      "displayName": "VM Instance - CPU utilization",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\"",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_MEAN"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "alertStrategy": {
    "autoClose": "604800s"
  }
}
EOF_JSON

api_post "${BASE_V3}/alertPolicies" /tmp/my-alert-policy.json \
  | tee /tmp/created-policy.json

ALERT_POLICY_NAME="$(
python3 - <<'PY'
import json
with open("/tmp/created-policy.json") as f:
    print(json.load(f)["name"])
PY
)"

sleep 20

echo
echo "============================================================"
echo "TASK 3"
echo "Click Check my progress: Create alerting policies"
echo "============================================================"
read -r -p "Press ENTER after Task 3 passes..." _ < /dev/tty

# ============================================================
# TASK 4 - RESOURCE GROUP
# ============================================================

echo
echo "[4/6] Creating VM instances group..."

api_get "${BASE_V3}/groups" > /tmp/groups.json

python3 - <<'PY' >/tmp/group-delete.txt
import json
with open("/tmp/groups.json") as f:
    data=json.load(f)
for g in data.get("group", data.get("groups", [])):
    if g.get("displayName") == "VM instances":
        print(g["name"])
PY

while read -r GROUP; do
  [[ -z "$GROUP" ]] && continue
  api_delete "https://monitoring.googleapis.com/v3/${GROUP}" >/dev/null
done < /tmp/group-delete.txt

cat >/tmp/vm-group.json <<'JSON'
{
  "displayName": "VM instances",
  "filter": "resource.metadata.name = has_substring(\"nginx\")"
}
JSON

api_post "${BASE_V3}/groups" /tmp/vm-group.json \
  | tee /tmp/created-group.json

GROUP_NAME="$(
python3 - <<'PY'
import json
with open("/tmp/created-group.json") as f:
    print(json.load(f)["name"])
PY
)"

GROUP_ID="${GROUP_NAME##*/}"

echo "Group: $GROUP_NAME"
sleep 20

echo
echo "============================================================"
echo "TASK 4"
echo "Click Check my progress: Create resource groups"
echo "============================================================"
read -r -p "Press ENTER after Task 4 passes..." _ < /dev/tty

# ============================================================
# TASK 5 - UPTIME CHECK
# ============================================================

echo
echo "[5/6] Creating My Uptime check..."

api_get "${BASE_V3}/uptimeCheckConfigs" > /tmp/uptimes.json

python3 - <<'PY' >/tmp/uptime-delete.txt
import json
with open("/tmp/uptimes.json") as f:
    data=json.load(f)
for u in data.get("uptimeCheckConfigs", []):
    if u.get("displayName") == "My Uptime check":
        print(u["name"])
PY

while read -r UPTIME; do
  [[ -z "$UPTIME" ]] && continue
  api_delete "https://monitoring.googleapis.com/v3/${UPTIME}" >/dev/null
done < /tmp/uptime-delete.txt

cat >/tmp/my-uptime.json <<EOF_JSON
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

api_post "${BASE_V3}/uptimeCheckConfigs" /tmp/my-uptime.json \
  | tee /tmp/created-uptime.json

UPTIME_NAME="$(
python3 - <<'PY'
import json
with open("/tmp/created-uptime.json") as f:
    print(json.load(f)["name"])
PY
)"

UPTIME_ID="${UPTIME_NAME##*/}"

echo "Uptime: $UPTIME_NAME"

# Attach notification policy to uptime check.

cat >/tmp/uptime-alert.json <<EOF_JSON
{
  "displayName": "My Uptime check alert",
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "$CHANNEL_NAME"
  ],
  "conditions": [
    {
      "displayName": "Failure of uptime check $UPTIME_ID",
      "conditionThreshold": {
        "filter": "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"$UPTIME_ID\" AND resource.type=\"gce_instance\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 1,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_NEXT_OLDER",
            "crossSeriesReducer": "REDUCE_COUNT_FALSE",
            "groupByFields": [
              "resource.label.*"
            ]
          }
        ],
        "trigger": {
          "count": 1
        }
      }
    }
  ]
}
EOF_JSON

api_post "${BASE_V3}/alertPolicies" /tmp/uptime-alert.json \
  > /tmp/uptime-alert-result.json || true

echo
echo "Waiting for uptime check activation..."
sleep 60

echo
echo "============================================================"
echo "TASK 5"
echo "Click Check my progress: Create uptime check"
echo "============================================================"
read -r -p "Press ENTER after Task 5 passes..." _ < /dev/tty

# ============================================================
# TASK 6 - DISABLE ALERT
# ============================================================

echo
echo "[6/6] Disabling My Alert Policy..."

cat >/tmp/disable-policy.json <<'JSON'
{
  "enabled": false
}
JSON

curl -fsS \
  -X PATCH \
  -H "Authorization: Bearer $(token)" \
  -H "Content-Type: application/json" \
  -d @/tmp/disable-policy.json \
  "https://monitoring.googleapis.com/v3/${ALERT_POLICY_NAME}?updateMask=enabled" \
  | tee /tmp/disabled-policy.json

echo
echo "============================================================"
echo " CBL012 AUTOMATION COMPLETE"
echo "============================================================"
echo "Dashboard:      My Dashboard"
echo "Chart:          My Chart"
echo "Alert:          My Alert Policy"
echo "Group:          VM instances"
echo "Uptime check:   My Uptime check"
echo "Alert enabled:  false"
echo "============================================================"
