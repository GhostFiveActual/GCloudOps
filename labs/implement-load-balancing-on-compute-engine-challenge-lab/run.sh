#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="${REGION:-}"
ZONE="${ZONE:-}"
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-12}"

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

echo
echo "============================================================"
echo " GCloudOps :: Implement Load Balancing Challenge Lab"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo "Image:   $IMAGE_FAMILY"
echo

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

gcloud services enable compute.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# ============================================================
# TASK 1
# THREE WEB SERVERS
# ============================================================

echo
echo "============================================================"
echo " TASK 1 :: Creating web1, web2, web3"
echo "============================================================"

for VM in web1 web2 web3; do

  if gcloud compute instances describe "$VM" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" >/dev/null 2>&1; then

    echo "$VM already exists."

  else

    echo "Creating $VM..."

    gcloud compute instances create "$VM" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" \
      --network=default \
      --tags=network-lb-tag \
      --machine-type=e2-small \
      --image-family="$IMAGE_FAMILY" \
      --image-project=debian-cloud \
      --metadata=startup-script="#!/bin/bash
apt-get update
apt-get install apache2 -y
service apache2 restart
echo '<h3>Web Server: ${VM}</h3>' | tee /var/www/html/index.html" \
      --quiet

  fi

done

echo
echo "Creating www-firewall-network-lb..."

if ! gcloud compute firewall-rules describe www-firewall-network-lb \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute firewall-rules create www-firewall-network-lb \
    --project="$PROJECT_ID" \
    --network=default \
    --target-tags=network-lb-tag \
    --allow=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --quiet

else
  echo "www-firewall-network-lb already exists."
fi

echo
echo "Waiting briefly for Apache..."
sleep 15

for VM in web1 web2 web3; do

  VM_IP="$(
    gcloud compute instances describe "$VM" \
      --project="$PROJECT_ID" \
      --zone="$ZONE" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
  )"

  echo "$VM -> $VM_IP"

  curl -fsS --max-time 5 "http://${VM_IP}" || \
    echo "$VM is still initializing."

  echo
done

echo
echo "TASK 1 COMPLETE"
echo "Click Check my progress for: Create multiple web server instances"
echo
read -r -p "Press ENTER to continue to Task 2..." _ < /dev/tty

# ============================================================
# TASK 2
# NETWORK LOAD BALANCER
# ============================================================

echo
echo "============================================================"
echo " TASK 2 :: Network Load Balancer"
echo "============================================================"

echo "Creating regional static IP network-lb-ip-1..."

if ! gcloud compute addresses describe network-lb-ip-1 \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

  gcloud compute addresses create network-lb-ip-1 \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --quiet

else
  echo "network-lb-ip-1 already exists."
fi

echo
echo "Creating legacy health check basic-check..."

if ! gcloud compute http-health-checks describe basic-check \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute http-health-checks create basic-check \
    --project="$PROJECT_ID" \
    --quiet

else
  echo "basic-check already exists."
fi

echo
echo "Creating target pool www-pool..."

if ! gcloud compute target-pools describe www-pool \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

  gcloud compute target-pools create www-pool \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --http-health-check=basic-check \
    --quiet

else
  echo "www-pool already exists."
fi

CURRENT_POOL="$(
  gcloud compute target-pools describe www-pool \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format="value(instances)" 2>/dev/null || true
)"

MISSING=()

for VM in web1 web2 web3; do
  if [[ "$CURRENT_POOL" != *"/instances/${VM}"* ]]; then
    MISSING+=("$VM")
  fi
done

