#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/hankchi12345/gitops-manifests.git"
REPO_DIR="/opt/gitops-manifests"

# ── Colors ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

wait_deploy() {
  local ns=$1 name=$2
  log "Waiting for deployment $name in $ns..."
  kubectl rollout status deployment/"$name" -n "$ns" --timeout=300s
}

# ── Root check ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"

# ── Interactive prompts ───────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     GitOps Monitoring Stack - Bootstrap  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
read -rp  "Grafana admin username   : " GRAFANA_USER
read -rsp "Grafana admin password   : " GRAFANA_PASS; echo
read -rsp "Cloudflare tunnel token  : " CF_TOKEN;     echo
read -rp  "GitHub username          : " GITHUB_USER
read -rsp "GitHub personal token    : " GITHUB_TOKEN; echo
echo ""

# ── Phase 0: DNS fix ──────────────────────────────────────────────
log "Phase 0: DNS — writing /etc/k3s-resolv.conf"
cat > /etc/k3s-resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF

# ── Phase 1: k3s ─────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  log "Phase 1: Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - server \
    --write-kubeconfig-mode 644 \
    --node-name k3s-master \
    --resolv-conf /etc/k3s-resolv.conf
  log "Waiting for node to be Ready..."
  until kubectl get node 2>/dev/null | grep -q " Ready"; do sleep 3; done
else
  log "Phase 1: k3s already installed, skipping"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── Phase 2: Helm ─────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  log "Phase 2: Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  log "Phase 2: Helm already installed"
fi

log "Phase 2: Updating Helm repos..."
helm repo add sealed-secrets       https://bitnami-labs.github.io/sealed-secrets          2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts      2>/dev/null || true
helm repo add grafana              https://grafana.github.io/helm-charts                   2>/dev/null || true
helm repo update

# ── Phase 3: Sealed Secrets controller ───────────────────────────
if ! helm list -n kube-system 2>/dev/null | grep -q "^sealed-secrets"; then
  log "Phase 3: Installing Sealed Secrets controller..."
  helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
else
  log "Phase 3: Sealed Secrets already installed"
fi

if ! command -v kubeseal &>/dev/null; then
  log "Phase 3: Installing kubeseal CLI..."
  KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
    | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
  curl -sOL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
  tar -xzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal
  mv kubeseal /usr/local/bin/
  rm -f "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
fi

wait_deploy kube-system sealed-secrets

# ── Phase 4: Clone repo ───────────────────────────────────────────
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Phase 4: Cloning repo..."
  git clone "$REPO_URL" "$REPO_DIR"
else
  log "Phase 4: Repo exists, pulling latest..."
  git -C "$REPO_DIR" pull
fi

# ── Phase 5: Create plaintext secrets (local only, never in git) ──
log "Phase 5: Writing plaintext secrets to /root/secrets-backup/"
mkdir -p /root/secrets-backup

cat > /root/secrets-backup/grafana-secrets.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-creds
  namespace: monitoring
type: Opaque
data:
  admin-user: $(echo -n "$GRAFANA_USER" | base64)
  admin-password: $(echo -n "$GRAFANA_PASS" | base64)
EOF

cat > /root/secrets-backup/cloudflare-secrets.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token
  namespace: infra-system
type: Opaque
data:
  tunnel-token: $(echo -n "$CF_TOKEN" | base64)
EOF

chmod 600 /root/secrets-backup/*.yaml

# ── Phase 6: Seal secrets ─────────────────────────────────────────
log "Phase 6: Sealing secrets..."
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/grafana-secrets.yaml \
  > "$REPO_DIR/01-configs/grafana/sealed-secrets.yaml"

kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/cloudflare-secrets.yaml \
  > "$REPO_DIR/00-base/cloudflare/cloudflare-sealed-secrets.yaml"

# ── Phase 7: Push sealed secrets to git ──────────────────────────
log "Phase 7: Pushing sealed secrets to git..."
git -C "$REPO_DIR" config user.email "setup@k3s-bootstrap"
git -C "$REPO_DIR" config user.name  "Bootstrap Script"
git -C "$REPO_DIR" remote set-url origin \
  "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/hankchi12345/gitops-manifests.git"

git -C "$REPO_DIR" add \
  01-configs/grafana/sealed-secrets.yaml \
  00-base/cloudflare/cloudflare-sealed-secrets.yaml

if git -C "$REPO_DIR" diff --cached --quiet; then
  warn "Phase 7: Sealed secrets unchanged, no commit needed"
else
  git -C "$REPO_DIR" commit -m "chore: reseal secrets for new cluster"
  git -C "$REPO_DIR" push
fi

# ── Phase 8: Apply base infrastructure ───────────────────────────
log "Phase 8: Applying base infrastructure..."
kubectl apply -f "$REPO_DIR/00-base/namespace.yaml"
kubectl apply -f "$REPO_DIR/00-base/pvc.yaml"
kubectl apply -f "$REPO_DIR/00-base/quota.yaml"
kubectl apply -f "$REPO_DIR/00-base/cloudflare/"
kubectl apply --server-side -k "$REPO_DIR/01-configs/grafana/"

# ── Phase 9: Install ArgoCD ───────────────────────────────────────
if ! kubectl get namespace argocd &>/dev/null; then
  log "Phase 9: Installing ArgoCD..."
  kubectl create namespace argocd
  kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  log "Phase 9: Waiting for ArgoCD CRDs..."
  until kubectl get crd applications.argoproj.io &>/dev/null; do sleep 3; done
  sleep 10

  log "Phase 9: Restarting applicationset-controller (CRD race fix)..."
  kubectl rollout restart deployment -n argocd argocd-applicationset-controller
else
  log "Phase 9: ArgoCD already installed"
fi

wait_deploy argocd argocd-server

# ── Phase 10: Connect GitHub repo to ArgoCD ───────────────────────
log "Phase 10: Registering GitHub repo in ArgoCD..."
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitops-manifests-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: $REPO_URL
  username: $GITHUB_USER
  password: $GITHUB_TOKEN
EOF

# ── Phase 11: Deploy ArgoCD apps ─────────────────────────────────
log "Phase 11: Deploying ArgoCD applications..."
kubectl apply -f "$REPO_DIR/03-argocd-apps/"

# ── Phase 12: Backup sealed secrets private key ───────────────────
log "Phase 12: Backing up Sealed Secrets private key..."
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /root/sealed-secrets-master-key-backup.yaml
chmod 600 /root/sealed-secrets-master-key-backup.yaml

# ── Done ──────────────────────────────────────────────────────────
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(not found)")

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                  Setup Complete                      ║"
echo "╠══════════════════════════════════════════════════════╣"
printf  "║  ArgoCD   : %-40s║\n" "http://argocd.lab-hc.cloud"
printf  "║  Grafana  : %-40s║\n" "http://grafana.lab-hc.cloud"
printf  "║  ArgoCD password : %-33s║\n" "$ARGOCD_PASS"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Keep these files safe (NOT in git):                 ║"
echo "║    /root/secrets-backup/                             ║"
echo "║    /root/sealed-secrets-master-key-backup.yaml       ║"
echo "╚══════════════════════════════════════════════════════╝"
