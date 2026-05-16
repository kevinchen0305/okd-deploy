---
name: okd-teardown
description: Use when user wants to destroy one or more OKD clusters. Triggered by /okd-teardown
---

# okd-teardown

把一個或多個 OKD 集群在 AWS 上的所有資源清乾淨：installer destroy → terraform destroy → ccoctl 殘留（S3、IAM role、OIDC provider）一併清掉。

## 何時使用

- 使用者執行 `/okd-teardown <name1> [<name2> ...] [--purge]`。
- 使用者明確要回收 AWS 資源 / 釋放 quota。

## 參數

- 位置參數：一到多個 cluster 名稱。
- `--purge`：選填。除了清 AWS 資源外，連同 `clusters/<name>/` 整個目錄也刪掉（含 status.json、tfstate、kubeconfig）。**預設不啟用**，因為保留目錄方便事後 review。

## 整體流程

### 第 0 步：（可選）Preflight

teardown 不嚴格需要 preflight，但建議檢查 STS 是否有效（`scripts/preflight.sh --clusters <list> --version <ver> --region <r>` 只看 sts_valid 那項）。STS 過期就先停下來。

### 第 1 步：派發 sub-agent，每集群一個（並行）

每個 sub-agent 對自己的 cluster 跑：

```bash
scripts/teardown.sh --cluster <name>
```

`scripts/teardown.sh` 內部依當前 phase 決定要做哪幾步（spec 要求「部分建置失敗的 teardown」也能跑乾淨）：

| 當前 phase | 動作 |
|---|---|
| `installing` 之後（含 `ready`、`verifying`） | `bin/<ver>/openshift-install destroy cluster --dir=clusters/<name>` → terraform destroy → 清 ccoctl 殘留 |
| `setting_up_iam` ~ `patching_manifests` | 跳過 installer destroy；terraform destroy → 清 ccoctl 殘留 |
| `provisioning_vpc` 失敗 | 只跑 terraform destroy |
| `pending` | 只清 `clusters/<name>/`（無 AWS 資源） |

過程中 phase 推進為 `tearing_down`，最終成功為 `destroyed`。

`--purge` 在 sub-agent 最後追加：

```bash
rm -rf clusters/<name>
```

（即 status.json 也一併清掉。）

### 第 2 步：失敗時自動 diagnose

任何 `terraform destroy` 失敗（典型：`DependencyViolation`、殘留 ENI / SG 卡住）→ sub-agent 立即呼叫 `okd-diagnose` skill，把 cluster 名與 phase=`tearing_down` 丟過去，比對：

- `teardown-orphaned-resource` — generic DependencyViolation（ENI / LB / SG / route53）
- `teardown-guardduty-vpc-residue` — 帳號啟用 GuardDuty Runtime Monitoring 時，AWS 自動往 VPC 塞的 `guardduty-data` endpoint 跟 `GuardDutyManagedSecurityGroup-*` SG。terraform 看不見就卡 destroy

**不自動 retry、不自動強刪**，等使用者選擇。

### 重要 (post-mortem from 2026-05-16 lifecycle test)

- teardown.sh 的 `terraform destroy` 必須帶 `-var "cluster_name=..."` `-var "region=..."` `-var "az=..."`（從 `clusters/<name>/status.json` 讀），加 `AWS_REGION` env 給 AWS provider。否則 layer 2 失敗、所有 terraform 建的 VPC/subnets/NAT GW 全留下。
- `--purge` 跟 terraform destroy 失敗合在一起的後果：`clusters/<name>/` 連 tfstate 一起被刪 → 無法再用 terraform 收尾，只能 aws CLI 手動清。若 destroy 失敗，**不要 `--purge`**，先收乾淨再 purge。

### 第 3 步：主 agent 聚合

| Cluster | Result | AWS Residue | Notes |
|---|---|---|---|
| dev01 | destroyed | none | – |
| dev02 | tearing_down (failed) | 1 ENI stuck on subnet-xxx | diagnose hit `teardown-orphaned-resource` |
| dev03 | destroyed | none | --purge: dir removed |

## 範例

```
/okd-teardown dev01
/okd-teardown dev01 dev02 dev03
/okd-teardown dev01 --purge
```

## 重要約束

- **每集群並行**，但每集群內部嚴格序列（installer 先於 terraform，terraform 先於 ccoctl 清理）。
- **保留 `status.json` 是預設行為**，方便 review；`--purge` 才整個刪。
- **失敗不重試**：diagnose 給建議，使用者決定下一步（如手動清 ENI、或 `terraform destroy -refresh=false` 等）。
- 不允許在 `phase=ready` 集群上「跳過 installer destroy 直接 terraform destroy」，會留下殘留資源。
