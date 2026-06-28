#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.gcloudops-cloud-storage-state"

if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
else
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  BUCKET_NAME=$(gcloud storage buckets list \
    --project="$PROJECT_ID" \
    --format="value(name)" \
    --limit=1)
fi

if [[ -z "${PROJECT_ID:-}" || -z "${BUCKET_NAME:-}" ]]; then
  echo "Could not determine project or bucket."
  echo "Run the lab automation first."
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "Bucket: gs://${BUCKET_NAME}"
echo

echo "Bucket details:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" || true

echo
echo "Objects and versions:"
gcloud storage ls -a "gs://${BUCKET_NAME}" || true

echo
echo "setup.html IAM policy:"
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME}/setup.html" || true

echo
echo "Lifecycle config:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(lifecycle_config)" || true

echo
echo "Versioning:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(versioning_enabled)" || true

echo
echo "Recursive sync check:"
gcloud storage ls -r "gs://${BUCKET_NAME}/firstlevel" || true

echo
echo "Local recovery files:"
ls -al setup.html recovered.txt recover2.html 2>/dev/null || true

echo
echo "Verification complete."
