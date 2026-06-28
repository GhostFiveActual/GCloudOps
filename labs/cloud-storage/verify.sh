#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

BUCKET_NAME=$(gcloud storage buckets list \
  --project="$PROJECT_ID" \
  --format="value(name)" \
  --filter="name:${PROJECT_ID}-storage-lab" \
  --limit=1)

if [[ -z "$BUCKET_NAME" ]]; then
  echo "No GCloudOps storage lab bucket found."
  echo
  echo "Existing buckets:"
  gcloud storage buckets list --project="$PROJECT_ID"
  echo
  echo "Run:"
  echo "curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/cloud-storage/run.sh | bash"
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "Bucket: gs://${BUCKET_NAME}"
echo

gcloud storage buckets describe "gs://${BUCKET_NAME}"
echo
gcloud storage ls -a "gs://${BUCKET_NAME}"
