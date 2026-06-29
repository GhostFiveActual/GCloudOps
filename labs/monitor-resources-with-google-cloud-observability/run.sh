#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
EMAIL="${EMAIL:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active project."
  exit 1
fi

if [[ -z "$EMAIL" ]]; then
  read -r -p "Enter notification email: " EMAIL < /dev/tty
fi

TOKEN=$(gcloud auth print-access-token)
BASE="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

api_post() {
  local url="$1"
  local file="$2"
  curl -sS -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$file" \
    "$url"
}

echo "Project: $PROJECT_ID"
echo "Email: $EMAIL"

gcloud services enable monitoring.googleapis.com --project="$PROJECT_ID" --quiet

echo
echo "VMs:"
gcloud compute instances list \
  --filter="name~nginxstack" \
  --format="table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)"

echo
echo "Creating dashboard..."

cat > dashboard.json <<'JSON'
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

gcloud monitoring dashboards create \
  --project="$PROJECT_ID" \
  --config-from-file=dashboard.json || true

echo
echo "CHECKPOINT: Click Check my progress for custom dashboard."
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "Creating notification channel..."

cat > channel.json <<EOF_JSON
{
  "type": "email",
  "displayName": "GCloudOps Email",
  "labels": {
    "email_address": "$EMAIL"
  },
  "enabled": true
}
EOF_JSON

CHANNEL_NAME=$(api_post "${BASE}/notificationChannels" channel.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')

if [[ -z "$CHANNEL_NAME" ]]; then
  echo "Failed to create notification channel."
  exit 1
fi

echo "Channel: $CHANNEL_NAME"

echo
echo "Creating alert policy..."

cat > alert-policy.json <<EOF_JSON
{
  "displayName": "My Alert Policy",
  "combiner": "AND",
  "enabled": true,
  "notificationChannels": ["$CHANNEL_NAME"],
  "conditions": [
    {
      "displayName": "VM CPU usage above threshold",
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
      "displayName": "VM CPU utilization above threshold",
      "conditionThreshold": {
        "filter": "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0.2,
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

api_post "${BASE}/alertPolicies" alert-policy.json >/tmp/gcloudops-alert.json
cat /tmp/gcloudops-alert.json

echo
echo "CHECKPOINT: Click Check my progress for alerting policies."
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "Creating resource group..."

cat > group.json <<'JSON'
{
  "displayName": "VM instances",
  "filter": "resource.metadata.name=monitoring.regex.full_match(\".*nginx.*\")"
}
JSON

GROUP_NAME=$(api_post "${BASE}/groups" group.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')

if [[ -z "$GROUP_NAME" ]]; then
  echo "Failed to create group."
  exit 1
fi

GROUP_ID="${GROUP_NAME##*/}"
echo "Group: $GROUP_NAME"
echo "Group ID: $GROUP_ID"

echo
echo "CHECKPOINT: Click Check my progress for resource groups."
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "Creating uptime check..."

cat > uptime.json <<EOF_JSON
{
  "displayName": "My Uptime check",
  "period": "60s",
  "timeout": "10s",
  "resourceGroup": {
    "groupId": "$GROUP_ID",
    "resourceType": "INSTANCE"
  },
  "httpCheck": {
    "path": "/",
    "port": 80,
    "useSsl": false,
    "requestMethod": "GET"
  }
}
EOF_JSON

api_post "${BASE}/uptimeCheckConfigs" uptime.json >/tmp/gcloudops-uptime.json
cat /tmp/gcloudops-uptime.json

echo
echo "CHECKPOINT: Wait 1-2 minutes, then click Check my progress for uptime check."
read -r -p "Press ENTER to disable alert policy..." _ < /dev/tty

POLICY_NAME=$(python3 -c 'import json; print(json.load(open("/tmp/gcloudops-alert.json")).get("name",""))')

if [[ -n "$POLICY_NAME" ]]; then
  cat > disable-alert.json <<EOF_JSON
{
  "enabled": false
}
EOF_JSON

  curl -sS -X PATCH \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @disable-alert.json \
    "https://monitoring.googleapis.com/v3/${POLICY_NAME}?updateMask=enabled" >/tmp/gcloudops-alert-disabled.json

  echo "Alert disabled."
fi

echo
echo "Automation complete."