if (( ${#MISSING[@]} > 0 )); then

  INSTANCES="$(IFS=,; echo "${MISSING[*]}")"

  echo "Adding $INSTANCES to www-pool..."

  gcloud compute target-pools add-instances www-pool \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --instances="$INSTANCES" \
    --instances-zone="$ZONE" \
    --quiet

else
  echo "All web servers are already in www-pool."
fi

echo
echo "Creating forwarding rule www-rule..."

if ! gcloud compute forwarding-rules describe www-rule \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

  gcloud compute forwarding-rules create www-rule \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --ports=80 \
    --address=network-lb-ip-1 \
    --target-pool=www-pool \
    --quiet

else
  echo "www-rule already exists."
fi

NETWORK_LB_IP="$(
  gcloud compute forwarding-rules describe www-rule \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format="value(IPAddress)"
)"

echo
echo "Network Load Balancer IP: $NETWORK_LB_IP"

for i in {1..12}; do

  RESPONSE="$(
    curl -fsS --max-time 5 "http://${NETWORK_LB_IP}" 2>/dev/null || true
  )"

  if [[ "$RESPONSE" == *"Web Server:"* ]]; then
    echo "$RESPONSE"
    break
  fi

  echo "Waiting for NLB... $i/12"
  sleep 10
done

echo
echo "TASK 2 COMPLETE"
echo "Click Check my progress for: Configure the load balancing service"
echo
read -r -p "Press ENTER to continue to Task 3..." _ < /dev/tty

# ============================================================
# TASK 3
# HTTP APPLICATION LOAD BALANCER
# ============================================================

echo
echo "============================================================"
echo " TASK 3 :: HTTP Application Load Balancer"
echo "============================================================"

echo "Creating backend startup script..."

cat >/tmp/lb-backend-startup.sh <<'STARTUP'
#!/bin/bash

apt-get update
apt-get install apache2 -y
a2ensite default-ssl
a2enmod ssl

vm_hostname="$(curl -s \
  -H 'Metadata-Flavor: Google' \
  http://169.254.169.254/computeMetadata/v1/instance/name)"

echo "Page served from: ${vm_hostname}" \
  > /var/www/html/index.html

systemctl restart apache2
STARTUP

echo
echo "Creating lb-backend-template..."

if ! gcloud compute instance-templates describe lb-backend-template \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud compute instance-templates create lb-backend-template \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network=default \
    --subnet=default \
    --tags=allow-health-check \
    --machine-type=e2-medium \
    --image-family="$IMAGE_FAMILY" \
    --image-project=debian-cloud \
    --metadata-from-file=startup-script=/tmp/lb-backend-startup.sh \
    --quiet

else
  echo "lb-backend-template already exists."
fi

echo
echo "Creating lb-backend-group..."

if ! gcloud compute instance-groups managed describe lb-backend-group \
    --project="$PROJECT_ID" \
    --zone="$ZONE" >/dev/null 2>&1; then

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
echo "Creating fw-allow-health-check..."

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
echo "Creating lb-ipv4-1..."

if ! gcloud compute addresses describe lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --global >/dev/null 2>&1; then

  gcloud compute addresses create lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --ip-version=IPV4 \
    --global \
    --quiet

else
  echo "lb-ipv4-1 already exists."
fi

HTTP_LB_IP="$(
  gcloud compute addresses describe lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --global \
    --format="value(address)"
)"

echo "HTTP Load Balancer IP: $HTTP_LB_IP"

echo
echo "Creating http-basic-check..."

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
echo "Creating backend service..."

if ! gcloud compute backend-services describe web-backend-service \
    --project="$PROJECT_ID" \
    --global >/dev/null 2>&1; then

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

  echo "Adding lb-backend-group to backend service..."

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
echo "Creating web-map-http..."

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
echo "Creating http-lb-proxy..."

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
echo "Creating HTTP forwarding rule..."

if ! gcloud compute forwarding-rules describe http-content-rule \
    --project="$PROJECT_ID" \
    --global >/dev/null 2>&1; then

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
echo "Waiting for HTTP load balancer..."

SUCCESS=0

for i in {1..30}; do

  RESPONSE="$(
    curl -fsS --max-time 10 "http://${HTTP_LB_IP}" 2>/dev/null || true
  )"

  if [[ "$RESPONSE" == *"Page served from:"* ]]; then
    echo
    echo "$RESPONSE"
    SUCCESS=1
    break
  fi

  echo "Waiting for healthy backend... $i/30"
  sleep 10

done

echo
echo "Backend health:"

gcloud compute backend-services get-health web-backend-service \
  --project="$PROJECT_ID" \
  --global || true

echo
echo "============================================================"
echo " GSP313 AUTOMATION COMPLETE"
echo "============================================================"
echo
echo "Task 1:"
echo "  web1"
echo "  web2"
echo "  web3"
echo "  www-firewall-network-lb"
echo
echo "Task 2:"
echo "  network-lb-ip-1"
echo "  basic-check"
echo "  www-pool"
echo "  www-rule"
echo "  NLB IP: http://${NETWORK_LB_IP}"
echo
echo "Task 3:"
echo "  lb-backend-template"
echo "  lb-backend-group"
echo "  fw-allow-health-check"
echo "  lb-ipv4-1"
echo "  http-basic-check"
echo "  web-backend-service"
echo "  web-map-http"
echo "  http-lb-proxy"
echo "  http-content-rule"
echo "  HTTP LB: http://${HTTP_LB_IP}"
echo

if [[ "$SUCCESS" -eq 1 ]]; then
  echo "HTTP LOAD BALANCER: RESPONDING"
else
  echo "HTTP LOAD BALANCER: Still propagating."
fi

echo
echo "Click the remaining Check my progress buttons."
