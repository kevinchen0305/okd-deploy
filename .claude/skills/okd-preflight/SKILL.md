---
name: okd-preflight
description: Use before any AWS-touching OKD operation; validates quota/STS/AMI/tools/account-id consistency for one or more clusters
---

# okd-preflight

在任何「會動到 AWS」的 OKD 操作之前先跑一輪預檢。此 skill 為 **read-only**，不會建立、不會修改任何 AWS 資源，也不會建立 `clusters/<name>/` 目錄。

## 何時使用

- 使用者執行 `/okd-preflight ...` 時直接觸發。
- 由 `okd-build`、`okd-teardown` 等 skill 在開始實際動作之前內部呼叫一次（共用一次預檢，覆蓋所有目標集群）。
- 使用者懷疑環境不對（剛換 region / 換 account / quota 變動）時手動跑。

## 入口腳本

```bash
scripts/preflight.sh \
  --clusters <name1>[,<name2>,...] \
  --version <okd-version> \
  --region <aws-region> \
  [--worker-replicas N]
```

預設 `--version` 為 `4.18.0-okd-scos.10`。`--region` 若未提供，從環境變數 `REGION` 讀取。

`--worker-replicas` 預設讀 `WORKER_REPLICAS` 環境變數,沒設就 `2`。它**直接影響 EIP 配額檢查**:每個 cluster 需 `1 (NAT GW) + N (workers)` 個 EIP,VPC 模組會用 terraform 預先 allocate 給之後 attach 用。預設 region quota 是 5,並行 build 多 cluster 時容易踩線 — 不夠就 `quota_eips=fail` 擋住,不讓 build 開始。

## 行為

1. 呼叫 `scripts/preflight.sh --json`，把 N 個 cluster 名稱與目標版本帶進去。
2. 該腳本輸出 JSON 到 stdout，schema 如下（**check name 與 `all_passed` 欄位都跟 script 對齊，不要自己改名**）：
   ```json
   {
     "version": "4.18.0-okd-scos.10",
     "region": "ap-northeast-1",
     "clusters": ["dev01", "dev02"],
     "checks": [
       {"name": "tools_installed",     "status": "ok|warn|fail", "detail": "...", "suggestion": "..."},
       {"name": "sts_valid",           "status": "...", "detail": "arn=..."},
       {"name": "name_conflict",       "status": "...", "detail": "clusters/dev01 not exists"},
       {"name": "ami_exists",          "status": "...", "detail": "ami-... in region"},
       {"name": "account_consistency", "status": "...", "detail": "STS account=..."},
       {"name": "quota_vpcs",          "status": "...", "detail": "limit=X used=Y remaining=Z need=N"},
       {"name": "quota_nat_gws",       "status": "...", "detail": "..."},
       {"name": "quota_eips",          "status": "...", "detail": "..."},
       {"name": "quota_vcpus_m5",      "status": "...", "detail": "..."}
     ],
     "all_passed": true
   }
   ```
3. Parse JSON 後，把結果以 markdown 表格呈現給使用者：

   | Check | Status | Detail |
   |---|---|---|
   | tools_installed | ok | bin/<ver>/openshift-install/ccoctl/oc |
   | sts_valid | ok | arn=assumed-role/... |
   | quota_vpcs | warn | limit=5 used=4 remaining=1 need=2 |
   | ... | ... | ... |

4. 若 `all_passed == false`（即任何 check `status=fail`）：
   - 列出所有 fail 項，附 `suggestion` 欄裡的修復指令。
   - 嘗試命中 playbook，命中則 **呼叫 `okd-diagnose` skill** 由它列建議。check name → playbook 對照：
     - `quota_vpcs` → `quota-exceeded-vpc`
     - `quota_eips` → `quota-exceeded-eip`
     - `quota_vcpus_m5` → `quota-exceeded-ec2`
     - `sts_valid` → `sts-expired`
     - `ami_exists` → `ami-not-found`
   - **絕不**自動修復。

5. 若 `all_passed == true` 但有 `status=warn` 項：列警告，回「可繼續」訊號給呼叫端（如 `okd-build`）。
6. 若全 ok：直接回傳成功，呼叫端進入下一步。

## 範例調用

```bash
# 單集群、預設版本
scripts/preflight.sh --clusters dev01 --version 4.18.0-okd-scos.10 --region ap-northeast-1

# 三集群並行 build 前
scripts/preflight.sh --clusters dev01,dev02,dev03 --version 4.18.0-okd-scos.10 --region ap-northeast-1
```

## 重要約束

- **不修改任何 AWS 資源**：只跑 `aws ec2 describe-*`、`aws sts get-caller-identity`、`aws service-quotas get-service-quota`、`aws iam get-role` 之類的 read-only API。
- **不建立 `clusters/<name>/` 目錄**：名稱衝突檢查只是 `[ -d clusters/<name> ]`，不寫檔。
- **不互動**：所有需要的設定一次從參數與環境變數取得；缺少時直接 fail，由呼叫端決定怎麼補。
- 失敗時退出碼 ≠ 0；呼叫端（`okd-build` 等）必須檢查退出碼，禁止吞掉。
