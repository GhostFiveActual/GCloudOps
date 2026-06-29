#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

echo "Dashboards:"
gcloud monitoring dashboards list \
  --project="$PROJECT_ID" \
  --filter='displayName="My Dashboard"'

echo
echo "Notification channels:"
gcloud monitoring channels list \
  --project="$PROJECT_ID" \
  --filter='displayName="GCloudOps Email"'

echo
echo "Alert policies:"
gcloud alpha monitoring policies list \
  --project="$PROJECT_ID" \
  --filter='displayName="My Alert Policy"'

echo
echo "Groups:"
gcloud alpha monitoring groups list \
  --project="$PROJECT_ID" \
  --filter='displayName="VM instances"'

echo
echo "Uptime checks:"
gcloud monitoring uptime list \
  --project="$PROJECT_ID" \
  --filter='displayName="My Uptime check"'
