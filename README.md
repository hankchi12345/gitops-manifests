# k3s GitOps Stack

基於 GitOps 架構的 k3s 平台，使用 ArgoCD 自動同步，GitHub Actions 自動追蹤上游版本。

## 架構

```
GitHub (source of truth)
    ↓ ArgoCD 每 3 分鐘 poll
k3s cluster
    ├── Cloudflare Tunnel → Traefik → 對外服務
    ├── Prometheus + node-exporter + kube-state-metrics
    ├── Grafana (dashboard)
    └── MeTube (YouTube 下載器)

GitHub Actions (每天 02:00 UTC)
    └── 查 MeTube 上游新版 → 更新 image tag → git push → ArgoCD 部署
```

## 服務網址

| 服務 | 網址 |
|------|------|
| Grafana | https://grafana.lab-hc.cloud |
| ArgoCD  | https://argocd.lab-hc.cloud  |
| MeTube  | https://metube.lab-hc.cloud  |

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

**MeTube 需要額外 apply 一次 ArgoCD Application（script 尚未自動化此步驟）：**

```bash
kubectl apply -f /opt/gitops-manifests/clusters/<cluster-id>/03-argocd-apps/metube.yaml
```

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

Node name 自動依本機 IP 與時間產生，格式：`k3s-worker-{IP最後一組}-{年2碼}-{月}`。

完成後在 master 執行 `kubectl get nodes` 確認 worker 已加入。

## 目錄結構

```
gitops-manifests/
├── startformzero.sh          # 一鍵部署腳本（master）
├── startworker.sh            # 加入 worker 腳本
├── .github/workflows/
│   └── update-metube.yml     # 每日自動更新 MeTube image tag
├── template/                 # 所有 yaml 模板（不直接部署）
│   ├── 00-base/              # namespace / pvc / quota / cloudflare
│   ├── 01-configs/grafana/   # datasource / dashboard / sealed-secrets
│   ├── 02-helm-values/       # prometheus / grafana helm values
│   ├── 03-argocd-apps/       # ArgoCD Application（含 CLUSTER_ID 佔位符）
│   └── 04-apps/metube/       # MeTube k8s 資源模板
└── clusters/                 # script 建立，每個 cluster 完全獨立
    └── <cluster-id>/         # 各 cluster 自己的目錄，互不干擾
        ├── 00-base/
        ├── 01-configs/
        ├── 02-helm-values/
        ├── 03-argocd-apps/   # ArgoCD app 路徑已替換為此 cluster 的 path
        └── 04-apps/metube/   # 實際部署的 MeTube 資源（image tag 由 CI 更新）
```

每個 cluster 的 ArgoCD 只監看自己的 `clusters/<id>/` 目錄，新增其他 cluster 不影響現有 cluster。

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

## CI/CD 流程（MeTube 自動更新）

```
每天 02:00 UTC
    ↓ GitHub Actions: update-metube.yml
    ├── curl GitHub API → 取得最新 release tag
    ├── 比對 clusters/*/04-apps/metube/deployment.yaml 中的現有 tag
    ├── 版本相同 → 結束，不產生任何 commit
    └── 版本不同 → sed 更新所有 cluster 的 image tag
                    → git commit + push
                    → ArgoCD 偵測 git 變化（~3 分鐘）
                    → 滾動更新 Pod
```

手動觸發：GitHub repo → Actions → `Update MeTube Image` → `Run workflow`

## 更新 MeTube YouTube Cookies

MeTube 使用 YouTube cookies 讓 yt-dlp 以認證身份下載，繞過機器人偵測。
Cookie session 約每數個月至一年過期，過期後下載可能失敗，需手動更新。

### 判斷是否需要更新

MeTube 下載時出現以下錯誤即代表 cookies 已過期：
```
Sign in to confirm you're not a bot
ERROR: [youtube] ...: This content isn't available
```

### 手動更新流程

**步驟一：在你的電腦匯出新 cookies**

1. Chrome 安裝擴充套件 [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc)
2. 開啟 `youtube.com` 並確認已登入帳號
3. 點擴充套件 → 選 `Current Site` → `Export`，存成 `cookies.txt`

**步驟二：更新 master 上的備份檔**

