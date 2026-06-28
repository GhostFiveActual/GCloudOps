#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
BUCKET_NAME="${PROJECT_ID}-storage-lab"

echo "Project: $PROJECT_ID"
echo "Bucket: gs://${BUCKET_NAME}"
echo

echo "Bucket details:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="table(name,location,uniform_bucket_level_access,public_access_prevention)"

echo
echo "Objects:"
gcloud storage ls -a "gs://${BUCKET_NAME}"

echo
echo "setup.html IAM policy:"
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME}/setup.html" || true

echo
echo "Lifecycle:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(lifecycle_config)"

echo
echo "Versioning:"
gcloud storage buckets describe "gs://${BUCKET_NAME}" \
  --format="json(versioning_enabled)"

echo
echo "Recursive sync check:"
gcloud storage ls -r "gs://${BUCKET_NAME}/firstlevel" || true

echo
echo "Verification complete."
