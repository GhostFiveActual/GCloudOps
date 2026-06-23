#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
USER2_EMAIL="${1:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$USER2_EMAIL" ]]; then
  echo "Usage:"
  echo "curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/a-tour-of-google-cloud-hands-on-labs/run.sh | bash -s -- USER2_EMAIL"
  exit 1
fi

echo "Project: $PROJECT_ID"
echo "User 2: $USER2_EMAIL"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:$USER2_EMAIL" \
  --role="roles/viewer" \
  --quiet

gcloud services enable dialogflow.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo "Automation complete."
echo "Click Check my progress."
