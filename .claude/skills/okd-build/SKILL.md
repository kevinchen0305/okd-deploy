---
name: okd-build
description: Use when user wants to build (create) one or more OKD 4.18 clusters on AWS. Triggered by /okd-build
---

# okd-build

從零建置一個或多個 OKD 4.18 集群於 AWS。每個集群一份獨立 VPC、IAM、Terraform state，最終產出可登入的 cluster + kubeconfig + console URL。

## 何時使用

- 使用者執行 `/okd-build <name> [<name2> ...] [--version X]`。
- 使用者明確說「我要建一個 OKD 集群叫 …」或「幫我並行起 N 個 lab cluster」。

## 參數解析

- 位置參數：一到多個 cluster 名稱（如 `dev01 dev02 dev03`）。
- `--version <ver>`：選填，預設 `4.18.0-okd-scos.10`。所有集群共用此版本（同一次 build 不混版本）。

## 必要環境變數

開工前先檢查以下變數，缺失就停下來請使用者設定（可指引讀 `.env`）：

| 變數 | 用途 |
|---|---|
| `BASE_DOMAIN` | OKD base domain，install-config 用 |
| `AMI_ID` | RHCOS AMI ID（region 相關） |
| `REGION` | AWS region，如 `ap-northeast-1` |
| `AZ` | 單 AZ 部署用（lab-only） |
| `VPC_CIDR` | VPC CIDR，如 `10.0.0.0/16` |
| `PULL_SECRET` | Pull secret JSON 字串內容（不是路徑） |
| `SSH_KEY` | SSH public key 檔路徑 |
| `MASTER_INSTANCE_TYPE` | 例 `m5.2xlarge`。**沒有 default — 每個集群都要明確選**，避免無意中跑 $0.768/hr 的機型 |
| `WORKER_INSTANCE_TYPE` | 例 `m5.xlarge`（lab 推薦）/`m5.4xlarge`（重 workload）。**無 default** |
| `MASTER_REPLICAS` | lab 只能 `1`；HA 一律 `3` |
| `WORKER_REPLICAS` | 例 `2`。每多一台直接乘上 `WORKER_INSTANCE_TYPE` 小時費率 |

缺任何一項立即終止，回應使用者：「請先設定環境變數 X / Y / Z（建議寫進 `.env`）」。

**sizing 為什麼強制**：master/worker instance type 跟 replicas 直接決定 AWS 帳單，不該被 silent default 蓋掉。`render-config.sh` 缺這四個會直接 exit，不允許「忘了設就跑」。

## 整體流程

### 第 0 步：Preflight（共用一次）

呼叫 `okd-preflight` skill。把全部 cluster 名稱、`--version`、以及 `--worker-replicas` 一次丟進去 — worker-replicas 用來算 EIP 需求（每 cluster 1 NAT + N worker），preflight 在配額不夠時會直接擋住 build：

```bash
scripts/preflight.sh --clusters dev01,dev02,dev03 \
  --version 4.18.0-okd-scos.10 \
  --region "$REGION" \
  --worker-replicas "$WORKER_REPLICAS"
```

`overall=fail` → 終止，把 preflight 的結果丟給使用者，必要時讓 `okd-diagnose` 接手。
`overall=warn` 或 `ok` → 繼續。

### 第 1 步：派發 sub-agent，每集群一個（並行）

使用 `superpowers:dispatching-parallel-agents` 的方式：在**同一個回應**裡用 Agent 工具（`subagent_type: general-purpose`）發出 N 個 sub-agent 呼叫，每個 sub-agent 負責一個集群完整生命週期。

每個 sub-agent 的工作（嚴格依序）：

1. **建目錄與初始化 status**
   ```bash
   mkdir -p clusters/<name>
   cat > clusters/<name>/status.json <<EOF
   {"name":"<name>","phase":"pending","phase_history":[],"last_error":null}
   EOF
   echo "<version>" > clusters/<name>/version
   ```

2. **provisioning_vpc**：把 phase 推進到 `provisioning_vpc`，跑 Terraform。**`worker_replicas` 必須帶入** — VPC 模組會 `count = var.worker_replicas` 預先 allocate 對應數量的 EIP，留給後面 `attach-worker-eips.sh` 使用：
   ```bash
   mkdir -p clusters/<name>/terraform
   cp -r modules/vpc/* clusters/<name>/terraform/
   cd clusters/<name>/terraform
   terraform init
   terraform apply -auto-approve \
     -var "cluster_name=<name>" \
     -var "region=$REGION" \
     -var "az=$AZ" \
     -var "worker_replicas=$WORKER_REPLICAS"
   ```

