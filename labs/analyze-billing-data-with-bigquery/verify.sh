#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.gcloudops-bigquery-billing-state"

if [[ -f "$STATE_FILE" ]]; then
  source "$STATE_FILE"
else
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  DATASET="billing_dataset"
  TABLE="sampleinfotable"
fi

echo "Project: $PROJECT_ID"
echo "Dataset: $DATASET"
echo "Table: $TABLE"
echo

echo "Datasets:"
bq ls "$PROJECT_ID" || true

echo
echo "Table:"
bq show "$PROJECT_ID:$DATASET.$TABLE" || true

echo
echo "Row count:"
bq query --use_legacy_sql=false \
"SELECT COUNT(*) AS total_rows FROM \`$PROJECT_ID.$DATASET.$TABLE\`;" || true

echo
echo "Rows where cost > 0:"
bq query --use_legacy_sql=false \
"SELECT COUNT(*) AS rows_cost_greater_than_zero
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
WHERE cost > 0;" || true

echo
echo "Top products by billing records:"
bq query --use_legacy_sql=false \
"SELECT service.description, COUNT(*) AS billing_records
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
GROUP BY service.description
ORDER BY billing_records DESC
LIMIT 5;" || true

echo
echo "Top products by total cost:"
bq query --use_legacy_sql=false \
"SELECT service.description, ROUND(SUM(cost), 2) AS total_cost
FROM \`$PROJECT_ID.$DATASET.$TABLE\`
GROUP BY service.description
ORDER BY total_cost DESC
LIMIT 5;" || true

echo
echo "Verification complete."
