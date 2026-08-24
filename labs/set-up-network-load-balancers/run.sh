#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "ERROR: No active Google Cloud project."
    exit 1
fi

read -r -p "Paste lab REGION value: " REGION < /dev/tty
read -r -p "Paste lab ZONE value: " ZONE < /dev/tty

if [[ -z "$REGION" || -z "$ZONE" ]]; then
    echo "ERROR: REGION and ZONE are required."
    exit 1
fi

echo
echo "============================================================"
echo " GCloudOps :: Set Up Network Load Balancers"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo

echo "[1/9] Configuring defaults..."

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

echo
echo "[2/9] Enabling Compute Engine API..."

gcloud services enable compute.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

echo
echo "[3/9] Creating web servers..."

for VM in www1 www2 www3; do

    if gcloud compute instances describe "$VM" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        >/dev/null 2>&1; then

        echo "$VM already exists."

    else
        echo "Creating $VM..."

        gcloud compute instances create "$VM" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --machine-type=e2-small \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --tags=network-lb-tag \
            --metadata=startup-script="#!/bin/bash
apt-get update
apt-get install -y apache2
systemctl enable apache2
systemctl restart apache2
echo '<h3>Web Server: ${VM}</h3>' > /var/www/html/index.html" \
            --quiet
    fi
done

echo
echo "[4/9] Creating HTTP firewall rule..."

if gcloud compute firewall-rules describe www-firewall-network-lb \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Firewall rule already exists."

else
    gcloud compute firewall-rules create www-firewall-network-lb \
        --project="$PROJECT_ID" \
        --network=default \
        --target-tags=network-lb-tag \
        --allow=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --quiet
fi

echo
echo "[5/9] Creating static regional IP..."

if gcloud compute addresses describe network-lb-ip-1 \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Static IP already exists."

else
    gcloud compute addresses create network-lb-ip-1 \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --quiet
fi

echo
echo "[6/9] Creating legacy HTTP health check..."

if gcloud compute http-health-checks describe basic-check \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Health check already exists."

else
    gcloud compute http-health-checks create basic-check \
        --project="$PROJECT_ID" \
        --port=80 \
        --request-path=/ \
        --quiet
fi

echo
echo "[7/9] Creating target pool..."

if gcloud compute target-pools describe www-pool \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Target pool already exists."

else
    gcloud compute target-pools create www-pool \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --http-health-check=basic-check \
        --quiet
fi

echo
echo "Adding web servers to target pool..."

# Determine which instances are already members.
CURRENT_INSTANCES="$(
    gcloud compute target-pools describe www-pool \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --format="value(instances)" 2>/dev/null || true
)"

MISSING=()

for VM in www1 www2 www3; do
    if ! grep -q "/instances/${VM}" <<< "$CURRENT_INSTANCES"; then
        MISSING+=("$VM")
    fi
done

if (( ${#MISSING[@]} > 0 )); then
    INSTANCE_LIST="$(IFS=,; echo "${MISSING[*]}")"

    gcloud compute target-pools add-instances www-pool \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --instances="$INSTANCE_LIST" \
        --instances-zone="$ZONE" \
        --quiet
else
    echo "All instances already belong to www-pool."
fi

echo
echo "[8/9] Creating forwarding rule..."

if gcloud compute forwarding-rules describe www-rule \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Forwarding rule already exists."

else
    gcloud compute forwarding-rules create www-rule \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --ports=80 \
        --address=network-lb-ip-1 \
        --target-pool=www-pool \
        --quiet
fi

echo
echo "[9/9] Verifying deployment..."

IPADDRESS="$(
    gcloud compute forwarding-rules describe www-rule \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="value(IPAddress)"
)"

echo
echo "============================================================"
echo " VM INSTANCES"
echo "============================================================"

gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="name=(www1 www2 www3)" \
    --format="table(
        name,
        zone.basename(),
        machineType.basename(),
        status,
        networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP
    )"

echo
echo "============================================================"
echo " LOAD BALANCER"
echo "============================================================"
echo "IP address: http://${IPADDRESS}"
echo

echo "Waiting for Apache/startup scripts and health checks..."

SUCCESS=0

for ATTEMPT in {1..18}; do
    RESPONSE="$(curl -fsS --max-time 5 "http://${IPADDRESS}" 2>/dev/null || true)"

    if [[ -n "$RESPONSE" ]]; then
        echo
        echo "Load balancer responded:"
        echo "$RESPONSE"
        SUCCESS=1
        break
    fi

    echo "Attempt ${ATTEMPT}/18 - not ready yet..."
    sleep 10
done

echo
echo "Testing individual web servers..."

for VM in www1 www2 www3; do
    VM_IP="$(
        gcloud compute instances describe "$VM" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
    )"

    echo
    echo "$VM -> $VM_IP"

    curl -fsS --max-time 5 "http://${VM_IP}" || \
        echo "Server may still be initializing."
done

echo
echo "============================================================"

if [[ "$SUCCESS" -eq 1 ]]; then
    echo " GCLOUDOPS AUTOMATION COMPLETE"
else
    echo " RESOURCES CREATED - LOAD BALANCER STILL INITIALIZING"
fi

echo "============================================================"
echo
echo "Project:        $PROJECT_ID"
echo "Region:         $REGION"
echo "Zone:           $ZONE"
echo "Target pool:    www-pool"
echo "Forwarding rule:www-rule"
echo "Load balancer:  http://${IPADDRESS}"
echo
echo "Click Check my progress for the lab objectives."
