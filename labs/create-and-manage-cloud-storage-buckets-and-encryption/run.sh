#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="${REGION:-}"
BOTO_FILE="$HOME/.boto"
STATE_FILE="$HOME/.gcloudops-cloud-storage-state"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

SUFFIX="${PROJECT_ID##*-}"
BUCKET_NAME_1="storecore${SUFFIX}"

echo
echo "============================================================"
echo " GCloudOps :: Cloud Storage Buckets and Encryption"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Bucket:  $BUCKET_NAME_1"
echo

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
REGION=$REGION
BUCKET_NAME=$BUCKET_NAME_1
STATE

echo "[1/7] Creating fine-grained regional bucket..."

if ! gcloud storage buckets describe "gs://${BUCKET_NAME_1}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET_NAME_1}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --no-uniform-bucket-level-access \
    --no-public-access-prevention
else
  echo "Bucket already exists."
fi

echo
echo "Downloading setup.html..."

curl -fsSL \
  https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html \
  -o setup.html

cp setup.html setup2.html
cp setup.html setup3.html

echo
echo "============================================================"
echo "TASK 1 COMPLETE"
echo "Bucket: gs://${BUCKET_NAME_1}"
echo "Click Check my progress: Create a Cloud Storage bucket"
echo "============================================================"
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "[2/7] Configuring ACLs..."

gcloud storage cp setup.html "gs://${BUCKET_NAME_1}/"

gcloud storage objects get-iam-policy \
  "gs://${BUCKET_NAME_1}/setup.html" > acl.txt || true

gcloud storage objects update \
  "gs://${BUCKET_NAME_1}/setup.html" \
  --predefined-acl=private

gcloud storage objects get-iam-policy \
  "gs://${BUCKET_NAME_1}/setup.html" > acl2.txt || true

gcloud storage objects add-iam-policy-binding \
  "gs://${BUCKET_NAME_1}/setup.html" \
  --member="allUsers" \
  --role="roles/storage.legacyObjectReader"

gcloud storage objects get-iam-policy \
  "gs://${BUCKET_NAME_1}/setup.html" > acl3.txt || true

rm -f setup.html
gcloud storage cp \
  "gs://${BUCKET_NAME_1}/setup.html" \
  setup.html

echo
echo "============================================================"
echo "TASK 2 COMPLETE"
echo "Click Check my progress: Make file publicly readable"
echo "============================================================"
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "[3/7] Generating CSEK..."

OLD_KEY="$(
python3 - <<'PY'
import os, base64
print(base64.b64encode(os.urandom(32)).decode())
PY
)"

cat >> "$STATE_FILE" <<STATE
OLD_KEY=$OLD_KEY
STATE

echo "Preparing clean .boto configuration..."

if [[ -f "$BOTO_FILE" ]]; then
  cp "$BOTO_FILE" "${BOTO_FILE}.gcloudops.backup"
fi

gsutil config -n >/dev/null 2>&1 || true

python3 - "$BOTO_FILE" "$OLD_KEY" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]

text = path.read_text() if path.exists() else "[GSUtil]\n"

if "[GSUtil]" not in text:
    text += "\n[GSUtil]\n"

lines = text.splitlines()

out = []
inside_gsutil = False
inserted = False

for line in lines:
    if re.match(r"^\s*\[GSUtil\]\s*$", line):
        inside_gsutil = True
        out.append(line)
        out.append(f"encryption_key={key}")
        inserted = True
        continue

    if line.startswith("[") and line.endswith("]") and line.strip() != "[GSUtil]":
        inside_gsutil = False

    if inside_gsutil and re.match(r"^\s*#?\s*(encryption_key|decryption_key\d*)\s*=", line):
        continue

    out.append(line)

if not inserted:
    out.extend([
        "",
        "[GSUtil]",
        f"encryption_key={key}"
    ])

path.write_text("\n".join(out) + "\n")
PY

echo "Uploading setup2.html and setup3.html using CSEK..."

gsutil kms encryption -d "gs://${BUCKET_NAME_1}"
gsutil cp setup2.html "gs://${BUCKET_NAME_1}/"
gsutil cp setup3.html "gs://${BUCKET_NAME_1}/"

echo
echo "CSEK verification:"
gsutil stat "gs://${BUCKET_NAME_1}/setup2.html" \
  | grep -E "Encryption algorithm|Encryption key SHA256"

gsutil stat "gs://${BUCKET_NAME_1}/setup3.html" \
  | grep -E "Encryption algorithm|Encryption key SHA256"

echo
echo "============================================================"
echo "TASK 3 COMPLETE"
echo "DO NOT CONTINUE UNTIL THIS CHECKPOINT PASSES."
echo "Click Check my progress: Customer-supplied encryption keys"
echo "============================================================"
read -r -p "Press ENTER only after the CSEK checkpoint passes..." _ < /dev/tty

echo
echo "Downloading all setup files using original key..."

rm -f setup.html setup2.html setup3.html
gsutil cp "gs://${BUCKET_NAME_1}/setup*" ./

echo
echo "[4/7] Rotating CSEK..."

NEW_KEY="$(
python3 - <<'PY'
import os, base64
print(base64.b64encode(os.urandom(32)).decode())
PY
)"

