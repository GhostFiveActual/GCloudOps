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

echo "Enabling BigQuery API..."
gcloud services enable bigquery.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "Creating dataset..."
bq --location="$LOCATION" mk \
  --dataset \
  --default_table_expiration=86400 \
  "$PROJECT_ID:$DATASET" || true

echo
echo "Loading Avro billing data into BigQuery..."
bq load \
  --source_format=AVRO \
  "$PROJECT_ID:$DATASET.$TABLE" \
  "$SOURCE_URI"

echo
echo "Table details:"
bq show "$PROJECT_ID:$DATASET.$TABLE"

echo
echo "Row count:"
bq query --use_legacy_sql=false \
"SELECT COUNT(*) AS total_rows FROM \`$PROJECT_ID.$DATASET.$TABLE\`;"

echo
echo "============================================================"
echo "Checkpoint:"
echo "Click Check my progress for: Use BigQuery to import data"
echo "============================================================"
read -r -p "Press ENTER after checkpoint passes..." _ < /dev/tty

echo
echo "Running simple query: cost > 0"
bq query --use_legacy_sql=false \
"SELECT COUNT(*) AS rows_cost_greater_than_zero
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 0;"

echo
echo "Running full selected billing query..."
bq query --use_legacy_sql=false \
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
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
LIMIT 100;"

echo
echo "Latest 100 records where cost > 0..."
bq query --use_legacy_sql=false \
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
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 0
ORDER BY usage_end_time DESC
LIMIT 100;"

echo
echo "Charges greater than 10 dollars..."
bq query --use_legacy_sql=false \
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
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 10;"

echo
echo "Product with most billing records..."
bq query --use_legacy_sql=false \
"SELECT
  service.description,
  COUNT(*) AS billing_records
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
GROUP BY service.description
ORDER BY billing_records DESC;"

echo
echo "Most frequently used product costing more than 1 dollar..."
bq query --use_legacy_sql=false \
"SELECT
  service.description,
  COUNT(*) AS billing_records
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 1
GROUP BY service.description
ORDER BY billing_records DESC;"

echo
echo "Most commonly charged unit of measure..."
bq query --use_legacy_sql=false \
"SELECT
  usage.unit,
  COUNT(*) AS billing_records
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 0
GROUP BY usage.unit
ORDER BY billing_records DESC;"

echo
echo "Product with highest aggregate cost..."
bq query --use_legacy_sql=false \
"SELECT
  service.description,
  ROUND(SUM(cost), 2) AS total_cost
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
GROUP BY service.description
ORDER BY total_cost DESC;"

echo
echo "============================================================"
echo "Checkpoint:"
echo "Click Check my progress for: Compose a simple query"
echo "Click Check my progress for: Analyze a large billing dataset with SQL"
echo "============================================================"
echo
echo "Automation complete."
echo "State file: $STATE_FILE"
