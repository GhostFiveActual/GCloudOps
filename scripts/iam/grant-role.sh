#!/usr/bin/env bash

PROJECT_ID="$1"
USER="$2"
ROLE="$3"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:$USER" \
  --role="$ROLE"
