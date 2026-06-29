#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

DATASET="billing_dataset"
TABLE="sampleinfotable"
LOCATION="US"
SOURCE_URI="gs://cloud-training/archinfra/BillingExport-2020-09-18.avro"
STATE_FILE="$HOME/.gcloudops-bigquery-billing-state"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
DATASET=$DATASET
TABLE=$TABLE
LOCATION=$LOCATION
SOURCE_URI=$SOURCE_URI
STATE

echo "Project: $PROJECT_ID"
echo "Dataset: $DATASET"
echo "Table: $TABLE"
echo

gcloud services enable bigquery.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

bq --location="$LOCATION" mk \
  --dataset \
  --default_table_expiration=86400 \
  "$PROJECT_ID:$DATASET" || true

bq rm -f -t "$PROJECT_ID:$DATASET.$TABLE" >/dev/null 2>&1 || true

bq load \
  --location="$LOCATION" \
  --source_format=AVRO \
  "$PROJECT_ID:$DATASET.$TABLE" \
  "$SOURCE_URI"

echo
echo "Table details:"
bq show "$PROJECT_ID:$DATASET.$TABLE"

echo
echo "Row count:"
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT COUNT(*) AS total_rows FROM \`$PROJECT_ID.$DATASET.$TABLE\`;"

echo
echo "============================================================"
echo "CHECKPOINT 1"
echo "Click Check my progress for: Use BigQuery to import data"
echo "============================================================"
read -r -p "Press ENTER after checkpoint passes..." _ < /dev/tty

echo
echo "Running exact Task 3 query..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT * FROM \`$DATASET.$TABLE\`
WHERE cost > 0;"

echo
echo "Task 3 answer:"
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT COUNT(*) AS rows_cost_greater_than_zero
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 0;"

echo
echo "============================================================"
echo "CHECKPOINT 2"
echo "Click Check my progress for: Compose a simple query"
echo "============================================================"
read -r -p "Press ENTER after checkpoint passes..." _ < /dev/tty

echo
echo "Running Task 4 query 1..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  billing_account_id,
  project.id,
  project.name,
  service.description,
  currency,
  currency_conversion_rate,
  cost,
  usage.amount,
  usage.pricing_unit
FROM
  \`$DATASET.$TABLE\`;"

echo
echo "Running Task 4 query 2..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  service.description,
  sku.description,
  location.country,
  cost,
  project.id,
  project.name,
  currency,
  currency_conversion_rate,
  usage.amount,
  usage.unit
FROM
  \`$DATASET.$TABLE\`
WHERE
  cost > 0
ORDER BY usage_end_time DESC
LIMIT 100;"

echo
echo "Running Task 4 query 3..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  service.description,
  sku.description,
  location.country,
  cost,
  project.id,
  project.name,
  currency,
  currency_conversion_rate,
  usage.amount,
  usage.unit
FROM
  \`$DATASET.$TABLE\`
WHERE
  cost > 10;"

echo
echo "Running Task 4 query 4..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  service.description,
  COUNT(*) AS billing_records
FROM
  \`$DATASET.$TABLE\`
GROUP BY
  service.description
ORDER BY billing_records DESC;"

echo
echo "Running Task 4 query 5..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  service.description,
  COUNT(*) AS billing_records
FROM
  \`$DATASET.$TABLE\`
WHERE
  cost > 1
GROUP BY
  service.description
ORDER BY
  billing_records DESC;"

echo
echo "Running Task 4 query 6..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  usage.unit,
  COUNT(*) AS billing_records
FROM
  \`$DATASET.$TABLE\`
WHERE cost > 0
GROUP BY
  usage.unit
ORDER BY
  billing_records DESC;"

echo
echo "Running Task 4 final aggregate cost query..."
bq query --location="$LOCATION" --use_legacy_sql=false \
"SELECT
  service.description,
  ROUND(SUM(cost),2) AS total_cost
FROM
  \`$DATASET.$TABLE\`
GROUP BY
  service.description
ORDER BY
  total_cost DESC;"

echo
echo "============================================================"
echo "CHECKPOINT 3"
echo "Click Check my progress for: Analyze a large billing dataset with SQL"
echo "============================================================"
echo
echo "Automation complete."
echo "State file: $STATE_FILE"
