#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="$(gcloud config get-value compute/region 2>/dev/null)"
ZONE="$(gcloud config get-value compute/zone 2>/dev/null)"

echo "============================================================"
echo " GCloudOps :: Network Load Balancer Verification"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo

PASS=0
FAIL=0

check() {
    local NAME="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "[PASS] $NAME"
        ((PASS+=1))
    else
        echo "[FAIL] $NAME"
        ((FAIL+=1))
    fi
}

check "www1 exists" \
    gcloud compute instances describe www1 \
    --project="$PROJECT_ID" --zone="$ZONE"

check "www2 exists" \
    gcloud compute instances describe www2 \
    --project="$PROJECT_ID" --zone="$ZONE"

check "www3 exists" \
    gcloud compute instances describe www3 \
    --project="$PROJECT_ID" --zone="$ZONE"

check "HTTP firewall rule exists" \
    gcloud compute firewall-rules describe www-firewall-network-lb \
    --project="$PROJECT_ID"

check "Static load balancer IP exists" \
    gcloud compute addresses describe network-lb-ip-1 \
    --project="$PROJECT_ID" --region="$REGION"

check "HTTP health check exists" \
    gcloud compute http-health-checks describe basic-check \
    --project="$PROJECT_ID"

check "Target pool exists" \
    gcloud compute target-pools describe www-pool \
    --project="$PROJECT_ID" --region="$REGION"

check "Forwarding rule exists" \
    gcloud compute forwarding-rules describe www-rule \
    --project="$PROJECT_ID" --region="$REGION"

echo
echo "Target pool members:"

gcloud compute target-pools describe www-pool \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format="yaml(instances)"

IPADDRESS="$(
    gcloud compute forwarding-rules describe www-rule \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="value(IPAddress)" 2>/dev/null || true
)"

echo
echo "Load balancer IP: $IPADDRESS"

if [[ -n "$IPADDRESS" ]]; then
    echo
    echo "HTTP test:"

    if RESPONSE="$(curl -fsS --max-time 10 "http://${IPADDRESS}")"; then
        echo "$RESPONSE"
        echo "[PASS] Load balancer responds over HTTP"
        ((PASS+=1))
    else
        echo "[WARN] Load balancer did not respond yet."
    fi
fi

echo
echo "============================================================"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "============================================================"

if (( FAIL > 0 )); then
    exit 1
fi

echo "Verification complete."
