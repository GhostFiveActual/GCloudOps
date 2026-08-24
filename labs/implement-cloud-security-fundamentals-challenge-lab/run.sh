#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

REGION="${REGION:-}"
ZONE="${ZONE:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-}"

[[ -n "$REGION" ]] || read -r -p "Paste lab REGION: " REGION </dev/tty
[[ -n "$ZONE" ]] || read -r -p "Paste lab ZONE: " ZONE </dev/tty
[[ -n "$CLUSTER_NAME" ]] || read -r -p "Paste exact lab Cluster Name: " CLUSTER_NAME </dev/tty
[[ -n "$SERVICE_ACCOUNT_ID" ]] || read -r -p "Paste exact lab Service Account ID: " SERVICE_ACCOUNT_ID </dev/tty

CUSTOM_ROLE_ID="orcaStorageRole"
CUSTOM_ROLE_TITLE="Custom Security Role"
SUBNET="orca-build-subnet"
JUMPHOST="orca-jumphost"

SA_EMAIL="${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
CUSTOM_ROLE="projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}"

echo
echo "============================================================"
echo " GCloudOps :: GSP342"
echo " Implement Cloud Security Fundamentals"
echo "============================================================"
echo "Project:         $PROJECT_ID"
echo "Region:          $REGION"
echo "Zone:            $ZONE"
echo "Cluster:         $CLUSTER_NAME"
echo "Service Account: $SA_EMAIL"
echo "Subnet:          $SUBNET"
echo "Jumphost:        $JUMPHOST"
echo "============================================================"

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

echo
echo "Enabling required APIs..."

gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# ============================================================
# TASK 1
# CUSTOM SECURITY ROLE
# ============================================================

echo
echo "============================================================"
echo "[1/5] Creating custom security role"
echo "============================================================"

if gcloud iam roles describe "$CUSTOM_ROLE_ID" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "$CUSTOM_ROLE_ID already exists."

  gcloud iam roles update "$CUSTOM_ROLE_ID" \
    --project="$PROJECT_ID" \
    --title="$CUSTOM_ROLE_TITLE" \
    --description="Orca GKE storage object access" \
    --permissions="storage.buckets.get,storage.objects.get,storage.objects.list,storage.objects.update,storage.objects.create" \
    --stage=GA \
    --quiet

else

  gcloud iam roles create "$CUSTOM_ROLE_ID" \
    --project="$PROJECT_ID" \
    --title="$CUSTOM_ROLE_TITLE" \
    --description="Orca GKE storage object access" \
    --permissions="storage.buckets.get,storage.objects.get,storage.objects.list,storage.objects.update,storage.objects.create" \
    --stage=GA \
    --quiet
fi

echo
echo "Custom role:"
gcloud iam roles describe "$CUSTOM_ROLE_ID" \
  --project="$PROJECT_ID" \
  --format="yaml(name,title,includedPermissions,stage)"

echo
echo "TASK 1 COMPLETE"
echo "Click Check my progress: Custom security role"
read -r -p "Press ENTER after Task 1 passes..." _ </dev/tty

# ============================================================
# TASK 2
# SERVICE ACCOUNT
# ============================================================

echo
echo "============================================================"
echo "[2/5] Creating dedicated service account"
echo "============================================================"

if gcloud iam service-accounts describe "$SA_EMAIL" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "$SA_EMAIL already exists."

else

  gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" \
    --project="$PROJECT_ID" \
    --display-name="Service Account"
fi

gcloud iam service-accounts describe "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --format="yaml(email,displayName)"

echo
echo "TASK 2 COMPLETE"
echo "Click Check my progress: Create service account"
read -r -p "Press ENTER after Task 2 passes..." _ </dev/tty

# ============================================================
# TASK 3
# IAM ROLE BINDINGS
# ============================================================

echo
echo "============================================================"
echo "[3/5] Binding least-privilege roles"
echo "============================================================"

ROLES=(
  "roles/monitoring.viewer"
  "roles/monitoring.metricWriter"
  "roles/logging.logWriter"
  "$CUSTOM_ROLE"
)

for ROLE in "${ROLES[@]}"; do

  echo "Binding $ROLE..."

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$ROLE" \
    --condition=None \
    --quiet
done

echo
echo "IAM bindings for cluster service account:"

gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format="table(bindings.role)"

echo
echo "TASK 3 COMPLETE"
echo "Click Check my progress: Bind security roles"
read -r -p "Press ENTER after Task 3 passes..." _ </dev/tty

# ============================================================
# DISCOVER EXISTING ORCA NETWORK RESOURCES
# ============================================================

echo
echo "Discovering Orca Build VPC..."

NETWORK_URL="$(
  gcloud compute networks subnets describe "$SUBNET" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --format="value(network)"
)"

NETWORK="${NETWORK_URL##*/}"

if [[ -z "$NETWORK" ]]; then
  echo "ERROR: Could not determine network containing $SUBNET."
  exit 1
fi

echo "Network: $NETWORK"