```bash
# 貼上新的 cookies 內容（覆蓋舊檔）
vi /root/secrets-backup/metube-cookies.txt
```

**步驟三：重新 seal 並 push**

```bash
# 重新產生 Secret YAML（從檔案內容）
kubectl create secret generic metube-cookies \
  --namespace app-dev \
  --from-file=cookies.txt=/root/secrets-backup/metube-cookies.txt \
  --dry-run=client -o yaml \
  > /root/secrets-backup/metube-cookies-secret.yaml

# 用 cluster 的公鑰加密（產生 SealedSecret，可安全進 git）
KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /root/secrets-backup/metube-cookies-secret.yaml \
  > /opt/gitops-manifests/clusters/Master-5cf92/04-apps/metube/cookies-sealed-secret.yaml

# push → ArgoCD 自動更新 Pod 內的 cookies 檔
cd /opt/gitops-manifests
git add clusters/Master-5cf92/04-apps/metube/cookies-sealed-secret.yaml
git commit -m "chore: refresh metube youtube cookies"
git push
```

push 完約 3 分鐘後 ArgoCD 自動 apply，Pod 滾動重啟後帶入新 cookies。

### 可以自動化嗎？

| 部分 | 能否自動化 | 說明 |
|------|-----------|------|
| 匯出 cookies | ❌ | YouTube 需要真實瀏覽器登入，server 上無法自動執行 |
| kubeseal + git push | ✅ | 純 script，可以自動化 |

**半自動化方案（推薦）**

把 cookies 內容存為 GitHub Actions Secret，建一個 workflow，你只需要在 GitHub UI 更新 Secret，workflow 自動處理 seal + commit + push：

1. GitHub repo → Settings → Secrets and variables → Actions
2. 建立 Secret 名稱：`METUBE_COOKIES_B64`，值為 cookies.txt 的 base64：
   ```bash
   base64 -w0 /root/secrets-backup/metube-cookies.txt
   # 複製輸出，貼到 GitHub Secret 的值欄位
   ```
3. 建立 `.github/workflows/refresh-metube-cookies.yml`（手動觸發）：
   ```yaml
   name: Refresh MeTube Cookies
   on:
     workflow_dispatch:
   jobs:
     refresh:
       runs-on: ubuntu-latest
       permissions:
         contents: write
       steps:
         - uses: actions/checkout@v4
         - name: Decode cookies and create secret YAML
           run: |
             echo "${{ secrets.METUBE_COOKIES_B64 }}" | base64 -d > /tmp/cookies.txt
             kubectl create secret generic metube-cookies \
               --namespace app-dev \
               --from-file=cookies.txt=/tmp/cookies.txt \
               --dry-run=client -o yaml > /tmp/metube-cookies-secret.yaml
         - name: Seal secret
           run: |
             curl -sL https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/kubeseal-0.27.3-linux-amd64.tar.gz | tar xz kubeseal
             # 需要 cluster 的 public key（存為另一個 Secret: SEALED_SECRETS_CERT）
             echo "${{ secrets.SEALED_SECRETS_CERT }}" > /tmp/ss-cert.pem
             ./kubeseal --format=yaml --cert /tmp/ss-cert.pem \
               < /tmp/metube-cookies-secret.yaml \
               > clusters/Master-5cf92/04-apps/metube/cookies-sealed-secret.yaml
         - name: Commit and push
           run: |
             git config user.name "github-actions[bot]"
             git config user.email "github-actions[bot]@users.noreply.github.com"
             git add clusters/Master-5cf92/04-apps/metube/cookies-sealed-secret.yaml
             git commit -m "chore: refresh metube youtube cookies"
             git push
   ```
4. 備份 cluster 的 Sealed Secrets 公鑰（存為 `SEALED_SECRETS_CERT` Secret）：
   ```bash
   KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --fetch-cert \
     --controller-name=sealed-secrets \
     --controller-namespace=kube-system
   # 複製輸出的 PEM，貼到 GitHub Secret
   ```

之後只需更新 `METUBE_COOKIES_B64` 並手動觸發 workflow，全程不需登入 master。

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

# 2. 重新 seal（將 CLUSTER_ID 替換為實際值）
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
