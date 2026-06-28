#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$ZONE" ]]; then
  read -r -p "Paste lab zone: " ZONE < /dev/tty
fi

BUCKET_NAME="${PROJECT_ID}-gcloudops-iam"
SERVICE_ACCOUNT_NAME="read-bucket-objects"
VM_NAME="demoiam"

SERVICE_ACCOUNT_EMAIL=$(gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --filter="email~${SERVICE_ACCOUNT_NAME}" \
  --format="value(email)" \
  --limit=1)

echo "Project: $PROJECT_ID"
echo "Zone: $ZONE"
echo

echo "Bucket objects:"
gcloud storage ls "gs://${BUCKET_NAME}" || true

echo
echo "Service account:"
if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
  gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
    --project="$PROJECT_ID" \
    --format="table(email,displayName)"
else
  echo "Service account not found."
fi

echo
echo "VM:"
gcloud compute instances describe "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="table(name,status,machineType.basename(),serviceAccounts[0].email)" || true

echo
echo "Relevant IAM bindings:"
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SERVICE_ACCOUNT_EMAIL} OR bindings.members:altostrat.com" \
  --format="table(bindings.role,bindings.members)" || true

echo
echo "Testing VM read access:"
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="gcloud storage ls gs://${BUCKET_NAME} && test -f sample.txt && echo sample.txt exists" || true

echo
echo "Verification complete."
