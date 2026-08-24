#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="${REGION:-}"
ZONE="${ZONE:-}"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

if [[ -z "$ZONE" ]]; then
  read -r -p "Paste lab ZONE value: " ZONE < /dev/tty
fi

if [[ -z "$REGION" || -z "$ZONE" ]]; then
  echo "ERROR: REGION and ZONE are required."
  exit 1
fi

echo
echo "============================================================"
echo " GCloudOps :: Set Up Application Load Balancer"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo

echo "[1/13] Setting defaults..."

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

echo
echo "[2/13] Enabling Compute Engine API..."

gcloud services enable compute.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "[3/13] Creating www1, www2, www3..."

for VM in www1 www2 www3; do
  if gcloud compute instances describe "$VM" \
      --zone="$ZONE" \
      --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "$VM already exists."

  else
    gcloud compute instances create "$VM" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" \
      --tags=network-lb-tag \
      --machine-type=e2-small \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --metadata=startup-script="#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo '<h3>Web Server: ${VM}</h3>' > /var/www/html/index.html" \
      --quiet
  fi
done

echo
echo "[4/13] Creating www firewall rule..."

if ! gcloud compute firewall-rules describe www-firewall-network-lb \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute firewall-rules create www-firewall-network-lb \
    --project="$PROJECT_ID" \
    --target-tags=network-lb-tag \
    --allow=tcp:80 \
    --quiet
else
  echo "www-firewall-network-lb already exists."
fi

echo
echo "[5/13] Creating backend instance template..."

cat >/tmp/lb-startup.sh <<'STARTUP'
#!/bin/bash
apt-get update
apt-get install apache2 -y
a2ensite default-ssl
a2enmod ssl
vm_hostname="$(curl -s -H 'Metadata-Flavor: Google' \
http://169.254.169.254/computeMetadata/v1/instance/name)"
echo "Page served from: ${vm_hostname}" > /var/www/html/index.html
systemctl restart apache2
STARTUP

if ! gcloud compute instance-templates describe lb-backend-template \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute instance-templates create lb-backend-template \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network=default \
    --subnet=default \
    --tags=allow-health-check \
    --machine-type=e2-medium \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --metadata-from-file=startup-script=/tmp/lb-startup.sh \
    --quiet
else
  echo "lb-backend-template already exists."
fi

echo
echo "[6/13] Creating managed instance group..."

if ! gcloud compute instance-groups managed describe lb-backend-group \
    --zone="$ZONE" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute instance-groups managed create lb-backend-group \
    --project="$PROJECT_ID" \
    --template=lb-backend-template \
    --size=2 \
    --zone="$ZONE" \
    --quiet
else
  echo "lb-backend-group already exists."
fi

gcloud compute instance-groups managed set-named-ports lb-backend-group \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --named-ports=http:80 \
  --quiet

echo
echo "[7/13] Creating health-check firewall rule..."

if ! gcloud compute firewall-rules describe fw-allow-health-check \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute firewall-rules create fw-allow-health-check \
    --project="$PROJECT_ID" \
    --network=default \
    --action=allow \
    --direction=ingress \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags=allow-health-check \
    --rules=tcp:80 \
    --quiet
else
  echo "fw-allow-health-check already exists."
fi

echo
echo "[8/13] Creating global static IP..."

if ! gcloud compute addresses describe lb-ipv4-1 \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute addresses create lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --ip-version=IPV4 \
    --global \
    --quiet
else
  echo "lb-ipv4-1 already exists."
fi

LB_IP="$(
  gcloud compute addresses describe lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --global \
    --format="get(address)"
)"

echo "Load balancer IP: $LB_IP"

echo
echo "[9/13] Creating HTTP health check..."

if ! gcloud compute health-checks describe http-basic-check \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute health-checks create http http-basic-check \
    --project="$PROJECT_ID" \
    --port=80 \
    --quiet
else
  echo "http-basic-check already exists."
fi

echo
echo "[10/13] Creating backend service..."

if ! gcloud compute backend-services describe web-backend-service \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute backend-services create web-backend-service \
    --project="$PROJECT_ID" \
    --protocol=HTTP \
    --port-name=http \
    --health-checks=http-basic-check \
    --global \
    --quiet
else
  echo "web-backend-service already exists."
fi

BACKENDS="$(
  gcloud compute backend-services describe web-backend-service \
    --project="$PROJECT_ID" \
    --global \
    --format="value(backends.group)" 2>/dev/null || true
)"

if [[ "$BACKENDS" != *"/instanceGroups/lb-backend-group"* ]]; then
  gcloud compute backend-services add-backend web-backend-service \
    --project="$PROJECT_ID" \
    --instance-group=lb-backend-group \
    --instance-group-zone="$ZONE" \
    --global \
    --quiet
else
  echo "lb-backend-group already attached."
fi

echo
echo "[11/13] Creating URL map..."

if ! gcloud compute url-maps describe web-map-http \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute url-maps create web-map-http \
    --project="$PROJECT_ID" \
    --default-service=web-backend-service \
    --quiet
else
  echo "web-map-http already exists."
fi

echo
echo "[12/13] Creating HTTP proxy..."

if ! gcloud compute target-http-proxies describe http-lb-proxy \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute target-http-proxies create http-lb-proxy \
    --project="$PROJECT_ID" \
    --url-map=web-map-http \
    --quiet
else
  echo "http-lb-proxy already exists."
fi

echo
echo "[13/13] Creating forwarding rule..."

if ! gcloud compute forwarding-rules describe http-content-rule \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute forwarding-rules create http-content-rule \
    --project="$PROJECT_ID" \
    --address=lb-ipv4-1 \
    --global \
    --target-http-proxy=http-lb-proxy \
    --ports=80 \
    --quiet
else
  echo "http-content-rule already exists."
fi

echo
echo "Waiting for load balancer..."

for ATTEMPT in {1..30}; do
  RESPONSE="$(curl -fsS --max-time 5 "http://${LB_IP}" 2>/dev/null || true)"

  if [[ "$RESPONSE" == *"Page served from:"* ]]; then
    echo
    echo "$RESPONSE"
    break
  fi

  echo "Waiting... $ATTEMPT/30"
  sleep 10
done

echo
echo "Backend health:"
gcloud compute backend-services get-health web-backend-service \
  --project="$PROJECT_ID" \
  --global || true

echo
echo "============================================================"
echo " Automation complete"
echo "============================================================"
echo "Load balancer: http://${LB_IP}"
