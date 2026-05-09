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
scripts/preflight.sh --clusters <name1>[,<name2>,...] --version <okd-version> --region <aws-region>
```

預設 `--version` 為 `4.18.0-okd-scos.10`。`--region` 若未提供，從環境變數 `REGION` 讀取。

## 行為

1. 呼叫 `scripts/preflight.sh`，把 N 個 cluster 名稱與目標版本帶進去。
2. 該腳本會輸出一份 JSON 結果到 stdout，欄位至少包含：
   ```json
   {
     "clusters": ["dev01", "dev02"],
     "version": "4.18.0-okd-scos.10",
     "region": "ap-northeast-1",
     "checks": [
       {"name": "aws_quota_vpc",      "status": "ok|warn|fail", "detail": "..."},
       {"name": "aws_quota_eip",      "status": "...", "detail": "..."},
       {"name": "aws_quota_natgw",    "status": "...", "detail": "..."},
       {"name": "aws_quota_ec2",      "status": "...", "detail": "..."},
       {"name": "sts_valid",          "status": "...", "detail": "expires_in_seconds=..."},
       {"name": "ami_exists",         "status": "...", "detail": "ami_id=..."},
       {"name": "tools_present",      "status": "...", "detail": "bin/4.18.0-okd-scos.10/{openshift-install,ccoctl,oc}"},
       {"name": "cluster_name_free",  "status": "...", "detail": "clusters/dev01 not exists"},
       {"name": "account_id_consistent", "status": "...", "detail": "sts_account=123 install_config_account=123"}
     ],
     "overall": "ok|warn|fail"
   }
   ```
3. 解析 JSON 後，把結果以 markdown 表格呈現給使用者：

   | Check | Status | Detail |
   |---|---|---|
   | aws_quota_vpc | ok | requested=2 remaining=3 |
   | sts_valid | warn | expires_in=42min |
   | ... | ... | ... |

4. 若 `overall == "fail"`：
   - 列出所有 `status=fail` 的項目。
   - 對每個 fail 嘗試命中 playbook（如 `quota-exceeded-vpc`、`sts-expired`、`ami-not-found`、`account-id-mismatch`）；若有命中，**呼叫 `okd-diagnose` skill** 把該失敗丟過去，由 diagnose 列出建議。
   - **絕不**自動修復。

5. 若 `overall == "warn"`：列警告但回傳「可繼續」訊號給呼叫端（如 `okd-build`）。
6. 若 `overall == "ok"`：直接回傳成功，呼叫端可進入下一步。

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
