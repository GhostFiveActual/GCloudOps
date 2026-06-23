#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

echo "Project: $PROJECT_ID"

echo
echo "Dialogflow API:"
gcloud services list \
  --enabled \
  --project="$PROJECT_ID" \
  --filter="dialogflow.googleapis.com" \
  --format="table(config.name,state)"

echo
echo "Viewer IAM bindings:"
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/viewer" \
  --format="table(bindings.role,bindings.members)"
