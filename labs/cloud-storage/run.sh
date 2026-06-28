#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=$(gcloud config get-value compute/region 2>/dev/null || true)

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

BUCKET_NAME="${PROJECT_ID}-storage-lab"

echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME"
echo

echo "Enabling Cloud Storage API..."
gcloud services enable storage.googleapis.com --project="$PROJECT_ID" --quiet

echo "Creating fine-grained Cloud Storage bucket..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --no-uniform-bucket-level-access \
  --no-public-access-prevention \
  --quiet || true

export BUCKET_NAME_1="$BUCKET_NAME"

echo "Downloading sample Hadoop setup file..."
curl -fsSL \
  https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html \
  -o setup.html

cp setup.html setup2.html
cp setup.html setup3.html

echo "Uploading setup.html..."
gcloud storage cp setup.html "gs://${BUCKET_NAME_1}/"

echo "Saving original object IAM policy..."
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl.txt || true

echo "Setting setup.html private..."
gcloud storage objects update "gs://${BUCKET_NAME_1}/setup.html" \
  --predefined-acl=private

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl2.txt || true

echo "Making setup.html publicly readable..."
gcloud storage objects add-iam-policy-binding "gs://${BUCKET_NAME_1}/setup.html" \
  --member="allUsers" \
  --role="roles/storage.legacyObjectReader"

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl3.txt || true

echo "Testing delete and restore from bucket..."
rm -f setup.html
gcloud storage cp "gs://${BUCKET_NAME_1}/setup.html" setup.html

echo "Generating CSEK key..."
OLD_KEY=$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
)

echo "Configuring .boto with CSEK encryption key..."
gsutil config -n >/dev/null 2>&1 || true

cat >> ~/.boto <<EOF_BOTO

# GCloudOps CSEK Lab Keys
encryption_key=${OLD_KEY}
EOF_BOTO

echo "Uploading setup2.html and setup3.html with CSEK..."
gsutil kms encryption -d "gs://${BUCKET_NAME_1}" || true
gsutil cp setup2.html "gs://${BUCKET_NAME_1}/"
gsutil cp setup3.html "gs://${BUCKET_NAME_1}/"

echo "Testing encrypted object download..."
rm -f setup*
gsutil cp "gs://${BUCKET_NAME_1}/setup*" ./

echo "Rotating CSEK keys..."
NEW_KEY=$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
)

cp ~/.boto ~/.boto.gcloudops.backup

cat >> ~/.boto <<EOF_BOTO

# GCloudOps CSEK Rotation
decryption_key1=${OLD_KEY}
encryption_key=${NEW_KEY}
EOF_BOTO

echo "Rewriting setup2.html with new key..."
gsutil rewrite -k "gs://${BUCKET_NAME_1}/setup2.html"

echo "Removing old decryption key from active config for failure test..."
cp ~/.boto.gcloudops.backup ~/.boto

cat >> ~/.boto <<EOF_BOTO

# GCloudOps Active New CSEK Only
encryption_key=${NEW_KEY}
EOF_BOTO

echo "Downloading setup2.html with new key..."
gsutil cp "gs://${BUCKET_NAME_1}/setup2.html" recover2.html

echo "Attempting setup3.html download; expected to fail because it still uses old key..."
set +e
gsutil cp "gs://${BUCKET_NAME_1}/setup3.html" recover3.html
SETUP3_RESULT=$?
set -e

if [[ "$SETUP3_RESULT" -ne 0 ]]; then
  echo "Expected result: setup3.html failed because it was not rewritten with the new CSEK."
else
  echo "Warning: setup3.html downloaded successfully. Check CSEK behavior manually."
fi

echo "Creating lifecycle policy..."
cat > life.json <<'JSON'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 31}
    }
  ]
}
JSON

gcloud storage buckets update "gs://${BUCKET_NAME_1}" \
  --lifecycle-file=life.json

echo "Enabling versioning..."
gcloud storage buckets update "gs://${BUCKET_NAME_1}" --versioning

echo "Creating object versions..."
curl -fsSL \
  https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html \
  -o setup.html

gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

sed -i '1,5d' setup.html
gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

sed -i '1,5d' setup.html
gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

VERSION_NAME=$(gcloud storage ls -a "gs://${BUCKET_NAME_1}/setup.html" | head -n 1)

echo "Oldest version: $VERSION_NAME"

gcloud storage cp "$VERSION_NAME" recovered.txt

echo "Creating nested directory and syncing..."
mkdir -p firstlevel/secondlevel
cp setup.html firstlevel/
cp setup.html firstlevel/secondlevel/

gcloud storage rsync ./firstlevel "gs://${BUCKET_NAME_1}/firstlevel" --recursive

echo
echo "Automation complete."
echo "Bucket: gs://${BUCKET_NAME_1}"
echo
echo "Click Check my progress for each lab objective."
