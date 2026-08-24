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
echo " GCloudOps :: Application Load Balancer"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo

echo "[1/13] Setting default region and zone..."

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
        echo "Creating $VM..."

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
systemctl restart apache2
echo '<h3>Web Server: $VM</h3>' > /var/www/html/index.html" \
            --quiet
    fi

done

echo
echo "[4/13] Creating web-server firewall rule..."

if gcloud compute firewall-rules describe www-firewall-network-lb \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "www-firewall-network-lb already exists."

else

    gcloud compute firewall-rules create www-firewall-network-lb \
        --project="$PROJECT_ID" \
        --target-tags=network-lb-tag \
        --allow=tcp:80 \
        --quiet
fi

echo
echo "Web server instances:"
gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="name=(www1 www2 www3)" \
    --format="table(name,zone.basename(),status,networkInterfaces[0].accessConfigs[0].natIP)"

echo
echo "[5/13] Creating load balancer instance template..."

if gcloud compute instance-templates describe lb-backend-template \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "lb-backend-template already exists."

else

    cat >/tmp/lb-startup.sh <<'STARTUP'
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
fi

echo
echo "[6/13] Creating managed instance group..."

if gcloud compute instance-groups managed describe lb-backend-group \
    --zone="$ZONE" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "lb-backend-group already exists."

else

    gcloud compute instance-groups managed create lb-backend-group \
        --project="$PROJECT_ID" \
        --template=lb-backend-template \
        --size=2 \
        --zone="$ZONE" \
        --quiet
fi

echo
echo "[7/13] Setting named port..."

gcloud compute instance-groups managed set-named-ports lb-backend-group \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --named-ports=http:80 \
    --quiet

echo
echo "[8/13] Creating health-check firewall rule..."

if gcloud compute firewall-rules describe fw-allow-health-check \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "fw-allow-health-check already exists."

else

    gcloud compute firewall-rules create fw-allow-health-check \
        --project="$PROJECT_ID" \
        --network=default \
        --action=allow \
        --direction=ingress \
        --source-ranges=130.211.0.0/22,35.191.0.0/16 \
        --target-tags=allow-health-check \
        --rules=tcp:80 \
        --quiet
fi

echo
echo "[9/13] Reserving global IPv4 address..."

if gcloud compute addresses describe lb-ipv4-1 \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "lb-ipv4-1 already exists."

else

    gcloud compute addresses create lb-ipv4-1 \
        --project="$PROJECT_ID" \
        --ip-version=IPV4 \
        --global \
        --quiet
fi

LB_IP="$(gcloud compute addresses describe lb-ipv4-1 \
    --project="$PROJECT_ID" \
    --global \
    --format='get(address)')"

echo "Load Balancer IP: $LB_IP"

echo
echo "[10/13] Creating HTTP health check..."

if gcloud compute health-checks describe http-basic-check \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "http-basic-check already exists."

else

    gcloud compute health-checks create http http-basic-check \
        --project="$PROJECT_ID" \
        --port=80 \
        --quiet
fi

echo
echo "[11/13] Creating backend service..."

if gcloud compute backend-services describe web-backend-service \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "web-backend-service already exists."

else

    gcloud compute backend-services create web-backend-service \
        --project="$PROJECT_ID" \
        --protocol=HTTP \
        --port-name=http \
        --health-checks=http-basic-check \
        --global \
        --quiet
fi

BACKENDS="$(gcloud compute backend-services describe web-backend-service \
    --project="$PROJECT_ID" \
    --global \
    --format='value(backends.group)' 2>/dev/null || true)"

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
echo "[12/13] Creating URL map and HTTP proxy..."

if gcloud compute url-maps describe web-map-http \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "web-map-http already exists."

else

    gcloud compute url-maps create web-map-http \
        --project="$PROJECT_ID" \
        --default-service=web-backend-service \
        --quiet
fi

if gcloud compute target-http-proxies describe http-lb-proxy \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "http-lb-proxy already exists."

else

    gcloud compute target-http-proxies create http-lb-proxy \
        --project="$PROJECT_ID" \
        --url-map=web-map-http \
        --quiet
fi

echo
echo "[13/13] Creating global forwarding rule..."

if gcloud compute forwarding-rules describe http-content-rule \
    --global \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "http-content-rule already exists."

else

    gcloud compute forwarding-rules create http-content-rule \
        --project="$PROJECT_ID" \
        --address=lb-ipv4-1 \
        --global \
        --target-http-proxy=http-lb-proxy \
        --ports=80 \
        --quiet
fi

echo
echo "============================================================"
echo " Waiting for Application Load Balancer"
echo "============================================================"
echo
echo "IP: http://${LB_IP}"
echo

SUCCESS=0

for ATTEMPT in {1..30}; do

    RESPONSE="$(curl -fsS \
        --connect-timeout 5 \
        --max-time 10 \
        "http://${LB_IP}/" 2>/dev/null || true)"

    if [[ "$RESPONSE" == *"Page served from:"* ]]; then

        echo
        echo "Load balancer is responding:"
        echo "$RESPONSE"
        SUCCESS=1
        break
    fi

    echo "Waiting for healthy backend... ($ATTEMPT/30)"
    sleep 10
done

echo
echo "Backend health:"

gcloud compute backend-services get-health web-backend-service \
    --project="$PROJECT_ID" \
    --global || true

echo
echo "============================================================"
echo " GCLOUDOPS AUTOMATION COMPLETE"
echo "============================================================"
echo
echo "Project:          $PROJECT_ID"
echo "Region:           $REGION"
echo "Zone:             $ZONE"
echo
echo "Web Servers:"
echo "  www1"
echo "  www2"
echo "  www3"
echo
echo "Application Load Balancer:"
echo "  Template:        lb-backend-template"
echo "  Instance Group:  lb-backend-group"
echo "  Health Check:    http-basic-check"
echo "  Backend Service: web-backend-service"
echo "  URL Map:         web-map-http"
echo "  HTTP Proxy:      http-lb-proxy"
echo "  Forwarding Rule: http-content-rule"
echo "  External IP:     $LB_IP"
echo

if [[ "$SUCCESS" -eq 1 ]]; then
    echo "STATUS: LOAD BALANCER RESPONDING"
else
    echo "STATUS: Resources created."
    echo "Google's load balancer may still be propagating."
fi

echo
echo "Click Check my progress for:"
echo "  1. Create multiple web server instances"
echo "  2. Create an Application Load Balancer"
echo "  3. Test the load balancer"
echo
