# A Tour of Google Cloud Hands-on Labs

## Purpose

This lab introduces the Google Cloud Console, projects, IAM roles, and API enablement.

## What This Automation Does

The `run.sh` script automates the CLI-based portions of the lab:

- Detects the active Google Cloud project
- Grants the Viewer role to the lab-provided User 2 account
- Enables the Dialogflow API
- Prints completion status

## Tested Automation

The following automation was tested successfully in Google Cloud Shell:

- `gcloud config get-value project`
- `gcloud projects add-iam-policy-binding`
- `gcloud services enable`
- `gcloud services list`
- `gcloud projects get-iam-policy`

## Run with Curl

```bash
curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/a-tour-of-google-cloud-hands-on-labs/run.sh | bash