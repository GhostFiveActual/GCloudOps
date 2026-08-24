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

echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

gcloud services enable compute.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "Creating www1, www2, www3..."

for VM in www1 www2 www3; do
  if ! gcloud compute instances describe "$VM" \
      --zone="$ZONE" \
      --project="$PROJECT_ID" >/dev/null 2>&1; then

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
echo "Creating www firewall rule..."

gcloud compute firewall-rules create www-firewall-network-lb \
  --project="$PROJECT_ID" \
  --target-tags=network-lb-tag \
  --allow=tcp:80 \
  --quiet || true

echo
echo "Creating backend instance template..."

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
  --quiet || true

echo
echo "Creating managed instance group..."

gcloud compute instance-groups managed create lb-backend-group \
  --project="$PROJECT_ID" \
  --template=lb-backend-template \
  --size=2 \
  --zone="$ZONE" \
  --quiet || true

gcloud compute instance-groups managed set-named-ports lb-backend-group \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --named-ports=http:80 \
  --quiet

echo
echo "Creating health-check firewall rule..."

gcloud compute firewall-rules create fw-allow-health-check \
  --project="$PROJECT_ID" \
  --network=default \
  --action=allow \
  --direction=ingress \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-check \
  --rules=tcp:80 \
  --quiet || true

echo
echo "Creating global static IP..."

gcloud compute addresses create lb-ipv4-1 \
  --project="$PROJECT_ID" \
  --ip-version=IPV4 \
  --global \
  --quiet || true

echo
echo "Creating HTTP health check..."

gcloud compute health-checks create http http-basic-check \
  --project="$PROJECT_ID" \
  --port=80 \
  --quiet || true

echo
echo "Creating backend service..."

gcloud compute backend-services create web-backend-service \
  --project="$PROJECT_ID" \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-basic-check \
  --global \
  --quiet || true

echo
echo "Attaching instance group..."

gcloud compute backend-services add-backend web-backend-service \
  --project="$PROJECT_ID" \
  --instance-group=lb-backend-group \
  --instance-group-zone="$ZONE" \
  --global \
  --quiet || true

echo
echo "Creating URL map..."

gcloud compute url-maps create web-map-http \
  --project="$PROJECT_ID" \
  --default-service=web-backend-service \
  --quiet || true

echo
echo "Creating HTTP proxy..."

gcloud compute target-http-proxies create http-lb-proxy \
  --project="$PROJECT_ID" \
  --url-map=web-map-http \
  --quiet || true

echo
echo "Creating forwarding rule..."

gcloud compute forwarding-rules create http-content-rule \
  --project="$PROJECT_ID" \
  --address=lb-ipv4-1 \
  --global \
  --target-http-proxy=http-lb-proxy \
  --ports=80 \
  --quiet || true

LB_IP="$(gcloud compute addresses describe lb-ipv4-1 \
  --project="$PROJECT_ID" \
  --global \
  --format='get(address)')"

echo
echo "Load balancer IP: $LB_IP"
echo
echo "Waiting for backend health..."

for i in {1..30}; do
  RESPONSE="$(curl -fsS --max-time 5 "http://${LB_IP}" 2>/dev/null || true)"

  if [[ "$RESPONSE" == *"Page served from:"* ]]; then
    echo "$RESPONSE"
    break
  fi

  echo "Waiting... $i/30"
  sleep 10
done

echo
echo "Backend health:"
gcloud compute backend-services get-health web-backend-service \
  --project="$PROJECT_ID" \
  --global || true

echo
echo "Automation complete."
echo "Load balancer: http://${LB_IP}"
