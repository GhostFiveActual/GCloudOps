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

  if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Invalid email. Try again."
  fi
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

TOKEN="$(gcloud auth print-access-token)"
MONITORING_V3="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

api_post() {
  local url="$1"
  local body="$2"

  curl -fsS \
    -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$body" \
    "$url"
}

api_patch() {
  local url="$1"
  local body="$2"

  curl -fsS \
    -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$body" \
    "$url"
}

echo
echo "[1/6] Verifying nginxstack VMs..."

VM_COUNT="$(
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter='name~"^nginxstack-[123]$"' \
    --format='value(name)' \
    | wc -l
)"

gcloud compute instances list \
  --project="$PROJECT_ID" \
  --filter='name~"^nginxstack-[123]$"' \
  --format='table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)'

if [[ "$VM_COUNT" -lt 3 ]]; then
  echo "ERROR: Expected nginxstack-1, nginxstack-2, nginxstack-3."
  exit 1
fi

# ============================================================
# TASK 2 - DASHBOARD
# ============================================================

echo
echo "[2/6] Creating My Dashboard / My Chart..."

cat > /tmp/dashboard.json <<'JSON'
{
  "displayName": "My Dashboard",
  "gridLayout": {
    "columns": "1",
    "widgets": [
      {
        "title": "My Chart",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN"
                  }
                }
              },
              "plotType": "LINE"
            }
          ],
          "yAxis": {
            "label": "CPU utilization",
            "scale": "LINEAR"
          }
        }
      }
    ]
  }
}
JSON

EXISTING_DASHBOARD="$(
  gcloud monitoring dashboards list \
    --project="$PROJECT_ID" \
    --format='value(name,displayName)' \
    2>/dev/null \
    | awk '$2=="My Dashboard"{print $1; exit}'
)"

if [[ -z "$EXISTING_DASHBOARD" ]]; then
  gcloud monitoring dashboards create \
    --project="$PROJECT_ID" \
    --config-from-file=/tmp/dashboard.json
else
  echo "My Dashboard already exists: $EXISTING_DASHBOARD"
fi

echo
echo "============================================================"
echo "TASK 2 COMPLETE"
echo "Click Check my progress: Create custom dashboard"
echo "============================================================"
read -r -p "Press ENTER after the checkpoint passes..." _ < /dev/tty

# ============================================================
# NOTIFICATION CHANNEL
# ============================================================

echo
echo "[3/6] Creating notification channel..."

CHANNEL_RESPONSE="$(
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MONITORING_V3}/notificationChannels"
)"

CHANNEL_NAME="$(
  printf '%s' "$CHANNEL_RESPONSE" | python3 - "$EMAIL" <<'PY'
import json, sys

email = sys.argv[1]
data = json.load(sys.stdin)

for ch in data.get("notificationChannels", []):
    if ch.get("type") == "email" and ch.get("labels", {}).get("email_address") == email:
        print(ch.get("name", ""))
        break
PY
)"

if [[ -z "$CHANNEL_NAME" ]]; then

  cat > /tmp/channel.json <<EOF_JSON
{
  "type": "email",
  "displayName": "GCloudOps Email",
  "labels": {
    "email_address": "$EMAIL"
  },
  "enabled": true
}
EOF_JSON

  CHANNEL_NAME="$(
    api_post "${MONITORING_V3}/notificationChannels" /tmp/channel.json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
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

cat > /tmp/alert-policy.json <<EOF_JSON
{
  "displayName": "My Alert Policy",
  "combiner": "AND",
  "enabled": true,
  "notificationChannels": [
    "$CHANNEL_NAME"
  ],
  "conditions": [
    {
      "displayName": "CPU usage above 20",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/usage_time\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 20,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_RATE"
          }
        ],
        "trigger": {
          "count": 1
        }
      }
    },
    {
      "displayName": "CPU utilization above 20 percent",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0.2,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_MEAN"
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

POLICIES="$(
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MONITORING_V3}/alertPolicies"
)"

ALERT_POLICY_NAME="$(
  printf '%s' "$POLICIES" | python3 <<'PY'
import json, sys

data = json.load(sys.stdin)

for p in data.get("alertPolicies", []):
    if p.get("displayName") == "My Alert Policy":
        print(p.get("name", ""))
        break
PY
)"

if [[ -z "$ALERT_POLICY_NAME" ]]; then

  ALERT_POLICY_NAME="$(
    api_post "${MONITORING_V3}/alertPolicies" /tmp/alert-policy.json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"

else
  echo "My Alert Policy already exists."
fi

if [[ -z "$ALERT_POLICY_NAME" ]]; then
  echo "ERROR: Alert policy creation failed."
  exit 1
fi

echo "Alert policy: $ALERT_POLICY_NAME"

