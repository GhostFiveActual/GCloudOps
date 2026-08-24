#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || {
  echo "ERROR: No active project."
  exit 1
}

read -r -p "Cluster name: " CLUSTER_NAME </dev/tty
read -r -p "Region: " REGION </dev/tty
read -r -p "Zone: " ZONE </dev/tty
read -r -p "Namespace name: " NAMESPACE_NAME </dev/tty
read -r -p "Artifact Registry repo name: " REPO_NAME </dev/tty
read -r -p "Service name: " SERVICE_NAME </dev/tty
read -r -p "Prometheus interval (example 30s): " INTERVAL </dev/tty

echo
echo "============================================================"
echo " GCloudOps :: GSP510"
echo " Manage Kubernetes in Google Cloud"
echo "============================================================"
echo "Project:   $PROJECT_ID"
echo "Cluster:   $CLUSTER_NAME"
echo "Zone:      $ZONE"
echo "Region:    $REGION"
echo "Namespace: $NAMESPACE_NAME"
echo "Repo:      $REPO_NAME"
echo "Service:   $SERVICE_NAME"
echo "Interval:  $INTERVAL"
echo "============================================================"

gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# ============================================================
# TASK 1
# Create GKE cluster
# ============================================================

echo
echo "[1/6] Creating GKE cluster..."

if ! gcloud container clusters describe "$CLUSTER_NAME" \
     --zone="$ZONE" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud container clusters create "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --release-channel=regular \
    --num-nodes=3 \
    --enable-autoscaling \
    --min-nodes=2 \
    --max-nodes=6 \
    --project="$PROJECT_ID" \
    --quiet
else
  echo "Cluster already exists."
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID"

echo
echo "Cluster:"
gcloud container clusters describe "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --format='yaml(name,location,currentMasterVersion,releaseChannel,autoscaling)'

echo
echo "============================================================"
echo "TASK 1 COMPLETE"
echo "Click Check my progress: Create a GKE cluster"
echo "============================================================"
read -r -p "Press ENTER after Task 1 passes..." _ </dev/tty

# ============================================================
# TASK 2
# Managed Prometheus
# ============================================================

echo
echo "[2/6] Enabling Managed Prometheus..."

gcloud container clusters update "$CLUSTER_NAME" \
  --zone="$ZONE" \
  --enable-managed-prometheus \
  --project="$PROJECT_ID" \
  --quiet

kubectl create namespace "$NAMESPACE_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f prometheus-app.yaml pod-monitoring.yaml

gcloud storage cp \
  gs://spls/gsp510/prometheus-app.yaml .

gcloud storage cp \
  gs://spls/gsp510/pod-monitoring.yaml .

python3 - "$NAMESPACE_NAME" <<'PY'
import sys
from pathlib import Path

p = Path("prometheus-app.yaml")
s = p.read_text()

# Replace TODOs in their expected order.
values = [
    "nilebox/prometheus-example-app:latest",
    "prometheus-test",
    "metrics",
]

for value in values:
    if "<todo>" not in s:
        break
    s = s.replace("<todo>", value, 1)

p.write_text(s)
PY

echo
echo "Patched prometheus-app.yaml:"
cat prometheus-app.yaml

kubectl apply \
  -n "$NAMESPACE_NAME" \
  -f prometheus-app.yaml

python3 - "$INTERVAL" <<'PY'
import sys
from pathlib import Path

interval = sys.argv[1]

p = Path("pod-monitoring.yaml")
s = p.read_text()

values = [
    "prometheus-test",
    "prometheus-test",
    "prometheus-test",
    interval,
]

for value in values:
    if "<todo>" not in s:
        break
    s = s.replace("<todo>", value, 1)

p.write_text(s)
PY

echo
echo "Patched pod-monitoring.yaml:"
cat pod-monitoring.yaml

kubectl apply \
  -n "$NAMESPACE_NAME" \
  -f pod-monitoring.yaml

kubectl get pods \
  -n "$NAMESPACE_NAME"

kubectl get podmonitorings.monitoring.googleapis.com \
  -n "$NAMESPACE_NAME" || true

