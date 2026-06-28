#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="${REGION:-}"
BOTO_FILE="$HOME/.boto"
STATE_FILE="$HOME/.gcloudops-cloud-storage-state"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

BUCKET_NAME="storecore${PROJECT_ID##*-}"
export BUCKET_NAME_1="$BUCKET_NAME"

echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME_1"
echo

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
REGION=$REGION
BUCKET_NAME=$BUCKET_NAME_1
STATE

set_boto_encryption_key() {
  local key="$1"

  gsutil config -n >/dev/null 2>&1 || true

  python3 - "$BOTO_FILE" "$key" <<'PY'
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]

text = path.read_text() if path.exists() else "[GSUtil]\n"

if "[GSUtil]" not in text:
    text += "\n[GSUtil]\n"

lines = [
    line for line in text.splitlines()
    if not re.match(r"\s*#?\s*(encryption_key|decryption_key1)\s*=", line)
]

out = []
inserted = False

for line in lines:
    out.append(line)
    if line.strip() == "[GSUtil]":
        out.append(f"encryption_key={key}")
        inserted = True

if not inserted:
    out.append("[GSUtil]")
    out.append(f"encryption_key={key}")

path.write_text("\n".join(out) + "\n")
PY
}

set_boto_rotation_keys() {
  local old_key="$1"
  local new_key="$2"

  python3 - "$BOTO_FILE" "$old_key" "$new_key" <<'PY'
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
old_key = sys.argv[2]
new_key = sys.argv[3]

text = path.read_text() if path.exists() else "[GSUtil]\n"

if "[GSUtil]" not in text:
    text += "\n[GSUtil]\n"

lines = [
    line for line in text.splitlines()
    if not re.match(r"\s*#?\s*(encryption_key|decryption_key1)\s*=", line)
]

out = []
inserted = False

for line in lines:
    out.append(line)
    if line.strip() == "[GSUtil]":
        out.append(f"decryption_key1={old_key}")
        out.append(f"encryption_key={new_key}")
        inserted = True

if not inserted:
    out.append("[GSUtil]")
    out.append(f"decryption_key1={old_key}")
    out.append(f"encryption_key={new_key}")

path.write_text("\n".join(out) + "\n")
PY
}

echo "Enabling Storage API..."
gcloud services enable storage.googleapis.com --project="$PROJECT_ID" --quiet

echo
echo "Creating Cloud Storage bucket..."
gcloud storage buckets create "gs://${BUCKET_NAME_1}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --no-uniform-bucket-level-access \
  --no-public-access-prevention \
  --quiet

echo
echo "Downloading sample file..."
curl -fsSL https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html -o setup.html
cp setup.html setup2.html
cp setup.html setup3.html

echo
echo "Uploading setup.html..."
gcloud storage cp setup.html "gs://${BUCKET_NAME_1}/"

echo
echo "Setting setup.html private..."
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl.txt || true
gcloud storage objects update "gs://${BUCKET_NAME_1}/setup.html" --predefined-acl=private
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl2.txt || true

echo
echo "Making setup.html public..."
gcloud storage objects add-iam-policy-binding "gs://${BUCKET_NAME_1}/setup.html" \
  --member="allUsers" \
  --role="roles/storage.legacyObjectReader"

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl3.txt || true

echo
echo "Restoring setup.html from bucket..."
rm -f setup.html
gcloud storage cp "gs://${BUCKET_NAME_1}/setup.html" setup.html

echo
echo "Generating CSEK keys..."
OLD_KEY=$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')
NEW_KEY=$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')

cat >> "$STATE_FILE" <<STATE
OLD_KEY=$OLD_KEY
NEW_KEY=$NEW_KEY
STATE

echo
echo "Configuring initial CSEK..."
set_boto_encryption_key "$OLD_KEY"

echo
echo "Uploading setup2.html and setup3.html with CSEK..."
gsutil kms encryption -d "gs://${BUCKET_NAME_1}"
gsutil cp setup2.html "gs://${BUCKET_NAME_1}/"
gsutil cp setup3.html "gs://${BUCKET_NAME_1}/"

echo
echo "CSEK metadata:"
gsutil stat "gs://${BUCKET_NAME_1}/setup2.html" | grep -E "Encryption algorithm|Encryption key SHA256"
gsutil stat "gs://${BUCKET_NAME_1}/setup3.html" | grep -E "Encryption algorithm|Encryption key SHA256"

echo
echo "Click Check my progress for CSEK now."
read -r -p "Press ENTER after the CSEK checkpoint passes..." _ < /dev/tty

echo
echo "Downloading encrypted files..."
rm -f setup*
gsutil cp "gs://${BUCKET_NAME_1}/setup*" ./

echo
echo "Rotating CSEK..."
set_boto_rotation_keys "$OLD_KEY" "$NEW_KEY"
gsutil rewrite -k "gs://${BUCKET_NAME_1}/setup2.html"

echo
echo "Testing rotated key..."
set_boto_encryption_key "$NEW_KEY"
gsutil cp "gs://${BUCKET_NAME_1}/setup2.html" recover2.html

if gsutil cp "gs://${BUCKET_NAME_1}/setup3.html" recover3.html >/tmp/gcloudops-setup3.log 2>&1; then
  echo "Warning: setup3.html downloaded successfully, but it was expected to fail."
else
  echo "Expected: setup3.html failed because it was not rewritten with the new key."
fi

echo
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

gcloud storage buckets update "gs://${BUCKET_NAME_1}" --lifecycle-file=life.json

echo
echo "Enabling versioning..."
gcloud storage buckets update "gs://${BUCKET_NAME_1}" --versioning

echo
echo "Creating object versions..."
curl -fsSL https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html -o setup.html

gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

sed -i '20,24d' setup.html
gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

sed -i '40,44d' setup.html || sed -i '10,14d' setup.html
gcloud storage cp -v setup.html "gs://${BUCKET_NAME_1}/"

VERSION_NAME=$(gcloud storage ls -a "gs://${BUCKET_NAME_1}/setup.html" | head -n 1)
echo "Oldest version: $VERSION_NAME"
gcloud storage cp "$VERSION_NAME" recovered.txt

echo
echo "Syncing nested directory..."
mkdir -p firstlevel/secondlevel
cp setup.html firstlevel/
cp setup.html firstlevel/secondlevel/

gcloud storage rsync ./firstlevel "gs://${BUCKET_NAME_1}/firstlevel" --recursive

echo
echo "Automation complete."
echo "Bucket: gs://${BUCKET_NAME_1}"
echo "State file: $STATE_FILE"
echo
echo "Click remaining Check my progress buttons."
