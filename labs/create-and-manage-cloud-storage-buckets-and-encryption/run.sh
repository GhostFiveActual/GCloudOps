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

BUCKET_NAME="storecore-${PROJECT_ID##*-}"

write_boto_keys() {
  local old_key="${1:-}"
  local new_key="${2:-}"
  local mode="${3:-initial}"

  if [[ ! -s "$BOTO_FILE" ]]; then
    gsutil config -n >/dev/null 2>&1 || true
  fi

  python3 - "$BOTO_FILE" "$old_key" "$new_key" "$mode" <<'PY'
import sys, re, pathlib

path = pathlib.Path(sys.argv[1])
old_key = sys.argv[2]
new_key = sys.argv[3]
mode = sys.argv[4]

text = path.read_text() if path.exists() else "[GSUtil]\n"

if "[GSUtil]" not in text:
    text += "\n[GSUtil]\n"

lines = text.splitlines()

lines = [
    l for l in lines
    if not re.match(r"\s*#?\s*(encryption_key|decryption_key1)\s*=", l)
]

out = []
inserted = False

for line in lines:
    out.append(line)
    if line.strip() == "[GSUtil]":
        if mode == "initial":
            out.append(f"encryption_key = {old_key}")
        elif mode == "rotate":
            out.append(f"decryption_key1 = {old_key}")
            out.append(f"encryption_key = {new_key}")
        elif mode == "newonly":
            out.append(f"encryption_key = {new_key}")
        inserted = True

if not inserted:
    out.append("[GSUtil]")
    if mode == "initial":
        out.append(f"encryption_key = {old_key}")
    elif mode == "rotate":
        out.append(f"decryption_key1 = {old_key}")
        out.append(f"encryption_key = {new_key}")
    elif mode == "newonly":
        out.append(f"encryption_key = {new_key}")

path.write_text("\n".join(out) + "\n")
PY
}

echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Bucket: $BUCKET_NAME"
echo

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
REGION=$REGION
BUCKET_NAME=$BUCKET_NAME
STATE

echo "Enabling Storage API..."
gcloud services enable storage.googleapis.com --project="$PROJECT_ID" --quiet

echo
echo "Creating fine-grained bucket..."
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --no-uniform-bucket-level-access \
  --no-public-access-prevention \
  --quiet || true

export BUCKET_NAME_1="$BUCKET_NAME"

echo
echo "Downloading sample files..."
curl -fsSL https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html -o setup.html
cp setup.html setup2.html
cp setup.html setup3.html

echo
echo "Uploading setup.html..."
gcloud storage cp setup.html "gs://${BUCKET_NAME_1}/"

echo
echo "Setting ACL private then public..."
gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl.txt || true

gcloud storage objects update "gs://${BUCKET_NAME_1}/setup.html" \
  --predefined-acl=private

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl2.txt || true

gcloud storage objects add-iam-policy-binding "gs://${BUCKET_NAME_1}/setup.html" \
  --member="allUsers" \
  --role="roles/storage.legacyObjectReader"

gcloud storage objects get-iam-policy "gs://${BUCKET_NAME_1}/setup.html" > acl3.txt || true

echo
echo "Testing restore from bucket..."
rm -f setup.html
gcloud storage cp "gs://${BUCKET_NAME_1}/setup.html" setup.html

echo
echo "Generating CSEK keys..."
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

echo
echo "Configuring initial CSEK..."
write_boto_keys "$OLD_KEY" "" "initial"

echo
echo "Uploading encrypted setup2.html and setup3.html..."
gsutil kms encryption -d "gs://${BUCKET_NAME_1}" || true
gsutil cp setup2.html "gs://${BUCKET_NAME_1}/"
gsutil cp setup3.html "gs://${BUCKET_NAME_1}/"

echo
echo "Verifying CSEK encryption metadata..."
gsutil stat "gs://${BUCKET_NAME_1}/setup2.html" | grep -E "Encryption algorithm|Encryption key SHA256" || true
gsutil stat "gs://${BUCKET_NAME_1}/setup3.html" | grep -E "Encryption algorithm|Encryption key SHA256" || true

echo
echo "CSEK upload complete."
echo "Click Check my progress for: Customer-supplied encryption keys."
read -r -p "Press ENTER after the CSEK checkpoint passes..." _ < /dev/tty

echo
echo "Testing encrypted download..."
rm -f setup*
gsutil cp "gs://${BUCKET_NAME_1}/setup*" ./

echo
echo "Rotating CSEK..."
write_boto_keys "$OLD_KEY" "$NEW_KEY" "rotate"
gsutil rewrite -k "gs://${BUCKET_NAME_1}/setup2.html"

echo
echo "Removing old decrypt key and testing recovery..."
write_boto_keys "$OLD_KEY" "$NEW_KEY" "newonly"

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

gcloud storage buckets update "gs://${BUCKET_NAME_1}" \
  --lifecycle-file=life.json

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
echo "Click any remaining Check my progress buttons."
