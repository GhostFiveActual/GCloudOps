#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

REGION="us-east1"
ZONE="us-east1-c"

ROLE_ID="orca_storage_editor_889"
ROLE_TITLE="orca_storage_editor_889"

SA_ID="orca-private-cluster-713-sa"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

CLUSTER="orca-cluster-631"
SUBNET="orca-build-subnet"
JUMPHOST="orca-jumphost"

CUSTOM_ROLE="projects/${PROJECT_ID}/roles/${ROLE_ID}"

echo "============================================================"
echo " GSP342 :: Cloud Security Fundamentals"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Zone:    $ZONE"
echo "Role:    $ROLE_ID"
echo "SA:      $SA_EMAIL"
echo "Cluster: $CLUSTER"
echo "============================================================"

gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --quiet

# ============================================================
# TASK 1
# ============================================================

echo
echo "[1/5] CUSTOM SECURITY ROLE"

if gcloud iam roles describe "$ROLE_ID" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud iam roles update "$ROLE_ID" \
    --project="$PROJECT_ID" \
    --title="$ROLE_TITLE" \
    --permissions="storage.buckets.get,storage.objects.get,storage.objects.list,storage.objects.update,storage.objects.create" \
    --stage=GA \
    --quiet
else
  gcloud iam roles create "$ROLE_ID" \
    --project="$PROJECT_ID" \
    --title="$ROLE_TITLE" \
    --permissions="storage.buckets.get,storage.objects.get,storage.objects.list,storage.objects.update,storage.objects.create" \
    --stage=GA \
    --quiet
fi

gcloud iam roles describe "$ROLE_ID" \
  --project="$PROJECT_ID" \
  --format="yaml(name,title,includedPermissions)"

echo
echo "TASK 1 READY — click Check my progress."
read -r -p "Press ENTER after Task 1 passes..." _ </dev/tty

# ============================================================
# TASK 2
# ============================================================

echo
echo "[2/5] SERVICE ACCOUNT"

if ! gcloud iam service-accounts describe "$SA_EMAIL" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud iam service-accounts create "$SA_ID" \
    --project="$PROJECT_ID" \
    --display-name="$SA_ID"
fi

gcloud iam service-accounts describe "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --format="yaml(email,displayName)"

echo
echo "TASK 2 READY — click Check my progress."
read -r -p "Press ENTER after Task 2 passes..." _ </dev/tty

# ============================================================
# TASK 3
# ============================================================

echo
echo "[3/5] IAM BINDINGS"

for ROLE in \
  roles/monitoring.viewer \
  roles/monitoring.metricWriter \
  roles/logging.logWriter \
  "$CUSTOM_ROLE"
do
  echo "Binding $ROLE"

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$ROLE" \
    --condition=None \
    --quiet
done

echo
echo "Bindings:"
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SA_EMAIL}" \
  --format="table(bindings.role)"

echo
echo "TASK 3 READY — click Check my progress."
read -r -p "Press ENTER after Task 3 passes..." _ </dev/tty

# ============================================================
# DISCOVER NETWORK + JUMPHOST
# ============================================================

echo
echo "Discovering network..."

NETWORK_URL="$(
  gcloud compute networks subnets describe "$SUBNET" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(network)"
)"

NETWORK="${NETWORK_URL##*/}"

JUMP_ZONE="$(
  gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="name=('${JUMPHOST}')" \
    --format="value(zone.basename())" \
    --limit=1
)"

JUMP_IP="$(
  gcloud compute instances describe "$JUMPHOST" \
    --zone="$JUMP_ZONE" \
    --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)"
)"

echo "Network:       $NETWORK"
echo "Jumphost zone: $JUMP_ZONE"
echo "Jumphost IP:   $JUMP_IP"
echo "Authorized:    ${JUMP_IP}/32"

# ============================================================
# TASK 4
# ============================================================

echo
echo "[4/5] PRIVATE GKE CLUSTER"

if ! gcloud container clusters describe "$CLUSTER" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud container clusters create "$CLUSTER" \
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
else
  echo "Cluster already exists."

  gcloud container clusters update "$CLUSTER" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --enable-master-authorized-networks \
    --master-authorized-networks="${JUMP_IP}/32" \
    --quiet
fi

echo
echo "Cluster verification:"

gcloud container clusters describe "$CLUSTER" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --format="yaml(
name,
location,
network,
subnetwork,
privateClusterConfig.enablePrivateNodes,
privateClusterConfig.enablePrivateEndpoint,
privateClusterConfig.privateEndpoint,
masterAuthorizedNetworksConfig,
nodeConfig.serviceAccount
)"

echo
echo "TASK 4 READY — click Check my progress."
read -r -p "Press ENTER after Task 4 passes..." _ </dev/tty

# ============================================================
# TASK 5
# ============================================================

echo
echo "[5/5] DEPLOY FROM ORCA JUMPHOST"

cat >/tmp/orca-deploy.sh <<REMOTE
#!/usr/bin/env bash
set -euo pipefail

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y google-cloud-sdk-gke-gcloud-auth-plugin
fi

gcloud container clusters get-credentials "$CLUSTER" \
  --internal-ip \
  --project="$PROJECT_ID" \
  --zone="$ZONE"

echo
echo "=== NODES ==="
kubectl get nodes

echo
echo "=== DEPLOY HELLO SERVER ==="

kubectl create deployment hello-server \
  --image=gcr.io/google-samples/hello-app:1.0 \
  --dry-run=client \
  -o yaml |
kubectl apply -f -

kubectl rollout status deployment/hello-server \
  --timeout=180s

echo
echo "=== DEPLOYMENT ==="
kubectl get deployment hello-server

echo
echo "=== PODS ==="
kubectl get pods -l app=hello-server -o wide
REMOTE

gcloud compute scp \
  /tmp/orca-deploy.sh \
  "${JUMPHOST}:/tmp/orca-deploy.sh" \
  --zone="$JUMP_ZONE" \
  --project="$PROJECT_ID" \
  --quiet

gcloud compute ssh "$JUMPHOST" \
  --zone="$JUMP_ZONE" \
  --project="$PROJECT_ID" \
  --command="chmod +x /tmp/orca-deploy.sh && /tmp/orca-deploy.sh"

echo
echo "============================================================"
echo " GSP342 COMPLETE"
echo "============================================================"
echo "Role:       $ROLE_ID"
echo "SA:         $SA_EMAIL"
echo "Cluster:    $CLUSTER"
echo "Network:    $NETWORK"
echo "Subnet:     $SUBNET"
echo "Authorized: ${JUMP_IP}/32"
echo "Deployment: hello-server"
echo
echo "Click Check my progress for Task 5."
