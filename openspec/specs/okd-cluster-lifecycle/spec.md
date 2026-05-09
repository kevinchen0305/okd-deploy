# okd-cluster-lifecycle Specification

## Purpose
TBD - created by archiving change okd-ai-agent. Update Purpose after archive.
## Requirements
### Requirement: 單集群端到端建置
系統 SHALL 提供 `/okd-build <cluster_name>` 指令，從零建立一個 OKD 4.18 集群於 AWS，包含 VPC、IAM、ccoctl IDP、installer、verify，全程不需人介入。

#### Scenario: 快樂路徑單集群建置
- **WHEN** user 在乾淨環境執行 `/okd-build dev01`，且 AWS quota 足夠、STS 有效、AMI 存在
- **THEN** 系統依序執行 preflight → terraform apply → ccoctl-setup → render-config → patch-machineset → install → verify
- **AND** `clusters/dev01/status.json` 的 `phase` 最終為 `ready`
- **AND** `clusters/dev01/auth/kubeconfig` 存在且可用
- **AND** `clusters/dev01/verify-report.json` 所有檢查項標 ok

#### Scenario: 集群名稱已存在
- **WHEN** user 執行 `/okd-build dev01`，但 `clusters/dev01/` 已存在
- **THEN** preflight 報「集群名稱衝突」錯誤
- **AND** 不執行任何 AWS 變更動作

### Requirement: 多集群並行建置
系統 SHALL 接受 `/okd-build <name1> <name2> ...` 多參數形式，並行建立 N 個集群，每集群在各自的子 agent 中執行。

#### Scenario: 兩集群並行成功
- **WHEN** user 執行 `/okd-build dev01 dev02`，AWS quota 足夠 2 集群
- **THEN** 系統共用 preflight 一次性檢查 2 集群所需總量
- **AND** 派發 2 個子 agent 並行執行
- **AND** 兩集群最終 phase 皆為 `ready`，互不干擾

#### Scenario: Quota 不足拒絕並行
- **WHEN** user 執行 `/okd-build dev01..dev05`，但 AWS region 僅剩 2 個 VPC quota
- **THEN** preflight 失敗並列出三個建議：teardown 閒置集群 / 申請 quota / 降併發
- **AND** 不啟動任何子 agent

### Requirement: 集群驗證
系統 SHALL 提供 `/okd-verify <cluster_name>` 指令，對指定集群跑健康檢查並更新報告。

#### Scenario: 健康集群通過驗證
- **WHEN** user 對 phase=ready 的集群執行 `/okd-verify dev01`
- **THEN** 系統用 `clusters/dev01/auth/kubeconfig` 跑 oc 指令檢查 nodes、ClusterOperators、core workloads、networking
- **AND** 所有檢查通過時，`clusters/dev01/verify-report.json` 全綠且 `status.json` 的 `verify_summary` 全部標 ok

#### Scenario: ClusterOperator degraded 自動觸發 diagnose
- **WHEN** verify 偵測到任何 ClusterOperator `Degraded=True`
- **THEN** 系統自動 invoke `okd-diagnose` skill
- **AND** verify-report 該項標 fail 並附帶 diagnose 摘要

### Requirement: 集群拆除
系統 SHALL 提供 `/okd-teardown <cluster_name>` 指令，徹底清除指定集群在 AWS 上的所有資源並更新 status。

#### Scenario: 完整 teardown 無殘留
- **WHEN** user 對 phase=ready 的集群執行 `/okd-teardown dev01`
- **THEN** 系統依序執行 `openshift-install destroy cluster` → `terraform destroy` → 清 ccoctl 建的 S3 bucket / IAM roles / OIDC provider
- **AND** AWS Console 上沒有任何含 `dev01` tag 的 EC2、VPC、Subnet、IGW、NAT、EIP、SG、IAM role、S3 bucket、Route53 zone
- **AND** `clusters/dev01/status.json` 的 phase 為 `destroyed`

#### Scenario: 部分建置失敗的 teardown
- **WHEN** user 對 phase=installing（中段失敗）的集群執行 `/okd-teardown dev01`
- **THEN** 系統依當前 phase 跳過已未建立的層（如 installer 從未啟動則跳過 installer destroy）
- **AND** 仍清除 terraform 已建的 VPC 與 ccoctl 已建的 IAM/S3
- **AND** 最終 phase 為 `destroyed`

### Requirement: 集群隔離
系統 SHALL 確保並行集群之間不共享 terraform state、不共用 AWS 資源（VPC、Subnet、NAT、IAM role、S3 bucket）。

#### Scenario: Per-cluster terraform state
- **WHEN** 系統建立 cluster `dev01` 與 `dev02`
- **THEN** `clusters/dev01/terraform/terraform.tfstate` 與 `clusters/dev02/terraform/terraform.tfstate` 為兩份獨立檔案
- **AND** 兩集群擁有不同 VPC ID

#### Scenario: 集群刪除不影響其他集群
- **WHEN** 集群 `dev01`、`dev02` 同時 ready，user 執行 `/okd-teardown dev01`
- **THEN** `dev01` 完整清除
- **AND** `dev02` 集群完全不受影響，verify 仍全綠

### Requirement: Phase 機讀化狀態
系統 SHALL 為每集群維護 `clusters/<name>/status.json`，phase 取自嚴格列舉：`pending`、`provisioning_vpc`、`getting_creds`、`setting_up_iam`、`rendering_config`、`patching_manifests`、`installing`、`verifying`、`ready`、`tearing_down`、`destroyed`。

#### Scenario: 步驟成功更新 phase
- **WHEN** 任一腳本完成自己負責的階段
- **THEN** 該腳本 MUST 用 `jq` 把 `status.json` 的 `phase` 更新為對應值，並 append 一筆 `phase_history`

#### Scenario: 步驟失敗保留 phase
- **WHEN** 任一階段失敗
- **THEN** `phase` 停在當下值（不變）
- **AND** `last_error` 寫入錯誤摘要

