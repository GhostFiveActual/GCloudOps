#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)

if [[ -z "$ZONE" ]]; then
  read -r -p "Paste lab zone: " ZONE < /dev/tty
fi

BUCKET_NAME="${PROJECT_ID}-gcloudops-iam"
SERVICE_ACCOUNT_EMAIL="read-bucket-objects@${PROJECT_ID}.iam.gserviceaccount.com"
VM_NAME="demoiam"

echo "Project: $PROJECT_ID"
echo

echo "Bucket objects:"
gcloud storage ls "gs://${BUCKET_NAME}" || true

echo
echo "Service account:"
gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" \
  --format="table(email,displayName)" || true

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
