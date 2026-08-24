#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "ERROR: No active Google Cloud project."
    exit 1
fi

read_tty() {
    local prompt="$1"
    local value
    read -r -p "$prompt" value </dev/tty
    printf '%s' "$value"
}

REGION="${REGION:-}"
ZONE="${ZONE:-}"
SOURCE_IP="${SOURCE_IP:-}"
ILB_IP="${ILB_IP:-}"

[[ -n "$REGION" ]] || REGION="$(read_tty 'Paste lab REGION value: ')"
[[ -n "$ZONE" ]] || ZONE="$(read_tty 'Paste lab ZONE value: ')"
[[ -n "$SOURCE_IP" ]] || SOURCE_IP="$(read_tty 'Paste lab IP value used for the backend firewall source range: ')"
[[ -n "$ILB_IP" ]] || ILB_IP="$(read_tty 'Paste lab IP value used for the internal load balancer: ')"

echo
echo "============================================================"
echo " GCloudOps :: GSP041 Internal Application Load Balancer"
echo "============================================================"
echo "Project:        $PROJECT_ID"
echo "Region:         $REGION"
echo "Zone:           $ZONE"
echo "Firewall IP:    $SOURCE_IP"
echo "Internal LB IP: $ILB_IP"
echo

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

echo
echo "[1/10] Enabling Compute Engine API..."

gcloud services enable compute.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

# ------------------------------------------------------------
# BACKEND STARTUP SCRIPT
# ------------------------------------------------------------

echo
echo "[2/10] Creating backend startup script..."

cat > /tmp/backend.sh <<'BACKEND'
#!/bin/bash

chmod -R 777 /usr/local/sbin/

cat > /usr/local/sbin/serveprimes.py <<'PY'
import http.server

def is_prime(a):
    return a != 1 and all(
        a % i for i in range(2, int(a**0.5) + 1)
    )

class myHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200)
        s.send_header("Content-type", "text/plain")
        s.end_headers()

        try:
            number = int(s.path[1:])
            result = str(is_prime(number))
        except Exception:
            result = "False"

        s.wfile.write(result.encode("utf-8"))

http.server.HTTPServer(("", 80), myHandler).serve_forever()
PY

nohup python3 /usr/local/sbin/serveprimes.py >/var/log/serveprimes.log 2>&1 &
BACKEND

# ------------------------------------------------------------
# INSTANCE TEMPLATE
# ------------------------------------------------------------

echo
echo "[3/10] Creating primecalc instance template..."

if gcloud compute instance-templates describe primecalc \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "primecalc already exists."

else

    gcloud compute instance-templates create primecalc \
        --project="$PROJECT_ID" \
        --metadata-from-file startup-script=/tmp/backend.sh \
        --no-address \
        --tags=backend \
        --machine-type=e2-medium \
        --quiet

fi

# ------------------------------------------------------------
# BACKEND FIREWALL
# ------------------------------------------------------------

echo
echo "[4/10] Creating backend HTTP firewall rule..."

if gcloud compute firewall-rules describe http \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "Firewall rule http already exists."

else

    gcloud compute firewall-rules create http \
        --project="$PROJECT_ID" \
        --network=default \
        --allow=tcp:80 \
        --source-ranges="$SOURCE_IP" \
        --target-tags=backend \
        --quiet

fi

# ------------------------------------------------------------
# MANAGED INSTANCE GROUP
# ------------------------------------------------------------

echo
echo "[5/10] Creating backend managed instance group..."

if gcloud compute instance-groups managed describe backend \
    --project="$PROJECT_ID" \
    --zone="$ZONE" >/dev/null 2>&1; then

    echo "backend instance group already exists."

else

    gcloud compute instance-groups managed create backend \
        --project="$PROJECT_ID" \
        --size=3 \
        --template=primecalc \
        --zone="$ZONE" \
        --quiet

fi

echo
echo "Waiting for backend instances..."

gcloud compute instance-groups managed wait-until backend \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --stable \
    --timeout=300 || true

# ------------------------------------------------------------
# HEALTH CHECK
# ------------------------------------------------------------

echo
echo "[6/10] Creating ilb-health..."

if gcloud compute health-checks describe ilb-health \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "ilb-health already exists."

else

    gcloud compute health-checks create http ilb-health \
        --project="$PROJECT_ID" \
        --request-path=/2 \
        --quiet

fi

# ------------------------------------------------------------
# BACKEND SERVICE
# ------------------------------------------------------------

echo
echo "[7/10] Creating prime-service..."

if gcloud compute backend-services describe prime-service \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    echo "prime-service already exists."

else

    gcloud compute backend-services create prime-service \
        --project="$PROJECT_ID" \
        --load-balancing-scheme=internal \
        --region="$REGION" \
        --protocol=tcp \
        --health-checks=ilb-health \
        --health-checks-region="$REGION" \
        --quiet 2>/dev/null || \
    gcloud compute backend-services create prime-service \
        --project="$PROJECT_ID" \
        --load-balancing-scheme=internal \
        --region="$REGION" \
        --protocol=tcp \
        --health-checks=ilb-health \
        --quiet