echo
echo "============================================================"
echo "TASK 2 COMPLETE"
echo "Click Check my progress: Enable Managed Prometheus"
echo "============================================================"
read -r -p "Press ENTER after Task 2 passes..." _ </dev/tty

# ============================================================
# TASK 3
# Intentionally broken deployment
# ============================================================

echo
echo "[3/6] Deploying intentionally broken helloweb manifest..."

rm -rf hello-app

gcloud storage cp -r \
  gs://spls/gsp510/hello-app/ .

MANIFEST="hello-app/manifests/helloweb-deployment.yaml"

kubectl delete deployment helloweb \
  -n "$NAMESPACE_NAME" \
  --ignore-not-found=true

kubectl apply \
  -n "$NAMESPACE_NAME" \
  -f "$MANIFEST"

echo
echo "Waiting for InvalidImageName event..."
sleep 30

kubectl get deployment helloweb \
  -n "$NAMESPACE_NAME" || true

kubectl get pods \
  -n "$NAMESPACE_NAME" || true

kubectl get events \
  -n "$NAMESPACE_NAME" \
  --sort-by='.lastTimestamp' | tail -20 || true

echo
echo "============================================================"
echo "TASK 3 COMPLETE"
echo "Click Check my progress: Deploy an application"
echo "============================================================"
read -r -p "Press ENTER after Task 3 passes..." _ </dev/tty

# ============================================================
# TASK 4
# Logs-based metric
# ============================================================

echo
echo "[4/6] Creating logs-based metric..."

METRIC_FILTER='resource.type="k8s_pod"
severity>=WARNING'

if gcloud logging metrics describe pod-image-errors \
     --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud logging metrics update pod-image-errors \
    --project="$PROJECT_ID" \
    --description="Kubernetes pod warnings and errors" \
    --log-filter="$METRIC_FILTER"
else
  gcloud logging metrics create pod-image-errors \
    --project="$PROJECT_ID" \
    --description="Kubernetes pod warnings and errors" \
    --log-filter="$METRIC_FILTER"
fi

echo
echo "Creating Pod Error Alert..."

ACCESS_TOKEN="$(gcloud auth print-access-token)"
BASE="https://monitoring.googleapis.com/v3/projects/${PROJECT_ID}"

curl -fsS \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${BASE}/alertPolicies" \
  >/tmp/gsp510-policies.json

python3 - <<'PY' >/tmp/gsp510-delete-policies.txt
import json

with open("/tmp/gsp510-policies.json") as f:
    d=json.load(f)

for p in d.get("alertPolicies", []):
    if p.get("displayName") == "Pod Error Alert":
        print(p["name"])
PY

while read -r POLICY; do
  [[ -z "$POLICY" ]] && continue

  curl -fsS -X DELETE \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://monitoring.googleapis.com/v3/${POLICY}" \
    >/dev/null
done </tmp/gsp510-delete-policies.txt

cat >/tmp/pod-error-alert.json <<'JSON'
{
  "displayName": "Pod Error Alert",
  "combiner": "OR",
  "enabled": true,
  "conditions": [
    {
      "displayName": "pod-image-errors above 0",
      "conditionThreshold": {
        "filter": "metric.type=\"logging.googleapis.com/user/pod-image-errors\" AND resource.type=\"k8s_pod\"",
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "aggregations": [
          {
            "alignmentPeriod": "600s",
            "perSeriesAligner": "ALIGN_COUNT",
            "crossSeriesReducer": "REDUCE_SUM"
          }
        ],
        "trigger": {
          "count": 1
        }
      }
    }
  ]
}
JSON

curl -fsS -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d @/tmp/pod-error-alert.json \
  "${BASE}/alertPolicies" \
  | tee /tmp/gsp510-created-alert.json

echo
echo "============================================================"
echo "TASK 4 COMPLETE"
echo "Click Check my progress: Create logs-based metric and alert"
echo "============================================================"
read -r -p "Press ENTER after Task 4 passes..." _ </dev/tty

# ============================================================
# TASK 5
# Repair deployment
# ============================================================

echo
echo "[5/6] Repairing helloweb deployment..."

