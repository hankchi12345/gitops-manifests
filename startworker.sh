#!/bin/bash
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must run as root"

# ── Auto-generate node name: k3s-worker-{last_octet}-{YY}-{M} ────
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
[[ -z "$LOCAL_IP" ]] && die "Cannot detect local IP"

LAST_OCTET=$(echo "$LOCAL_IP" | awk -F. '{print $4}')
YEAR_SHORT=$(date +%y)   # 2-digit year, e.g. 26
MONTH=$(date +%-m)        # month without leading zero, e.g. 5
NODE_NAME="k3s-worker-${LAST_OCTET}-${YEAR_SHORT}-${MONTH}"

# ── Banner ────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       GitOps k3s - Worker Bootstrap      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Detected IP  : ${LOCAL_IP}"
echo "  Node name    : ${NODE_NAME}"
echo ""
read -rp  "k3s Master IP (e.g. 192.168.1.100) : " MASTER_IP
read -rsp "k3s Join token                      : " K3S_TOKEN; echo
echo ""

# ── Phase 0: Hostname + DNS ───────────────────────────────────────
log "Phase 0: Setting hostname to ${NODE_NAME}"
hostnamectl set-hostname "${NODE_NAME}"

log "Phase 0: DNS — writing /etc/k3s-resolv.conf"
cat > /etc/k3s-resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF

# ── Phase 1: Install k3s agent ───────────────────────────────────
if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  log "Phase 1: k3s-agent already running, skipping"
else
  log "Phase 1: Installing k3s agent and joining cluster..."
  curl -sfL https://get.k3s.io | K3S_URL="https://${MASTER_IP}:6443" \
    K3S_TOKEN="${K3S_TOKEN}" \
    sh -s - agent \
      --node-name "${NODE_NAME}" \
      --resolv-conf /etc/k3s-resolv.conf
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                  Worker Joined                       ║"
echo "╠══════════════════════════════════════════════════════╣"
printf  "║  Node name   : %-37s║\n" "$NODE_NAME"
printf  "║  Master      : %-37s║\n" "$MASTER_IP"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Verify on master:                                   ║"
echo "║    kubectl get nodes                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
