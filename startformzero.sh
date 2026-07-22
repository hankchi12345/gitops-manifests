#!/bin/bash
set -euo pipefail

REPO_DIR="/opt/gitops-manifests"

# ── Colors ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

wait_deploy() {
  local ns=$1 name=$2
  log "Waiting for deployment/$name in $ns..."
  kubectl rollout status deployment/"$name" -n "$ns" --timeout=300s
}

# ── Root check ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"

# ── Repo URL ──────────────────────────────────────────────────────
echo ""
echo "此腳本會把 cluster 設定 commit + push 回你自己的 git repo。"
echo "請先 Fork https://github.com/hankchi12345/gitops-manifests 到你自己的帳號,"
echo "並在下面貼上 fork 後的 repo URL(不要用原作者的 repo,你不會有 push 權限)。"
read -rp "你的 GitOps repo URL (e.g. https://github.com/<you>/gitops-manifests.git) : " REPO_URL
[[ -z "$REPO_URL" ]] && die "Repo URL cannot be empty"
read -rp  "GitHub username                    : " GITHUB_USER
read -rsp "GitHub personal token              : " GITHUB_TOKEN; echo

# Git credentials for this session (clone/pull/push) — never persisted to .git/config
GIT_ASKPASS_SCRIPT=$(mktemp)
trap 'rm -f "$GIT_ASKPASS_SCRIPT"' EXIT
chmod 700 "$GIT_ASKPASS_SCRIPT"
cat > "$GIT_ASKPASS_SCRIPT" << 'ASKPASS_EOF'
#!/bin/bash
case "$1" in
  Username*) printf '%s' "$GIT_ASKPASS_USERNAME" ;;
  Password*) printf '%s' "$GIT_ASKPASS_PASSWORD" ;;
esac
ASKPASS_EOF
export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
export GIT_ASKPASS_USERNAME="$GITHUB_USER"
export GIT_ASKPASS_PASSWORD="$GITHUB_TOKEN"

# ── Phase 4: Clone / pull repo ────────────────────────────────────
# Runs before the interactive prompts so clusters/ reflects git state
# when the user is asked to pick an existing Cluster ID below.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Phase 4: Cloning repo..."
  git clone "$REPO_URL" "$REPO_DIR"
else
  log "Phase 4: Repo exists, syncing remote + pulling latest..."
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" pull
fi

# ── Auto-generate node name: k3s-master-{last_octet}-{YY}-{M} ────
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[[ -z "$LOCAL_IP" ]] && die "Cannot detect local IP"
LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
YEAR_SHORT=$(date +%y)
MONTH=$(date +%-m)
NODE_NAME="k3s-master-${LAST_OCTET}-${YEAR_SHORT}-${MONTH}"

# ── Interactive prompts ───────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     GitOps Monitoring Stack - Bootstrap  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Detected IP  : ${LOCAL_IP}"
echo "  Node name    : ${NODE_NAME}"
echo ""
echo "  1) 建立新 cluster"
echo "  2) 使用既有 Cluster ID"
read -rp "選擇 [1/2] : " CLUSTER_MODE_CHOICE

