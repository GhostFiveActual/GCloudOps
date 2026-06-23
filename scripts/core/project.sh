#!/usr/bin/env bash

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

if [[ -z "$PROJECT_ID" ]]; then
    echo "No active Google Cloud project found."
    exit 1
fi

export PROJECT_ID