echo
echo "============================================================"
echo "TASK 3 COMPLETE"
echo "Click Check my progress: Create alerting policies"
echo "============================================================"
read -r -p "Press ENTER after the checkpoint passes..." _ < /dev/tty

# ============================================================
# TASK 4 - GROUP
# ============================================================

echo
echo "[4/6] Creating VM instances resource group..."

GROUPS="$(
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MONITORING_V3}/groups"
)"

GROUP_NAME="$(
  printf '%s' "$GROUPS" | python3 <<'PY'
import json, sys

data = json.load(sys.stdin)

for g in data.get("group", data.get("groups", [])):
    if g.get("displayName") == "VM instances":
        print(g.get("name", ""))
        break
PY
)"

if [[ -z "$GROUP_NAME" ]]; then

  cat > /tmp/group.json <<'JSON'
{
  "displayName": "VM instances",
  "filter": "resource.metadata.name=has_substring(\"nginx\")"
}
JSON

  GROUP_NAME="$(
    api_post "${MONITORING_V3}/groups" /tmp/group.json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"

fi

if [[ -z "$GROUP_NAME" ]]; then
  echo "ERROR: Resource group creation failed."
  exit 1
fi

GROUP_ID="${GROUP_NAME##*/}"

echo "Group:    $GROUP_NAME"
echo "Group ID: $GROUP_ID"

echo
echo "============================================================"
echo "TASK 4 COMPLETE"
echo "Click Check my progress: Create resource groups"
echo "============================================================"
read -r -p "Press ENTER after the checkpoint passes..." _ < /dev/tty

# ============================================================
# TASK 5 - UPTIME CHECK
# ============================================================

echo
echo "[5/6] Creating My Uptime check..."

UPTIME_LIST="$(
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MONITORING_V3}/uptimeCheckConfigs"
)"

UPTIME_NAME="$(
  printf '%s' "$UPTIME_LIST" | python3 <<'PY'
import json, sys

data = json.load(sys.stdin)

for u in data.get("uptimeCheckConfigs", []):
    if u.get("displayName") == "My Uptime check":
        print(u.get("name", ""))
        break
PY
)"

if [[ -z "$UPTIME_NAME" ]]; then

  cat > /tmp/uptime.json <<EOF_JSON
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

  UPTIME_NAME="$(
    api_post "${MONITORING_V3}/uptimeCheckConfigs" /tmp/uptime.json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
  )"

fi

if [[ -z "$UPTIME_NAME" ]]; then
  echo "ERROR: Uptime check creation failed."
  exit 1
fi

UPTIME_ID="${UPTIME_NAME##*/}"

echo "Uptime check: $UPTIME_NAME"

echo
echo "Creating notification policy for uptime check..."

cat > /tmp/uptime-policy.json <<EOF_JSON
{
  "displayName": "My Uptime check alert",
  "combiner": "OR",
  "enabled": true,
  "notificationChannels": [
    "$CHANNEL_NAME"
  ],
  "conditions": [
    {
      "displayName": "My Uptime check failed",
      "conditionThreshold": {
        "filter": "resource.type = \"gce_instance\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"$UPTIME_ID\"",
        "comparison": "COMPARISON_LT",
        "thresholdValue": 1,
        "duration": "60s",
        "aggregations": [
          {
            "alignmentPeriod": "60s",
            "perSeriesAligner": "ALIGN_NEXT_OLDER"
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

UPTIME_POLICY_NAME="$(
  api_post "${MONITORING_V3}/alertPolicies" /tmp/uptime-policy.json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))'
)" || true

echo
echo "Uptime check created."
echo "Wait about 60-90 seconds for Monitoring to evaluate it."

sleep 60

echo
echo "============================================================"
echo "TASK 5 COMPLETE"
echo "Click Check my progress: Create uptime check"
echo "============================================================"
read -r -p "Press ENTER after the checkpoint passes..." _ < /dev/tty

# ============================================================
# TASK 6 - DISABLE MY ALERT POLICY
# ============================================================

echo
echo "[6/6] Disabling My Alert Policy..."

cat > /tmp/disable-alert.json <<'JSON'
{
  "enabled": false
}
JSON

api_patch \
  "https://monitoring.googleapis.com/v3/${ALERT_POLICY_NAME}?updateMask=enabled" \
  /tmp/disable-alert.json \
  >/tmp/disabled-policy.json

echo
echo "============================================================"
echo " CBL012 AUTOMATION COMPLETE"
echo "============================================================"
echo
echo "Dashboard:            My Dashboard"
echo "Chart:                My Chart"
echo "Alert policy:         My Alert Policy"
echo "Resource group:       VM instances"
echo "Uptime check:         My Uptime check"
echo "Notification channel: $EMAIL"
echo "Alert status:         Disabled"
echo