echo
echo "Finding orca-jumphost..."

JUMP_ZONE="$(
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="name=${JUMPHOST}" \
    --format="value(zone.basename())" \
    --limit=1
)"

if [[ -z "$JUMP_ZONE" ]]; then
  echo "ERROR: orca-jumphost was not found."
  exit 1
fi

JUMP_IP="$(
  gcloud compute instances describe "$JUMPHOST" \
    --project="$PROJECT_ID" \
    --zone="$JUMP_ZONE" \
    --format="value(networkInterfaces[0].networkIP)"
)"

if [[ -z "$JUMP_IP" ]]; then
  echo "ERROR: Could not determine orca-jumphost internal IP."
  exit 1
fi

echo "Jumphost zone: $JUMP_ZONE"
echo "Jumphost IP:   $JUMP_IP"

# ============================================================
# TASK 4
# PRIVATE GKE CLUSTER
# ============================================================

echo
echo "============================================================"
echo "[4/5] Creating private GKE cluster"
echo "============================================================"

if gcloud container clusters describe "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" >/dev/null 2>&1; then

  echo "$CLUSTER_NAME already exists."

else

  gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --network="$NETWORK" \
    --subnetwork="$SUBNET" \
    --service-account="$SA_EMAIL" \
    --enable-ip-alias \
    --enable-private-nodes \
    --enable-private-endpoint \
    --enable-master-authorized-networks \
    --master-authorized-networks="${JUMP_IP}/32" \
    --quiet
fi

echo
echo "Verifying cluster configuration..."

gcloud container clusters describe "$CLUSTER_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="yaml(
name,
location,
network,
subnetwork,
privateClusterConfig,
masterAuthorizedNetworksConfig,
nodeConfig.serviceAccount
)"

echo
echo "Checking authorized network..."

AUTHORIZED="$(
  gcloud container clusters describe "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --format="value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock)"
)"

echo "$AUTHORIZED"

if [[ "$AUTHORIZED" != *"${JUMP_IP}/32"* ]]; then

  echo "Updating master authorized network..."

  gcloud container clusters update "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --enable-master-authorized-networks \
    --master-authorized-networks="${JUMP_IP}/32" \
    --quiet
fi

echo
echo "TASK 4 COMPLETE"
echo "Click Check my progress: Create private Kubernetes cluster"
read -r -p "Press ENTER after Task 4 passes..." _ </dev/tty

# ============================================================
# TASK 5
# DEPLOY FROM JUMPHOST
# ============================================================

echo
echo "============================================================"
echo "[5/5] Deploying hello-server from orca-jumphost"
echo "============================================================"

REMOTE_SCRIPT="/tmp/orca-gke-deploy.sh"

cat > /tmp/orca-gke-deploy.sh <<REMOTE
#!/usr/bin/env bash
set -e

PROJECT_ID="$PROJECT_ID"
CLUSTER_NAME="$CLUSTER_NAME"
ZONE="$ZONE"

echo "Installing GKE auth plugin..."

if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
fi

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

echo "Getting private cluster credentials..."

gcloud config set project "\$PROJECT_ID" --quiet

gcloud container clusters get-credentials "\$CLUSTER_NAME" \
  --internal-ip \
  --project="\$PROJECT_ID" \
  --zone="\$ZONE"

echo
echo "Cluster nodes:"
kubectl get nodes

echo
echo "Creating hello-server deployment..."

kubectl create deployment hello-server \
  --image=gcr.io/google-samples/hello-app:1.0 \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

echo
echo "Waiting for hello-server rollout..."

kubectl rollout status deployment/hello-server \
  --timeout=180s

echo
echo "Deployment:"
kubectl get deployment hello-server

echo
echo "Pods:"
kubectl get pods \
  -l app=hello-server \
  -o wide
REMOTE

echo
echo "Copying deployment script to jumphost..."

gcloud compute scp \
  /tmp/orca-gke-deploy.sh \
  "${JUMPHOST}:${REMOTE_SCRIPT}" \
  --project="$PROJECT_ID" \
  --zone="$JUMP_ZONE" \
  --quiet

echo
echo "Executing from jumphost..."

gcloud compute ssh "$JUMPHOST" \
  --project="$PROJECT_ID" \
  --zone="$JUMP_ZONE" \
  --command="chmod +x ${REMOTE_SCRIPT} && ${REMOTE_SCRIPT}"

echo
echo "============================================================"
echo " GSP342 AUTOMATION COMPLETE"
echo "============================================================"
echo "Custom role:     $CUSTOM_ROLE_TITLE"
echo "Role ID:         $CUSTOM_ROLE_ID"
echo "Service account: $SA_EMAIL"
echo "Cluster:         $CLUSTER_NAME"
echo "Subnet:          $SUBNET"
echo "Network:         $NETWORK"
echo "Jumphost:        $JUMPHOST"
echo "Authorized CIDR: ${JUMP_IP}/32"
echo "Deployment:      hello-server"
echo
echo "Click Check my progress for Task 5."
