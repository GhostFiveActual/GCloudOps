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

echo "Project: $PROJECT_ID"
echo "Email: $EMAIL"

gcloud services enable monitoring.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "Verifying nginx VMs..."
gcloud compute instances list \
  --filter="name~nginxstack" \
  --format="table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)"

echo
echo "Creating dashboard..."
cat > dashboard.json <<'JSON'
{
  "displayName": "My Dashboard",
  "gridLayout": {
    "widgets": [
      {
        "title": "My Chart",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\"",
                  "aggregation": {
                    "alignmentPeriod": "60s",
                    "perSeriesAligner": "ALIGN_MEAN"
                  }
                }
              },
              "plotType": "LINE"
            }
          ],
          "timeshiftDuration": "0s",
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
echo "Creating email notification channel..."
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

CHANNEL_NAME=$(gcloud monitoring channels create \
  --project="$PROJECT_ID" \
  --channel-content-from-file=channel.json \
  --format="value(name)" 2>/dev/null || true)

if [[ -z "$CHANNEL_NAME" ]]; then
  CHANNEL_NAME=$(gcloud monitoring channels list \
    --project="$PROJECT_ID" \
    --filter='displayName="GCloudOps Email"' \
    --format="value(name)" \
    --limit=1)
fi

echo "Channel: $CHANNEL_NAME"

echo
echo "Creating alerting policy..."
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
        ],
        "trigger": {
          "count": 1
        }
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
        ],
        "trigger": {
          "count": 1
        }
      }
    }
  ]
}
EOF_JSON

gcloud alpha monitoring policies create \
  --project="$PROJECT_ID" \
  --policy-from-file=alert-policy.json || true

echo
echo "Creating Monitoring group..."
cat > group.json <<'JSON'
{
  "displayName": "VM instances",
  "filter": "resource.metadata.name=monitoring.regex.full_match(\".*nginx.*\")"
}
JSON

GROUP_NAME=$(gcloud alpha monitoring groups create \
  --project="$PROJECT_ID" \
  --group-content-from-file=group.json \
  --format="value(name)" 2>/dev/null || true)

if [[ -z "$GROUP_NAME" ]]; then
  GROUP_NAME=$(gcloud alpha monitoring groups list \
    --project="$PROJECT_ID" \
    --filter='displayName="VM instances"' \
    --format="value(name)" \
    --limit=1)
fi

echo "Group: $GROUP_NAME"

echo
echo "Creating uptime check..."
cat > uptime-check.json <<EOF_JSON
{
  "displayName": "My Uptime check",
  "timeout": "10s",
  "period": "60s",
  "monitoredResource": {
    "type": "uptime_url",
    "labels": {
      "project_id": "$PROJECT_ID",
      "host": "example.com"
    }
  },
  "httpCheck": {
    "path": "/",
    "port": 80,
    "useSsl": false,
    "requestMethod": "GET"
  }
}
EOF_JSON

gcloud monitoring uptime create \
  --project="$PROJECT_ID" \
  --config-from-file=uptime-check.json || true

echo
echo "Automation complete."
echo "Click all Check my progress buttons."
