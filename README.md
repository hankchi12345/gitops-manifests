# k3s GitOps Monitoring Stack

基於 GitOps 架構的 k3s 監控平台，使用 ArgoCD 自動同步。

## 快速部署

### Master（控制平面）

```bash
git clone https://github.com/hankchi12345/gitops-manifests.git /opt/gitops-manifests
bash /opt/gitops-manifests/startformzero.sh
```

> 若 repo 已存在，每次執行前先 pull 確保 script 是最新版：
> ```bash
> git -C /opt/gitops-manifests pull
> bash /opt/gitops-manifests/startformzero.sh
> ```

Script 會互動式詢問以下資訊，其餘全自動：

| 輸入 | 說明 |
|------|------|
| Cluster name | 自定義名稱（e.g. `m1`, `prod`），script 自動附加 5 碼隨機 ID，例如 `m1-a3k9x` |
| Grafana 帳號 / 密碼 | 輸入明文，script 自動轉 base64 |
| Cloudflare tunnel token | 從 Cloudflare Zero Trust 後台取得，貼上原始 token |
| GitHub username / token | 用於 ArgoCD 連接此 repo（token 需有 `repo` 讀取權限） |

完成後輸出 Cluster ID、ArgoCD 初始密碼與各服務網址。

### Worker（加入現有 cluster）

在 **worker 機器**上執行：

```bash
git clone https://github.com/hankchi12345/gitops-manifests.git /opt/gitops-manifests
bash /opt/gitops-manifests/startworker.sh
```

Script 會互動式詢問以下資訊：

| 輸入 | 說明 |
|------|------|
| Master IP | k3s master 的 IP，例如 `192.168.1.100` |
| Join token | 從 master 取得：`cat /var/lib/rancher/k3s/server/node-token` |

Node name 自動依本機 IP 與時間產生，格式：`k3s-worker-{IP最後一組}-{年2碼}-{月}`，例如 `k3s-worker-122-26-5`。

完成後在 master 執行 `kubectl get nodes` 確認 worker 已加入。

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
| 4 | Clone / pull repo |
| 5 | 從 `template/` 複製到 `clusters/<cluster-id>/`，替換 ArgoCD app 路徑 |
| 6 | 將輸入的帳密 / token 寫入 `/root/secrets-backup/`（明文，不進 git） |
| 7 | kubeseal 加密，sealed secrets 寫入 `clusters/<cluster-id>/` |
| 8 | git commit + push（ArgoCD 從 git 拉，sealed secrets 必須先進 repo） |
| 9 | apply namespace / PVC / quota / Cloudflare / Grafana kustomize |
| 10 | 安裝 ArgoCD，修正 applicationset-controller 啟動 race condition |
| 11 | 將 GitHub repo 註冊進 ArgoCD |
| 12 | apply ArgoCD Application（之後 ArgoCD 全自動） |
| 13 | 備份 Sealed Secrets 私鑰到 `/root/sealed-secrets-master-key-backup.yaml` |

## 目錄結構

```
gitops-manifests/
├── startformzero.sh          # 一鍵部署腳本
├── template/                 # 所有 yaml 模板（不直接部署）
│   ├── 00-base/
│   │   ├── namespace.yaml
│   │   ├── pvc.yaml
│   │   ├── quota.yaml
│   │   └── cloudflare/
│   ├── 01-configs/grafana/
│   │   ├── datasources.yaml
│   │   ├── dashboards-provision.yaml
│   │   ├── sealed-secrets.yaml
│   │   ├── kustomization.yaml
│   │   └── dash-json/
│   ├── 02-helm-values/
│   │   ├── prometheus/values.yaml
│   │   └── grafana/values.yaml
│   └── 03-argocd-apps/       # prometheus/grafana.yaml 含 CLUSTER_ID 佔位符
└── clusters/                 # script 建立，每個 cluster 完全獨立
    └── m1-a3k9x/             # 各 cluster 自己的目錄，互不干擾
        ├── 00-base/
        ├── 01-configs/
        ├── 02-helm-values/
        └── 03-argocd-apps/   # ArgoCD app 路徑已替換為此 cluster 的 path
```

每個 cluster 的 ArgoCD 只監看自己的 `clusters/<id>/` 目錄，新增其他 cluster 不影響現有 cluster。

## 搬到新 Server

Sealed Secrets 私鑰是 cluster-specific。新 server 有兩種情境：

**A. 還原舊私鑰（sealed secrets 不需重新加密）**
```bash
# 先還原私鑰，再跑 script
kubectl apply -f /root/sealed-secrets-master-key-backup.yaml
kubectl rollout restart deployment -n kube-system sealed-secrets
git -C /opt/gitops-manifests pull
bash /opt/gitops-manifests/startformzero.sh
```

**B. 全新 cluster（重新加密，預設做法）**
```bash
git clone https://github.com/hankchi12345/gitops-manifests.git /opt/gitops-manifests
bash /opt/gitops-manifests/startformzero.sh
# script 會用新 cluster 的金鑰重新 seal 並 push 新的 clusters/<id>/ 目錄
```

## 改密碼

```bash
# 1. 修改明文檔案
vi /root/secrets-backup/grafana-secrets.yaml

# 2. 重新 seal（將 CLUSTER_ID 替換為實際值，例如 m1-a3k9x）
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/grafana-secrets.yaml \
  > /opt/gitops-manifests/clusters/<cluster-id>/01-configs/grafana/sealed-secrets.yaml

# 3. git push → ArgoCD 自動 apply

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

`/root/secrets-backup/` 和 `/root/sealed-secrets-master-key-backup.yaml` 請妥善保存，**不進 git**。