fi

BACKENDS="$(
    gcloud compute backend-services describe prime-service \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="value(backends.group)" 2>/dev/null || true
)"

if [[ "$BACKENDS" == *"/instanceGroups/backend"* ]]; then
    echo "backend already attached to prime-service."
else

    echo "Attaching backend instance group..."

    gcloud compute backend-services add-backend prime-service \
        --project="$PROJECT_ID" \
        --instance-group=backend \
        --instance-group-zone="$ZONE" \
        --region="$REGION" \
        --quiet

fi

# ------------------------------------------------------------
# FORWARDING RULE
# ------------------------------------------------------------

echo
echo "[8/10] Creating prime-lb..."

if gcloud compute forwarding-rules describe prime-lb \
    --project="$PROJECT_ID" \
    --region="$REGION" >/dev/null 2>&1; then

    echo "prime-lb already exists."

else

    gcloud compute forwarding-rules create prime-lb \
        --project="$PROJECT_ID" \
        --load-balancing-scheme=internal \
        --ports=80 \
        --network=default \
        --region="$REGION" \
        --address="$ILB_IP" \
        --backend-service=prime-service \
        --quiet

fi

# ------------------------------------------------------------
# FRONTEND STARTUP
# ------------------------------------------------------------

echo
echo "[9/10] Creating frontend..."

cat > /tmp/frontend.sh <<FRONTEND
#!/bin/bash

chmod -R 777 /usr/local/sbin/

cat > /usr/local/sbin/getprimes.py <<'PY'
import urllib.request
from multiprocessing.dummy import Pool as ThreadPool
import http.server

PREFIX = "http://${ILB_IP}/"

def get_url(number):
    return urllib.request.urlopen(
        PREFIX + str(number),
        timeout=5
    ).read().decode("utf-8")

class myHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(s):

        s.send_response(200)
        s.send_header("Content-type", "text/html")
        s.end_headers()

        try:
            i = int(s.path[1:]) if len(s.path) > 1 else 1
        except:
            i = 1

        s.wfile.write(b"<html><body><table>")

        pool = ThreadPool(10)
        results = pool.map(get_url, range(i, i + 100))
        pool.close()
        pool.join()

        for x in range(100):

            if not (x % 10):
                s.wfile.write(b"<tr>")

            if results[x] == "True":
                s.wfile.write(b"<td bgcolor='#00ff00'>")
            else:
                s.wfile.write(b"<td bgcolor='#ff0000'>")

            s.wfile.write(
                (str(x + i) + "</td> ").encode("utf-8")
            )

            if not ((x + 1) % 10):
                s.wfile.write(b"</tr>")

        s.wfile.write(b"</table></body></html>")

http.server.HTTPServer(("",80),myHandler).serve_forever()
PY

nohup python3 /usr/local/sbin/getprimes.py >/var/log/getprimes.log 2>&1 &
FRONTEND

if gcloud compute instances describe frontend \
    --project="$PROJECT_ID" \
    --zone="$ZONE" >/dev/null 2>&1; then

    echo "frontend already exists."

else

    gcloud compute instances create frontend \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --metadata-from-file startup-script=/tmp/frontend.sh \
        --tags=frontend \
        --machine-type=e2-standard-2 \
        --quiet

fi

# ------------------------------------------------------------
# FRONTEND FIREWALL
# ------------------------------------------------------------

echo
echo "[10/10] Creating frontend firewall..."

if gcloud compute firewall-rules describe http2 \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    echo "Firewall rule http2 already exists."

else

    gcloud compute firewall-rules create http2 \
        --project="$PROJECT_ID" \
        --network=default \
        --allow=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=frontend \
        --quiet

fi

# ------------------------------------------------------------
# RESULTS
# ------------------------------------------------------------

echo
echo "Waiting briefly for startup scripts..."
sleep 20

FRONTEND_IP="$(
    gcloud compute instances describe frontend \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
)"

echo
echo "============================================================"
echo " GSP041 AUTOMATION COMPLETE"
echo "============================================================"
echo
echo "Project:         $PROJECT_ID"
echo "Backend MIG:     backend"
echo "Backend service: prime-service"
echo "Internal LB:     $ILB_IP"
echo "Frontend IP:     $FRONTEND_IP"
echo
echo "Frontend:"
echo "http://${FRONTEND_IP}"
echo
echo "Prime calculator tests:"
echo "  ${ILB_IP}/2  -> True"
echo "  ${ILB_IP}/4  -> False"
echo "  ${ILB_IP}/5  -> True"
echo
echo "Click Check my progress for each lab objective."
echo "============================================================"
