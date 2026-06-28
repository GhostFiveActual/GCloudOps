#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="${REGION:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

BUCKET_NAME="storecore-${PROJECT_ID##*-}"
STATE_FILE="$HOME/.gcloudops-cloud-storage-state"
BOTO_FILE="$HOME/.boto"

echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME"
echo

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
REGION=$REGION
BUCKET_NAME=$BUCKET_NAME
STATE

gcloud services enable storage.googleapis.com --project="$PROJECT_ID" --quiet

gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --no-uniform-bucket-level-access \
  --no-public-access-prevention \
  --quiet || true

export BUCKET_NAME_1="$BUCKET_NAME"

curl -fsSL \
  https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html \
  -o setup.html

cp setup.html setup2.html
cp setup.html setup3.html

gcloud storage cp setup.html "gs://${BUCKET_NAME_1}/"

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl.txt || true

gcloud storage objects update "gs://${BUCKET_NAME_1}/setup.html" \
  --predefined-acl=private

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl2.txt || true

gcloud storage objects add-iam-policy-binding "gs://${BUCKET_NAME_1}/setup.html" \
  --member="allUsers" \
  --role="roles/storage.legacyObjectReader"

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl3.txt || true

rm -f setup.html
gcloud storage cp "gs://${BUCKET_NAME_1}/setup.html" setup.html

OLD_KEY=$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
)

NEW_KEY=$(python3 - <<'PY'
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
)

cat >> "$STATE_FILE" <<STATE
OLD_KEY=$OLD_KEY
NEW_KEY=$NEW_KEY
STATE

cp "$BOTO_FILE" "$HOME/.boto.gcloudops.original" 2>/dev/null || true

cat > "$BOTO_FILE" <<EOF_BOTO
[GSUtil]
default_project_id = ${PROJECT_ID}
encryption_key = ${OLD_KEY}
EOF_BOTO

gsutil kms encryption -d "gs://${BUCKET_NAME_1}" || true
gsutil cp setup2.html "gs://${BUCKET_NAME_1}/"
gsutil cp setup3.html "gs://${BUCKET_NAME_1}/"

rm -f setup*
gsutil cp "gs://${BUCKET_NAME_1}/setup*" ./

cat > "$BOTO_FILE" <<EOF_BOTO
[GSUtil]
default_project_id = ${PROJECT_ID}
decryption_key1 = ${OLD_KEY}
encryption_key = ${NEW_KEY}
EOF_BOTO

gsutil rewrite -k "gs://${BUCKET_NAME_1}/setup2.html"

cat > "$BOTO_FILE" <<EOF_BOTO
[GSUtil]
default_project_id = ${PROJECT_ID}
encryption_key = ${NEW_KEY}
EOF_BOTO

gsutil cp "gs://${BUCKET_NAME_1}/setup2.html" recover2.html

set +e
gsutil cp "gs://${BUCKET_NAME_1}/setup3.html" recover3.html
SETUP3_RESULT=$?
set -e

if [[ "$SETUP3_RESULT" -ne 0 ]]; then
  echo "Expected: setup3.html failed because it was not rewritten with the new key."
fi

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

gcloud storage buckets update "gs://${BUCKET_NAME_1}" --versioning

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

mkdir -p firstlevel/secondlevel
cp setup.html firstlevel/
cp setup.html firstlevel/secondlevel/

gcloud storage rsync ./firstlevel "gs://${BUCKET_NAME_1}/firstlevel" --recursive

echo
echo "Automation complete."
echo "Bucket: gs://${BUCKET_NAME_1}"
echo "State file: $STATE_FILE"
echo
echo "Click Check my progress for each objective."
