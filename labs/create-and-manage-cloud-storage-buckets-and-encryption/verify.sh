#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.gcloudops-cloud-storage-state"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
fi

if [[ -z "${BUCKET_NAME:-}" ]]; then
  BUCKET_NAME=$(gcloud storage buckets list \
    --project="$PROJECT_ID" \
    --format="value(name)" \
    | head -n 1)
fi

if [[ -z "${BUCKET_NAME:-}" ]]; then
  echo "No bucket found. Run run.sh first."
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "Bucket: gs://${BUCKET_NAME}"
echo

echo "Bucket:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" || true

echo
echo "Objects and versions:"
gcloud storage ls -a "gs://${BUCKET_NAME}" || true

echo
echo "setup.html IAM policy:"
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME}/setup.html" || true

echo
echo "Lifecycle:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(lifecycle_config)" || true

echo
echo "Versioning:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(versioning_enabled)" || true

echo
echo "Recursive sync:"
gcloud storage ls -r "gs://${BUCKET_NAME}/firstlevel" || true

echo
echo "Local files:"
ls -al setup.html recovered.txt recover2.html 2>/dev/null || true

echo
echo "Verification complete."
