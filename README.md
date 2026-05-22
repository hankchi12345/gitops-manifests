# k3s GitOps Monitoring Stack

基於 GitOps 架構的 k3s 監控平台，使用 ArgoCD 自動同步，包含 Prometheus、Grafana、Cloudflare Tunnel。

## 架構

```
GitHub (source of truth)
    ↓ ArgoCD 自動同步
k3s cluster
    ├── Cloudflare Tunnel → Traefik → 對外服務
    ├── Prometheus + node-exporter + kube-state-metrics
    └── Grafana (dashboard)
```

## 目錄結構

```
gitops-manifests/
├── 00-base/                        # 基礎設施
│   ├── namespace.yaml              # 所有 namespace 定義
│   ├── pvc.yaml                    # Grafana 持久化儲存
│   ├── quota.yaml                  # 各 namespace pod 數量上限
│   └── cloudflare/                 # Cloudflare Tunnel
│       ├── cloudflare-configmap.yaml
│       ├── cloudflare-deployment.yaml
│       └── cloudflare-sealed-secrets.yaml
├── 01-configs/grafana/             # Grafana 設定
│   ├── datasources.yaml            # Prometheus datasource
│   ├── dashboards-provision.yaml   # Dashboard 載入路徑
│   ├── sealed-secrets.yaml         # 加密的帳密
│   ├── kustomization.yaml
│   └── dash-json/                  # Dashboard JSON
│       ├── node-exporter.json      # Node 監控
│       └── kube-cluster-monitoring.json  # Pod 監控
├── 02-helm-values/                 # Helm chart 設定
│   ├── prometheus/values.yaml
│   └── grafana/values.yaml
└── 03-argocd-apps/                 # ArgoCD 應用定義
    ├── argocd-default-project.yaml
    ├── argocd-ingress.yaml
    ├── prometheus.yaml
    └── grafana.yaml
```

## 部署到新 Server

### Day 0：基礎設施

```bash
# 1. 修正 DNS（避免 Go 應用程式解析到 localhost）
cat > /etc/k3s-resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF

# 2. 安裝 k3s（帶入正確的 resolv.conf）
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-name k3s-master \
  --resolv-conf /etc/k3s-resolv.conf

# 3. 安裝 Sealed Secrets controller
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# 4. 安裝 kubeseal CLI
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
mv kubeseal /usr/local/bin/
```

### Day 1：平台部署

```bash
# 1. Clone repo
git clone https://github.com/hankchi12345/gitops-manifests.git /opt/gitops-manifests
cd /opt/gitops-manifests

# 2. 建立 secrets（明文只存本機，不進 Git）
mkdir -p /root/secrets-backup
cat > /root/secrets-backup/grafana-secrets.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-creds
  namespace: monitoring
type: Opaque
data:
  admin-user: $(echo -n "你的帳號" | base64)
  admin-password: $(echo -n "你的密碼" | base64)
EOF

cat > /root/secrets-backup/cloudflare-secrets.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-token
  namespace: infra-system
type: Opaque
data:
  tunnel-token: 你的_tunnel_token_base64
EOF

# 3. 加密 secrets
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/grafana-secrets.yaml \
  > 01-configs/grafana/sealed-secrets.yaml

kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/cloudflare-secrets.yaml \
  > 00-base/cloudflare/cloudflare-sealed-secrets.yaml

# 4. 套用基礎設施
kubectl apply -f 00-base/namespace.yaml
kubectl apply -f 00-base/
kubectl apply --server-side -k 01-configs/grafana/

# 5. 安裝 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# 等待 CRD 就緒後重啟 controller
kubectl rollout restart deployment -n argocd argocd-applicationset-controller

# 6. 安裝 Helm 並加入 repo
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Day 2：連接 GitOps

```bash
# 1. 安裝 argocd CLI
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# 2. 登入 ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --insecure --username admin

# 3. 連接 GitHub repo
argocd repo add https://github.com/hankchi12345/gitops-manifests.git \
  --username 你的帳號 --password 你的_github_token

# 4. 套用 ArgoCD Application（之後 ArgoCD 全自動）
kubectl apply -f 03-argocd-apps/
```

## 對外網址

| 服務 | 網址 |
|---|---|
| Grafana | https://grafana.你的網域 |
| ArgoCD | https://argocd.你的網域 |

## 改密碼注意事項

1. 修改 `/root/secrets-backup/grafana-secrets.yaml`（使用 `echo -n` 避免多換行）
2. 重新 kubeseal 並 apply
3. 砍 PVC 讓 Grafana 用新密碼重新初始化

## 備份 Sealed Secrets 私鑰

```bash
# cluster 重建時需要這個才能解密
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /root/sealed-secrets-master-key-backup.yaml
```
