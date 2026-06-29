#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.gcloudops-cloud-sql-state"

if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
else
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  INSTANCE_NAME="wordpress-db"
  DATABASE_NAME="wordpress"
  PROXY_VM="wordpress-proxy"
  PRIVATE_VM="wordpress-private-ip"
  ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
fi

echo "Project: $PROJECT_ID"
echo "Cloud SQL instance: $INSTANCE_NAME"
echo

echo "Cloud SQL:"
gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --format="table(name,state,region,databaseVersion,settings.tier,ipAddresses.ipAddress,ipAddresses.type)" || true

echo
echo "Databases:"
gcloud sql databases list \
  --instance="$INSTANCE_NAME" \
  --project="$PROJECT_ID" || true

echo
echo "Connection name:"
gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --format="value(connectionName)" || true

echo
echo "Private IP:"
gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --format="value(ipAddresses.filter(type=PRIVATE).ipAddress)" || true

echo
echo "VMs:"
gcloud compute instances list \
  --project="$PROJECT_ID" \
  --filter="name:($PROXY_VM OR $PRIVATE_VM)" \
  --format="table(name,zone.basename(),status,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)" || true

echo
echo "Proxy process on wordpress-proxy:"
if [[ -n "${ZONE:-}" ]]; then
  gcloud compute ssh "$PROXY_VM" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --quiet \
    --command="pgrep -af cloud_sql_proxy || true; ss -ltnp | grep 3306 || true" || true
else
  echo "Zone unknown. Skipping SSH proxy check."
fi

echo
echo "Verification complete."
