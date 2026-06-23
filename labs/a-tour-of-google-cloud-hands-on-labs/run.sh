#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
USER2_EMAIL="${1:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$USER2_EMAIL" ]]; then
  read -p "Paste User 2 email from the lab panel: " USER2_EMAIL
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
echo "Run verification or click Check my progress."