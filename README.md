# k3s GitOps Monitoring Stack

基於 GitOps 架構的 k3s 監控平台，使用 ArgoCD 自動同步。

## 快速部署

```bash
git clone https://github.com/hankchi12345/gitops-manifests.git /opt/gitops-manifests
bash /opt/gitops-manifests/startformzero.sh
```

Script 會互動式詢問三樣東西，其餘全自動：

| 輸入 | 說明 |
|------|------|
| Grafana 帳號 / 密碼 | Grafana UI 登入用 |
| Cloudflare tunnel token | 從 Cloudflare Zero Trust 後台取得 |
| GitHub username / token | 用於 ArgoCD 連接此 repo（token 需有 repo 讀取權限） |

完成後輸出 ArgoCD 初始密碼與各服務網址。

## 架構

```
GitHub (source of truth)
    ↓ ArgoCD 自動同步
k3s cluster (single node)
    ├── Cloudflare Tunnel → Traefik → 對外服務
    ├── Prometheus + node-exporter + kube-state-metrics
    └── Grafana (dashboard)
```

## 服務網址

| 服務 | 網址 |
|------|------|
| Grafana | https://grafana.lab-hc.cloud |
| ArgoCD  | https://argocd.lab-hc.cloud  |

## Script 做了什麼

| Phase | 內容 |
|-------|------|
| 0 | 修正 DNS（`/etc/k3s-resolv.conf`，避免 Go 應用解析到 localhost） |
| 1 | 安裝 k3s server，等待 Node Ready |
| 2 | 安裝 Helm，加入 prometheus / grafana / sealed-secrets repo |
| 3 | 安裝 Sealed Secrets controller + kubeseal CLI |
| 4 | Clone repo |
| 5 | 將輸入的帳密 / token 寫入 `/root/secrets-backup/`（明文，不進 git） |
| 6 | kubeseal 加密，寫入 repo 的 sealed-secrets.yaml |
| 7 | git commit + push（ArgoCD 從 git 拉，所以新 sealed secrets 要先進 repo） |
| 8 | apply namespace / PVC / quota / Cloudflare / Grafana kustomize |
| 9 | 安裝 ArgoCD，修正 applicationset-controller 啟動 race condition |
| 10 | 將 GitHub repo 註冊進 ArgoCD |
| 11 | apply ArgoCD Application（之後 ArgoCD 全自動） |
| 12 | 備份 Sealed Secrets 私鑰到 `/root/sealed-secrets-master-key-backup.yaml` |

## 目錄結構

```
gitops-manifests/
├── startformzero.sh                # 一鍵部署腳本
├── 00-base/                        # 基礎設施
│   ├── namespace.yaml
│   ├── pvc.yaml
│   ├── quota.yaml
│   └── cloudflare/
│       ├── cloudflare-configmap.yaml
│       ├── cloudflare-deployment.yaml
│       └── cloudflare-sealed-secrets.yaml
├── 01-configs/grafana/
│   ├── datasources.yaml
│   ├── dashboards-provision.yaml
│   ├── sealed-secrets.yaml
│   ├── kustomization.yaml
│   └── dash-json/
│       ├── node-exporter.json
│       └── kube-cluster-monitoring.json
├── 02-helm-values/
│   ├── prometheus/values.yaml
│   └── grafana/values.yaml
└── 03-argocd-apps/
    ├── argocd-default-project.yaml
    ├── argocd-ingress.yaml
    ├── prometheus.yaml
    └── grafana.yaml
```

## 搬到新 Server

Sealed Secrets 私鑰是 cluster-specific，新 server 有兩種做法：

**A. 還原舊私鑰（sealed secrets 不用重新加密）**
```bash
kubectl apply -f /root/sealed-secrets-master-key-backup.yaml
kubectl rollout restart deployment -n kube-system sealed-secrets
# 然後再跑 startformzero.sh
```

**B. 全新 cluster（重新加密）**
```bash
# 直接跑 script，它會用新 cluster 的金鑰重新 seal 並 push
bash /opt/gitops-manifests/startformzero.sh
```

## 改密碼

```bash
# 1. 修改明文檔案
vi /root/secrets-backup/grafana-secrets.yaml

# 2. 重新 seal
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/grafana-secrets.yaml \
  > /opt/gitops-manifests/01-configs/grafana/sealed-secrets.yaml

# 3. push → ArgoCD 自動 apply

# 4. 刪 PVC 讓 Grafana 重新初始化（密碼存在 DB 裡）
kubectl delete pvc grafana-pvc -n monitoring
```

## 安全備份（重要）

```bash
# Sealed Secrets 私鑰 — cluster 重建時需要
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /root/sealed-secrets-master-key-backup.yaml
```

`/root/secrets-backup/` 和 `/root/sealed-secrets-master-key-backup.yaml` 請妥善保存，不進 git。
