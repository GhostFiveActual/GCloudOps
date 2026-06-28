#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

echo "Project: $PROJECT_ID"
echo

read -r -p "Paste Username 2 email from the lab panel: " USER2_EMAIL < /dev/tty

if [[ -z "$USER2_EMAIL" ]]; then
  echo "Username 2 email cannot be empty."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab region: " REGION < /dev/tty
fi

if [[ -z "$ZONE" ]]; then
  read -r -p "Paste lab zone: " ZONE < /dev/tty
fi

BUCKET_NAME="${PROJECT_ID}-gcloudops-iam"
SERVICE_ACCOUNT_NAME="read-bucket-objects"
SERVICE_ACCOUNT_EMAIL=$(gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --filter="email:${SERVICE_ACCOUNT_NAME}" \
  --format="value(email)" \
  --limit=1)

if [[ -z "$SERVICE_ACCOUNT_EMAIL" ]]; then
  echo "Could not find service account email."
  exit 1
fi

echo "Service account email: $SERVICE_ACCOUNT_EMAIL"

VM_NAME="demoiam"

echo
echo "Enabling APIs..."
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "Creating Cloud Storage bucket..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location=US \
  --uniform-bucket-level-access \
  --quiet || true

echo "Creating sample file..."
echo "Hello from GCloudOps IAM automation." > sample.txt

echo "Uploading sample.txt..."
gcloud storage cp sample.txt "gs://${BUCKET_NAME}/sample.txt"

echo
echo "Removing Username 2 project-level Viewer access..."
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
  --member="user:${USER2_EMAIL}" \
  --role="roles/viewer" \
  --quiet || true

echo
echo "Granting Username 2 Storage Object Viewer..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:${USER2_EMAIL}" \
  --role="roles/storage.objectViewer" \
  --quiet

echo
echo "Creating service account..."
gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
  --display-name="Read Bucket Objects" \
  --project="$PROJECT_ID" \
  --quiet || true

echo
echo "Granting service account Storage Object Viewer..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/storage.objectViewer" \
  --quiet

echo
echo "Granting altostrat.com Service Account User on service account..."
gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" \
  --member="domain:altostrat.com" \
  --role="roles/iam.serviceAccountUser" \
  --quiet || true

echo
echo "Granting altostrat.com Compute Instance Admin..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="domain:altostrat.com" \
  --role="roles/compute.instanceAdmin.v1" \
  --quiet || true

echo
echo "Creating VM with service account..."
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --service-account="$SERVICE_ACCOUNT_EMAIL" \
  --scopes=https://www.googleapis.com/auth/devstorage.read_write \
  --quiet || true

echo
echo "Testing read access from VM service account..."
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="gcloud storage cp gs://${BUCKET_NAME}/sample.txt . && ls -l sample.txt"

echo
echo "Testing write denial before role change..."
set +e
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="cp sample.txt sample2.txt && gcloud storage cp sample2.txt gs://${BUCKET_NAME}/sample2.txt"
WRITE_TEST_RESULT=$?
set -e

if [[ "$WRITE_TEST_RESULT" -ne 0 ]]; then
  echo "Expected result: write failed because service account only has Storage Object Viewer."
else
  echo "Warning: write succeeded earlier than expected."
fi

echo
echo "Changing service account role to Storage Object Creator..."
gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/storage.objectViewer" \
  --quiet || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/storage.objectCreator" \
  --quiet

echo
echo "Testing write access after role change..."
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="gcloud storage cp sample2.txt gs://${BUCKET_NAME}/sample2.txt"

echo
echo "Automation complete."
echo "Bucket: gs://${BUCKET_NAME}"
echo "VM: ${VM_NAME}"
echo "Service Account: ${SERVICE_ACCOUNT_EMAIL}"
echo
echo "Click Check my progress in the lab."
