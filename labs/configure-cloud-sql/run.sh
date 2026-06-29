#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)

INSTANCE_NAME="wordpress-db"
DATABASE_NAME="wordpress"
PROXY_VM="wordpress-proxy"
PRIVATE_VM="wordpress-private-ip"
STATE_FILE="$HOME/.gcloudops-cloud-sql-state"

if [[ -z "$PROJECT_ID" ]]; then
  echo "No active Google Cloud project found."
  exit 1
fi

if [[ -z "$REGION" ]]; then
  read -r -p "Paste lab REGION value: " REGION < /dev/tty
fi

if [[ -z "$ZONE" ]]; then
  read -r -p "Paste lab ZONE value: " ZONE < /dev/tty
fi

read -r -s -p "Enter Cloud SQL root password to use: " ROOT_PASSWORD < /dev/tty
echo

if [[ -z "$ROOT_PASSWORD" ]]; then
  echo "Root password cannot be empty."
  exit 1
fi

cat > "$STATE_FILE" <<STATE
PROJECT_ID=$PROJECT_ID
REGION=$REGION
ZONE=$ZONE
INSTANCE_NAME=$INSTANCE_NAME
DATABASE_NAME=$DATABASE_NAME
PROXY_VM=$PROXY_VM
PRIVATE_VM=$PRIVATE_VM
ROOT_PASSWORD=$ROOT_PASSWORD
STATE

echo
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Zone: $ZONE"
echo "Cloud SQL instance: $INSTANCE_NAME"
echo

echo "Enabling required APIs..."
gcloud services enable \
  sqladmin.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo
echo "Configuring private services access for default VPC..."
gcloud compute addresses create google-managed-services-default \
  --project="$PROJECT_ID" \
  --global \
  --purpose=VPC_PEERING \
  --prefix-length=16 \
  --network=default \
  --quiet || true

gcloud services vpc-peerings connect \
  --project="$PROJECT_ID" \
  --service=servicenetworking.googleapis.com \
  --ranges=google-managed-services-default \
  --network=default \
  --quiet || true

echo
echo "Creating Cloud SQL MySQL instance..."
gcloud sql instances create "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --database-version=MYSQL_8_0 \
  --edition=ENTERPRISE \
  --tier=db-custom-1-3840 \
  --storage-type=SSD \
  --storage-size=10GB \
  --availability-type=ZONAL \
  --zone="$ZONE" \
  --root-password="$ROOT_PASSWORD" \
  --network=default \
  --no-assign-ip \
  --authorized-networks=0.0.0.0/0 \
  --quiet || true

echo
echo "Waiting for Cloud SQL instance to become RUNNABLE..."

if ! gcloud sql instances describe "$INSTANCE_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Cloud SQL instance was not created. Check the create command output above."
  exit 1
fi

for i in {1..60}; do
  STATE_SQL=$(gcloud sql instances describe "$INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --format="value(state)" 2>/dev/null || true)

  if [[ "$STATE_SQL" == "RUNNABLE" ]]; then
    echo "Cloud SQL is RUNNABLE."
    break
  fi

  echo "Cloud SQL state: ${STATE_SQL:-unknown}. Waiting 20 seconds..."
  sleep 20
done

echo
echo "Creating wordpress database..."
gcloud sql databases create "$DATABASE_NAME" \
  --instance="$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --quiet || true

SQL_CONNECTION_NAME=$(gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --format="value(connectionName)")

SQL_PRIVATE_IP=$(gcloud sql instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --format="value(ipAddresses.filter(type=PRIVATE).ipAddress)")

cat >> "$STATE_FILE" <<STATE
SQL_CONNECTION_NAME=$SQL_CONNECTION_NAME
SQL_PRIVATE_IP=$SQL_PRIVATE_IP
STATE

echo
echo "SQL connection name: $SQL_CONNECTION_NAME"
echo "SQL private IP: $SQL_PRIVATE_IP"
echo

echo "Configuring Cloud SQL proxy on $PROXY_VM..."
gcloud compute ssh "$PROXY_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="
    set -e
    wget -q https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64 -O cloud_sql_proxy
    chmod +x cloud_sql_proxy
    pkill -f cloud_sql_proxy || true
    nohup ./cloud_sql_proxy -instances=${SQL_CONNECTION_NAME}=tcp:3306 > cloud_sql_proxy.log 2>&1 &
    sleep 5
    cat cloud_sql_proxy.log || true
  "

echo
echo "Testing proxy listener on $PROXY_VM..."
gcloud compute ssh "$PROXY_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --quiet \
  --command="ss -ltnp | grep 3306 || true"

PROXY_EXTERNAL_IP=$(gcloud compute instances describe "$PROXY_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

PRIVATE_EXTERNAL_IP=$(gcloud compute instances describe "$PRIVATE_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)

cat >> "$STATE_FILE" <<STATE
PROXY_EXTERNAL_IP=$PROXY_EXTERNAL_IP
PRIVATE_EXTERNAL_IP=$PRIVATE_EXTERNAL_IP
STATE

echo
echo "============================================================"
echo "Checkpoint 1:"
echo "Cloud SQL instance and wordpress database have been created."
echo "Click Check my progress for: Create a Cloud SQL instance"
echo "Then click Check my progress for: Create a database and configure a proxy on a Virtual Machine"
echo "============================================================"
echo

echo "WordPress proxy setup:"
echo "URL: http://${PROXY_EXTERNAL_IP}"
echo "Database Name: wordpress"
echo "Username: root"
echo "Password: $ROOT_PASSWORD"
echo "Database Host: 127.0.0.1"
echo

read -r -p "Press ENTER after completing the WordPress installer on wordpress-proxy..." _ < /dev/tty

echo
echo "Getting Private IP VM details..."
if [[ -z "$PRIVATE_EXTERNAL_IP" ]]; then
  echo "Could not automatically find external IP for $PRIVATE_VM."
  gcloud compute instances list --project="$PROJECT_ID"
else
  echo "WordPress private IP setup:"
  echo "URL: http://${PRIVATE_EXTERNAL_IP}"
  echo "Database Name: wordpress"
  echo "Username: root"
  echo "Password: $ROOT_PASSWORD"
  echo "Database Host: $SQL_PRIVATE_IP"
fi

echo
echo "============================================================"
echo "Checkpoint 2:"
echo "Open the private IP WordPress site and configure using the SQL private IP."
echo "If WordPress says Already Installed, the private IP connection is working."
echo "============================================================"
echo

echo "Automation complete."
echo "State file: $STATE_FILE"