case "$CLUSTER_MODE_CHOICE" in
  1)
    read -rp  "Cluster name (e.g. m1, prod, lab) : " CLUSTER_NAME
    [[ -n "$CLUSTER_NAME" ]] || die "Cluster name cannot be empty"
    RANDOM_SUFFIX=$(openssl rand -hex 4 | head -c 5)
    CLUSTER_ID="${CLUSTER_NAME}-${RANDOM_SUFFIX}"
    ;;
  2)
    mapfile -t EXISTING_CLUSTERS < <(find "$REPO_DIR/clusters" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    [[ ${#EXISTING_CLUSTERS[@]} -eq 0 ]] && die "No existing clusters found under clusters/"
    echo "  既有 Cluster:"
    for i in "${!EXISTING_CLUSTERS[@]}"; do
      printf "    %d) %s\n" "$((i + 1))" "${EXISTING_CLUSTERS[$i]}"
    done
    read -rp "選擇編號 : " CLUSTER_PICK
    [[ "$CLUSTER_PICK" =~ ^[0-9]+$ ]] && (( CLUSTER_PICK >= 1 && CLUSTER_PICK <= ${#EXISTING_CLUSTERS[@]} )) \
      || die "Invalid choice '$CLUSTER_PICK'"
    CLUSTER_ID="${EXISTING_CLUSTERS[$((CLUSTER_PICK - 1))]}"
    ;;
  *)
    die "Invalid choice '$CLUSTER_MODE_CHOICE': must be 1 or 2"
    ;;
esac
echo "      → Cluster ID: ${CLUSTER_ID}"
echo ""

read -rp "你的網域 (e.g. lab-hc.cloud, 對外服務會用 <sub>.<domain>) : " DOMAIN
[[ -z "$DOMAIN" ]] && die "Domain cannot be empty"

DEFAULT_SECRETS_DIR="/root/secrets-backup/$CLUSTER_ID"
if [[ "$CLUSTER_MODE_CHOICE" == "2" ]]; then
  read -rp "secrets-backup 路徑 [預設 $DEFAULT_SECRETS_DIR] : " SECRETS_DIR
  SECRETS_DIR="${SECRETS_DIR:-$DEFAULT_SECRETS_DIR}"
else
  SECRETS_DIR="$DEFAULT_SECRETS_DIR"
fi
GRAFANA_SECRETS_FILE="$SECRETS_DIR/grafana-secrets.yaml"
CLOUDFLARE_SECRETS_FILE="$SECRETS_DIR/cloudflare-secrets.yaml"

if [[ -s "$GRAFANA_SECRETS_FILE" && -s "$CLOUDFLARE_SECRETS_FILE" ]]; then
  log "沿用既有 secrets-backup: $SECRETS_DIR"
  REUSE_SECRETS=true
else
  REUSE_SECRETS=false
  read -rp  "Grafana admin username             : " GRAFANA_USER
  read -rsp "Grafana admin password             : " GRAFANA_PASS; echo
  read -rsp "Cloudflare tunnel token            : " CF_TOKEN;     echo
fi
echo ""

CLUSTER_DIR="$REPO_DIR/clusters/$CLUSTER_ID"

# ── Phase 0: Hostname + DNS ───────────────────────────────────────
log "Phase 0: Setting hostname to ${NODE_NAME}"
hostnamectl set-hostname "${NODE_NAME}"

log "Phase 0: DNS — writing /etc/k3s-resolv.conf"
cat > /etc/k3s-resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ── Phase 1: k3s ─────────────────────────────────────────────────
if systemctl is-active --quiet k3s 2>/dev/null; then
  log "Phase 1: k3s already running, skipping install"
  warn "Phase 1: resolv-conf only takes effect at install time — restart k3s manually if DNS settings changed"
elif [[ -x /usr/local/bin/k3s ]]; then
  die "k3s is installed but the k3s service is not active — investigate with 'systemctl status k3s' before rerunning"
else
  log "Phase 1: Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - server \
    --write-kubeconfig-mode 644 \
    --node-name "$NODE_NAME" \
    --resolv-conf /etc/k3s-resolv.conf
fi

log "Waiting for node to be Ready..."
WAIT_SECONDS=0
until kubectl get node 2>/dev/null | grep -q " Ready"; do
  sleep 3
  WAIT_SECONDS=$((WAIT_SECONDS + 3))
  if (( WAIT_SECONDS >= 180 )); then
    die "Node not Ready after 180s — check k3s port (6443) and etcd/datastore health (journalctl -u k3s)"
  fi
done

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

# Phase 4 (clone/pull repo) runs earlier, before the interactive prompts —
# see below the root check — so clusters/ reflects git state before asking
# the user to pick an existing Cluster ID.

# ── Phase 5: Prepare cluster directory ────────────────────────────
log "Phase 5: Preparing cluster directory clusters/$CLUSTER_ID ..."

if [[ -d "$CLUSTER_DIR" ]]; then
  [[ "$CLUSTER_MODE_CHOICE" == "2" ]] \
    || die "clusters/$CLUSTER_ID already exists — pick a different cluster name or choose option 2"
  log "Phase 5: Reusing existing directory, skipping template copy"
else
  [[ "$CLUSTER_MODE_CHOICE" == "1" ]] \
    || die "clusters/$CLUSTER_ID not found"
  mkdir -p "$CLUSTER_DIR"
  cp -r "$REPO_DIR/template/." "$CLUSTER_DIR/"

  # Substitute CLUSTER_ID placeholder in ArgoCD app files
  sed -i "s|CLUSTER_ID|$CLUSTER_ID|g" "$CLUSTER_DIR/03-argocd-apps/prometheus.yaml"
  sed -i "s|CLUSTER_ID|$CLUSTER_ID|g" "$CLUSTER_DIR/03-argocd-apps/grafana.yaml"

  # Substitute DOMAIN placeholder across manifests that expose services externally
  sed -i "s|DOMAIN|$DOMAIN|g" "$CLUSTER_DIR/00-base/cloudflare/cloudflare-configmap.yaml"
  sed -i "s|DOMAIN|$DOMAIN|g" "$CLUSTER_DIR/02-helm-values/grafana/values.yaml"
  sed -i "s|DOMAIN|$DOMAIN|g" "$CLUSTER_DIR/03-argocd-apps/argocd-ingress.yaml"
fi

# ── Phase 6: Create plaintext secrets (local only, never in git) ──
mkdir -p "$SECRETS_DIR"

if [[ "$REUSE_SECRETS" == "true" ]]; then
  log "Phase 6: Reusing existing plaintext secrets at $SECRETS_DIR/"
else
  log "Phase 6: Writing plaintext secrets to $SECRETS_DIR/"

  GRAFANA_USER_B64=$(printf '%s' "$GRAFANA_USER" | base64 -w 0)
  GRAFANA_PASS_B64=$(printf '%s' "$GRAFANA_PASS" | base64 -w 0)
  CF_TOKEN_B64=$(printf '%s' "$CF_TOKEN" | base64 -w 0)

  cat > "$GRAFANA_SECRETS_FILE" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-creds
  namespace: monitoring
type: Opaque
data:
  admin-user: ${GRAFANA_USER_B64}
  admin-password: ${GRAFANA_PASS_B64}
EOF

  cat > "$CLOUDFLARE_SECRETS_FILE" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token
  namespace: infra-system
type: Opaque
data:
  tunnel-token: ${CF_TOKEN_B64}
EOF

  chmod 600 "$SECRETS_DIR"/*.yaml
fi

# ── Phase 7: Seal secrets into cluster directory ──────────────────
log "Phase 7: Sealing secrets into clusters/$CLUSTER_ID ..."
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < "$GRAFANA_SECRETS_FILE" \
  > "$CLUSTER_DIR/01-configs/grafana/sealed-secrets.yaml"

kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < "$CLOUDFLARE_SECRETS_FILE" \
  > "$CLUSTER_DIR/00-base/cloudflare/cloudflare-sealed-secrets.yaml"

# ── Phase 8: Commit + push cluster directory to git ───────────────
log "Phase 8: Committing clusters/$CLUSTER_ID ..."
git -C "$REPO_DIR" config user.email "setup@k3s-bootstrap"
git -C "$REPO_DIR" config user.name  "Bootstrap Script"

git -C "$REPO_DIR" add "clusters/$CLUSTER_ID"
git -C "$REPO_DIR" diff --cached --quiet \
  || git -C "$REPO_DIR" commit -m "chore: bootstrap cluster $CLUSTER_ID"

if [[ -n "$(git -C "$REPO_DIR" log '@{u}..HEAD' --oneline 2>/dev/null)" ]]; then
  log "Phase 8: Pushing to git..."
  git -C "$REPO_DIR" push
else
  log "Phase 8: Nothing to push"
fi

# ── Phase 9: Apply base infrastructure ───────────────────────────
log "Phase 9: Applying base infrastructure..."
kubectl apply -f "$CLUSTER_DIR/00-base/namespace.yaml"
kubectl apply -f "$CLUSTER_DIR/00-base/pvc.yaml"
kubectl apply -f "$CLUSTER_DIR/00-base/quota.yaml"
kubectl apply -f "$CLUSTER_DIR/00-base/cloudflare/"
kubectl apply --server-side -k "$CLUSTER_DIR/01-configs/grafana/"

# ── Phase 10: Install ArgoCD ──────────────────────────────────────
if ! kubectl get namespace argocd &>/dev/null; then
  log "Phase 10: Installing ArgoCD..."
  kubectl create namespace argocd
  kubectl apply --server-side -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  log "Phase 10: Waiting for ArgoCD CRDs..."
  until kubectl get crd applications.argoproj.io &>/dev/null; do sleep 3; done
  sleep 10

  log "Phase 10: Restarting applicationset-controller (CRD race fix)..."
  kubectl rollout restart deployment -n argocd argocd-applicationset-controller
else
  log "Phase 10: ArgoCD already installed"
fi

wait_deploy argocd argocd-server

# Disable ArgoCD's built-in HTTP→HTTPS redirect (SSL is terminated at Cloudflare)
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type=merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
wait_deploy argocd argocd-server

# ── Phase 11: Connect GitHub repo to ArgoCD ───────────────────────
log "Phase 11: Registering GitHub repo in ArgoCD..."
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
  type: "git"
  url: "${REPO_URL}"
  username: "${GITHUB_USER}"
  password: "${GITHUB_TOKEN}"
EOF

# ── Phase 12: Deploy ArgoCD apps ─────────────────────────────────
log "Phase 12: Deploying ArgoCD applications..."
if [[ -f "$CLUSTER_DIR/03-argocd-apps/kustomization.yaml" ]]; then
  kubectl apply -k "$CLUSTER_DIR/03-argocd-apps/"
else
  kubectl apply -f "$CLUSTER_DIR/03-argocd-apps/"
fi

# ── Phase 13: Backup sealed secrets private key ───────────────────
log "Phase 13: Backing up Sealed Secrets private key..."
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
printf  "║  Cluster ID  : %-37s║\n" "$CLUSTER_ID"
printf  "║  ArgoCD      : %-37s║\n" "http://argocd.$DOMAIN"
printf  "║  Grafana     : %-37s║\n" "http://grafana.$DOMAIN"
printf  "║  ArgoCD pass : %-37s║\n" "$ARGOCD_PASS"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Keep these files safe (NOT in git):                 ║"
printf  "║    %-50s║\n" "$SECRETS_DIR/"
echo "║    /root/sealed-secrets-master-key-backup.yaml       ║"
echo "╚══════════════════════════════════════════════════════╝"
