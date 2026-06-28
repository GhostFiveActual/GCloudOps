# Exploring IAM

## Purpose

This lab tests Google Cloud IAM permissions, Cloud Storage access, service accounts, and Compute Engine service account behavior.

## What This Automation Does

The script automates the lab flow by:

- Detecting the active Qwiklabs project
- Prompting for Username 2
- Creating a Cloud Storage bucket
- Uploading `sample.txt`
- Removing Username 2 project-level Viewer access
- Granting Username 2 Storage Object Viewer
- Creating the `read-bucket-objects` service account
- Granting the service account Storage Object Viewer
- Granting `altostrat.com` Service Account User
- Granting `altostrat.com` Compute Instance Admin
- Creating the `demoiam` VM
- Testing read access from the VM
- Testing expected write failure
- Updating service account permissions to Storage Object Creator
- Testing successful write access

## Run from Cloud Shell

```bash
curl -fsSL https://raw.githubusercontent.com/GhostFiveActual/GCloudOps/master/labs/exploring-iam/run.sh | bash