3. **setting_up_iam**：phase=`setting_up_iam`
   ```bash
   scripts/ccoctl-setup.sh --cluster <name> --region "$REGION"
   ```

4. **rendering_config**：phase=`rendering_config`
   ```bash
   scripts/render-config.sh --cluster <name>
   ```
   （腳本會用 `BASE_DOMAIN`、`AMI_ID`、`PULL_SECRET`、`SSH_KEY` 等環境變數渲染 `templates/install-config.yaml.tmpl` → `clusters/<name>/install-config.yaml`）

5. **manifests 生成**
   ```bash
   bin/<version>/openshift-install create manifests --dir=clusters/<name>
   ```

6. **patching_manifests**：phase=`patching_manifests`
   ```bash
   scripts/patch-machineset.sh --cluster <name>
   ```

7. **(no-op for current ccoctl flow)** — 早期版本需要 `cp cco_manifests/* manifests/`，但目前 `ccoctl aws create-identity-provider` + `create-iam-roles` 已經把 `cluster-authentication-02-config.yaml` 跟 6 個 credential secret manifests 直接寫到 `clusters/<name>/manifests/`，無另外 copy 步驟。`install.sh` 仍保留 `credrequests/` → `manifests/` 的 copy 作為 STS Manual 模式 CCO 對齊用。

8. **installing**：phase=`installing`
   ```bash
   scripts/install.sh --cluster <name>
   ```

   **進度回饋（required）**：installing phase 預期 30–45 分鐘，**不可以靜默**。每 ~5 分鐘給使用者一次摘要，內容至少包含：
   - `grep '^level=info' clusters/<name>/.openshift_install.log | tail -5` 最後幾個 milestone
   - `oc --kubeconfig=clusters/<name>/auth/kubeconfig get co --no-headers | awk '$3!="True" || $4!="False" || $5!="False"'` 列出未健康 operator（kubeconfig 一旦生成就可以查）
   - 當前 elapsed time + 預估剩餘

   實作方式 agent 自選（`/loop 5m`、`Monitor` tool、ScheduleWakeup、etc.）。**靜默超過 30 分鐘等於失敗** — 使用者誤以為卡住會中斷 → 整個 build 報廢。

9. **attach worker EIPs**：把 Terraform 第 2 步預配的 EIP 綁到剛起來的 worker。執行時間視 MachineSet 收斂速度,通常 install 完之後 worker 已經 Running 了,腳本內部會 poll 直到 N 個 worker 進入 `Running` 才開始 associate。
   ```bash
   scripts/attach-worker-eips.sh --cluster <name>
   ```
   失敗(timeout、associate-address 報錯)→ fail_with_diagnose,進入 diagnose。已知限制:**之後 MachineSet scale-out 的新 worker 不會自動拿 EIP** — lab 用法可接受,需要時手動再跑一次本腳本。

10. **verifying**：phase=`verifying`
    ```bash
    scripts/verify.sh --cluster <name>
    ```
    verify 全綠 → phase=`ready`。verify 會包含 `worker_eips` 一項,確認每個 tagged EIP 都已 associated。**driver agent 收到 verify ok 後要主動關掉 step 8 的進度 loop**（CronDelete / TaskStop），避免 cron 繼續打 log。

任一步驟失敗 → sub-agent 不再前進，**呼叫 `okd-diagnose` skill** 把該 cluster 名稱與當前 phase 丟過去，把 diagnose 結果回傳給主 agent。

### 第 2 步：主 agent 聚合

等所有 sub-agent 結束後，列出聚合表：

| Cluster | Phase | Kubeconfig | Console URL | Notes |
|---|---|---|---|---|
| dev01 | ready | `clusters/dev01/auth/kubeconfig` | `https://console-openshift-console.apps.dev01.<base_domain>` | – |
| dev02 | installing (failed) | – | – | diagnose hit `bootstrap-stuck` |
| dev03 | ready | `clusters/dev03/auth/kubeconfig` | `https://console-openshift-console.apps.dev03.<base_domain>` | – |

對失敗集群，把 diagnose 的「症狀／原因／建議動作 a/b/c」直接附上，等使用者選下一步。

## 範例使用者指令

```
/okd-build dev01
/okd-build dev01 dev02 dev03
/okd-build dev01 --version 4.18.0-okd-scos.10
```

## 重要約束

- **同一次 build 全部集群共用一個版本**（`--version`）。混版本要分次跑。
- **每集群獨立 VPC + 獨立 tfstate**，路徑為 `clusters/<name>/terraform/terraform.tfstate`。
- **腳本一律用 `bin/<version>/<tool>` 絕對路徑**，禁止依賴 PATH。
- 任何步驟失敗都不前進；diagnose 只「建議」，不自動執行。
