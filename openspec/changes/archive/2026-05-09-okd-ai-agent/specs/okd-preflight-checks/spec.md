## ADDED Requirements

### Requirement: AWS Quota 聚合預檢
系統 SHALL 在任何 AWS 變更動作之前，計算 N 集群所需資源總量，並對照 AWS Service Quotas API 回傳的剩餘量，不足時拒絕繼續。

#### Scenario: 單集群 quota 充足
- **WHEN** user 執行 `/okd-build dev01` 且 region 內 VPC 剩餘 ≥1、EIP 剩餘 ≥1、NAT Gateway 剩餘 ≥1、相關 EC2 instance type 配額足夠
- **THEN** preflight 通過

#### Scenario: 多集群 quota 不足
- **WHEN** user 執行 `/okd-build dev01..dev05` 但 VPC 僅剩 2 個 quota
- **THEN** preflight 失敗
- **AND** 報告須列出：請求量（5）、剩餘量（2）、quota 上限（5）
- **AND** 建議三選一：teardown 閒置集群 / 申請 quota / 降併發

### Requirement: STS 憑證有效性檢查
系統 SHALL 在執行任何 AWS 變更前，驗證 STS 憑證有效且剩餘時間足夠完成預估流程（建議 ≥1 小時）。

#### Scenario: 憑證無效
- **WHEN** preflight 執行 `aws sts get-caller-identity` 失敗
- **THEN** preflight 失敗並建議重跑 `scripts/sts-creds.sh`

#### Scenario: 憑證即將過期
- **WHEN** STS 憑證剩餘有效期 < 60 分鐘
- **THEN** preflight 警告但允許繼續，並建議重跑 sts-creds 以延長時效

### Requirement: AMI 存在性檢查
系統 SHALL 驗證 install-config 引用的 AMI ID 在目標 region 確實存在且帳號有讀取權限。

#### Scenario: AMI 不存在
- **WHEN** install-config 內 AMI ID 在指定 region 找不到
- **THEN** preflight 失敗，匹配 `ami-not-found` playbook 並列建議

### Requirement: 工具版本檢查
系統 SHALL 驗證 `bin/<version>/` 目錄下 `openshift-install`、`ccoctl`、`oc` 三個檔案皆存在且可執行。

#### Scenario: 工具缺失
- **WHEN** user 執行 `/okd-build dev01 --version 4.18.0-okd-scos.10` 但 `bin/4.18.0-okd-scos.10/openshift-install` 不存在
- **THEN** preflight 失敗並提示如何下載對應版本

### Requirement: 集群名稱衝突檢查
系統 SHALL 在開始任何動作前檢查 `clusters/<cluster_name>/` 是否已存在。

#### Scenario: 名稱已被使用
- **WHEN** user 執行 `/okd-build dev01` 但 `clusters/dev01/` 已存在
- **THEN** preflight 失敗並建議改名或先 teardown

### Requirement: Account ID 一致性檢查
系統 SHALL 解析當前 STS 憑證對應的 AWS account ID，並驗證 install-config / IAM role ARN 中所有 account ID 引用一致。

#### Scenario: Account ID 不一致
- **WHEN** STS 憑證屬於 account A，但 install-config 中 IAM role ARN 屬於 account B
- **THEN** preflight 失敗並印出兩個 account ID 與不一致欄位位置

### Requirement: 預檢為 read-only
系統 SHALL 確保 preflight 階段不修改任何 AWS 狀態、不寫入 `clusters/<name>/` 集群目錄。

#### Scenario: Preflight 失敗無副作用
- **WHEN** preflight 任一檢查失敗
- **THEN** AWS 上沒有任何新增資源
- **AND** `clusters/<name>/` 目錄未被建立