python3 - "$MANIFEST" <<'PY'
import sys
from pathlib import Path

p=Path(sys.argv[1])
s=p.read_text()

s=s.replace(
    "<todo>",
    "us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0"
)

p.write_text(s)
PY

kubectl delete deployment helloweb \
  -n "$NAMESPACE_NAME" \
  --ignore-not-found=true

kubectl apply \
  -n "$NAMESPACE_NAME" \
  -f "$MANIFEST"

kubectl rollout status deployment/helloweb \
  -n "$NAMESPACE_NAME" \
  --timeout=180s

kubectl get pods \
  -n "$NAMESPACE_NAME"

echo
echo "============================================================"
echo "TASK 5 COMPLETE"
echo "Click Check my progress: Update and re-deploy your app"
echo "============================================================"
read -r -p "Press ENTER after Task 5 passes..." _ </dev/tty

# ============================================================
# TASK 6
# Build v2 / push Artifact Registry / expose service
# ============================================================

echo
echo "[6/6] Building application v2..."

MAIN_GO="hello-app/main.go"

python3 - "$MAIN_GO" <<'PY'
import re
import sys
from pathlib import Path

p=Path(sys.argv[1])
s=p.read_text()

# Lab source normally contains Version: 1.0.0.
s=re.sub(
    r'Version:\s*[^"\\n]+',
    'Version: 2.0.0',
    s
)

# Also handle literal quoted version patterns if present.
s=s.replace('Version: 1.0.0', 'Version: 2.0.0')
s=s.replace('Version: 1.0.0\\n', 'Version: 2.0.0\\n')

p.write_text(s)
PY

echo "Version references:"
grep -n "Version" "$MAIN_GO" || true

gcloud auth configure-docker \
  "${REGION}-docker.pkg.dev" \
  --quiet

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/hello-app:v2"

echo
echo "Image:"
echo "$IMAGE"

docker build \
  -t "$IMAGE" \
  hello-app

docker push "$IMAGE"

echo
echo "Updating helloweb deployment..."

kubectl set image \
  deployment/helloweb \
  hello-app="$IMAGE" \
  -n "$NAMESPACE_NAME"

kubectl rollout status deployment/helloweb \
  -n "$NAMESPACE_NAME" \
  --timeout=180s

echo
echo "Creating LoadBalancer service..."

kubectl delete service "$SERVICE_NAME" \
  -n "$NAMESPACE_NAME" \
  --ignore-not-found=true

kubectl expose deployment helloweb \
  -n "$NAMESPACE_NAME" \
  --name="$SERVICE_NAME" \
  --type=LoadBalancer \
  --port=8080 \
  --target-port=8080

echo
echo "Waiting for external IP..."

for i in {1..40}; do

  EXTERNAL_IP="$(
    kubectl get service "$SERVICE_NAME" \
      -n "$NAMESPACE_NAME" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
      2>/dev/null || true
  )"

  if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="$(
      kubectl get service "$SERVICE_NAME" \
        -n "$NAMESPACE_NAME" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        2>/dev/null || true
    )"
  fi

  if [[ -n "$EXTERNAL_IP" ]]; then
    break
  fi

  echo "Waiting for LoadBalancer... ($i/40)"
  sleep 10
done

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  echo "WARNING: LoadBalancer IP is still provisioning."
else
  echo
  echo "External endpoint:"
  echo "http://${EXTERNAL_IP}:8080"

  echo
  echo "Testing application..."

  for i in {1..20}; do
    if curl -fsS \
      --connect-timeout 5 \
      "http://${EXTERNAL_IP}:8080/" \
      >/tmp/gsp510-response.txt 2>/dev/null; then

      cat /tmp/gsp510-response.txt
      break
    fi

    sleep 10
  done
fi

echo
echo "============================================================"
echo " GSP510 AUTOMATION COMPLETE"
echo "============================================================"
echo "Cluster:   $CLUSTER_NAME"
echo "Namespace: $NAMESPACE_NAME"
echo "Repository:$REPO_NAME"
echo "Image:     $IMAGE"
echo "Service:   $SERVICE_NAME"
echo
echo "Click Check my progress for Task 6."
echo "============================================================"