cat >> "$STATE_FILE" <<STATE
NEW_KEY=$NEW_KEY
STATE

python3 - "$BOTO_FILE" "$OLD_KEY" "$NEW_KEY" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
old_key = sys.argv[2]
new_key = sys.argv[3]

text = path.read_text()

lines = text.splitlines()
out = []
inside = False

for line in lines:
    if line.strip() == "[GSUtil]":
        inside = True
        out.append(line)
        out.append(f"encryption_key={new_key}")
        out.append(f"decryption_key1={old_key}")
        continue

    if line.startswith("[") and line.endswith("]") and line.strip() != "[GSUtil]":
        inside = False

    if inside and re.match(r"^\s*#?\s*(encryption_key|decryption_key\d*)\s*=", line):
        continue

    out.append(line)

path.write_text("\n".join(out) + "\n")
PY

gsutil rewrite -k "gs://${BUCKET_NAME_1}/setup2.html"

echo
echo "Removing old decryption key..."

python3 - "$BOTO_FILE" "$NEW_KEY" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
new_key = sys.argv[2]

text = path.read_text()
lines = text.splitlines()

out = []
inside = False

for line in lines:
    if line.strip() == "[GSUtil]":
        inside = True
        out.append(line)
        out.append(f"encryption_key={new_key}")
        continue

    if line.startswith("[") and line.endswith("]") and line.strip() != "[GSUtil]":
        inside = False

    if inside and re.match(r"^\s*#?\s*(encryption_key|decryption_key\d*)\s*=", line):
        continue

    out.append(line)

path.write_text("\n".join(out) + "\n")
PY

gsutil cp \
  "gs://${BUCKET_NAME_1}/setup2.html" \
  recover2.html

if gsutil cp \
    "gs://${BUCKET_NAME_1}/setup3.html" \
    recover3.html >/tmp/setup3-recovery.log 2>&1; then

  echo "WARNING: setup3.html unexpectedly decrypted."
else
  echo "Expected: setup3.html cannot be decrypted after old key removal."
fi

echo
echo "[5/7] Configuring lifecycle management..."

cat > life.json <<'JSON'
{
  "rule": [
    {
      "action": {
        "type": "Delete"
      },
      "condition": {
        "age": 31
      }
    }
  ]
}
JSON

gcloud storage buckets update \
  "gs://${BUCKET_NAME_1}" \
  --lifecycle-file=life.json

gcloud storage buckets describe \
  "gs://${BUCKET_NAME_1}" \
  --format="json(lifecycle)"

echo
echo "============================================================"
echo "TASK 5 COMPLETE"
echo "Click Check my progress: Enable lifecycle management"
echo "============================================================"
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "[6/7] Enabling versioning..."

gcloud storage buckets update \
  "gs://${BUCKET_NAME_1}" \
  --versioning

gcloud storage buckets describe \
  "gs://${BUCKET_NAME_1}" \
  --format="json(versioning_enabled)"

echo
echo "============================================================"
echo "TASK 6 CHECKPOINT"
echo "Click Check my progress: Enable versioning"
echo "============================================================"
read -r -p "Press ENTER to continue..." _ < /dev/tty

echo
echo "Creating object versions..."

curl -fsSL \
  https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html \
  -o setup.html

gcloud storage cp -v \
  setup.html \
  "gs://${BUCKET_NAME_1}/setup.html"

python3 - <<'PY'
from pathlib import Path
p = Path("setup.html")
lines = p.read_text().splitlines()
p.write_text("\n".join(lines[:20] + lines[25:]) + "\n")
PY

gcloud storage cp -v \
  setup.html \
  "gs://${BUCKET_NAME_1}/setup.html"

python3 - <<'PY'
from pathlib import Path
p = Path("setup.html")
lines = p.read_text().splitlines()
p.write_text("\n".join(lines[:40] + lines[45:]) + "\n")
PY

gcloud storage cp -v \
  setup.html \
  "gs://${BUCKET_NAME_1}/setup.html"

echo
echo "Object versions:"
gcloud storage ls -a \
  "gs://${BUCKET_NAME_1}/setup.html"

VERSION_NAME="$(
  gcloud storage ls -a \
    "gs://${BUCKET_NAME_1}/setup.html" \
    | head -n 1
)"

echo
echo "Oldest version:"
echo "$VERSION_NAME"

gcloud storage cp \
  "$VERSION_NAME" \
  recovered.txt

ls -lh setup.html recovered.txt

echo
echo "[7/7] Synchronizing directory..."

rm -rf firstlevel
mkdir -p firstlevel/secondlevel

cp setup.html firstlevel/
cp setup.html firstlevel/secondlevel/

gcloud storage rsync \
  ./firstlevel \
  "gs://${BUCKET_NAME_1}/firstlevel" \
  --recursive

echo
echo "Synchronized objects:"
gcloud storage ls -r \
  "gs://${BUCKET_NAME_1}/firstlevel"

echo
echo "============================================================"
echo " GCLOUDOPS AUTOMATION COMPLETE"
echo "============================================================"
echo "Bucket: gs://${BUCKET_NAME_1}"
echo "State:  $STATE_FILE"
echo
echo "Remaining validation can now be completed."
