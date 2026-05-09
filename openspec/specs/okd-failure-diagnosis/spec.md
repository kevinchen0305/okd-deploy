# okd-failure-diagnosis Specification

## Purpose
TBD - created by archiving change okd-ai-agent. Update Purpose after archive.
## Requirements
### Requirement: Diagnose 指令
系統 SHALL 提供 `/okd-diagnose <cluster_name>` 指令，讀取集群狀態與日誌，比對 playbook，輸出結構化建議。

#### Scenario: 命中 playbook
- **WHEN** user 對失敗集群執行 `/okd-diagnose dev01`，且 log 內容匹配某 playbook 的 signals
- **THEN** 輸出該 playbook 的「症狀」「原因」「建議動作（標號 a/b/c...）」
- **AND** 不執行任何自動修復動作
- **AND** 等待人選擇下一步

#### Scenario: 未命中 playbook
- **WHEN** log 內容不匹配任何 playbook signals
- **THEN** Claude 直接讀 log 摘要，列出最多 3 個值得查的方向
- **AND** 在 `docs/playbooks/_unknown.md` append 一筆，包含集群名、phase、log 片段
- **AND** 在輸出明示「此為 LLM 推測，非已知 playbook」

### Requirement: Playbook 檔案格式
系統 SHALL 採用 markdown + YAML frontmatter 的格式定義 playbook，前段機讀（給 AI 比對）、後段人讀。

#### Scenario: Playbook 必需欄位
- **WHEN** 建立新 playbook
- **THEN** YAML frontmatter MUST 包含 `id`、`applies_to_phase`、`signals`、`severity`、`auto_fixable`
- **AND** 內文 MUST 包含「症狀」「原因」「建議動作」三個段落

#### Scenario: Signals 結構
- **WHEN** playbook signals 用於比對
- **THEN** 每個 signal MUST 包含 `source`（`terraform_log` / `installer_log` / `aws_api_error` / `oc_output`）與比對條件（`pattern` regex 或 `code`）

### Requirement: 跨 skill 自動觸發
系統 SHALL 在 `okd-build`、`okd-verify`、`okd-teardown` 任一 skill 失敗時，自動 invoke `okd-diagnose`。

#### Scenario: Build 失敗自動診斷
- **WHEN** `okd-build` 任一 phase 失敗
- **THEN** 系統自動呼叫 `okd-diagnose <cluster_name>`，輸出到使用者面前

#### Scenario: Teardown 失敗自動診斷
- **WHEN** `terraform destroy` 失敗（如殘留 ENI / SG）
- **THEN** 系統自動呼叫 `okd-diagnose`，比對 `teardown-orphaned-resource` 等 teardown 相關 playbook

### Requirement: Phase-aware 診斷材料收集
系統 SHALL 依當前 phase 決定要收集的診斷材料，避免無謂讀取。

#### Scenario: installing phase 的材料
- **WHEN** phase=installing 失敗時 diagnose
- **THEN** 系統收集 `clusters/<name>/.openshift_install.log`（最後 200 行）、`aws ec2 describe-instances --filters tag:cluster=<name>`
- **AND** 不嘗試讀 `auth/kubeconfig`（尚未生成）

#### Scenario: verifying phase 的材料
- **WHEN** phase=verifying 失敗時 diagnose
- **THEN** 系統收集 `oc get co -o yaml`、`oc get nodes -o yaml`、`clusters/<name>/verify-report.json`

### Requirement: AI 不擅自動手
系統在「輕量診斷」模式 SHALL 僅輸出建議，不執行 AWS 變更或修復動作。

#### Scenario: 建議不自動執行
- **WHEN** diagnose 輸出建議「重跑 sts-creds.sh」
- **THEN** 系統不自動執行該指令
- **AND** 等待 user 明確輸入選擇（如 `a` / `b` / `c` / `skip`）

### Requirement: 知識庫成長機制
系統 SHALL 透過 `_unknown.md` 累積未匹配的失敗模式，供日後升格為正式 playbook。

#### Scenario: 未知失敗自動記錄
- **WHEN** diagnose 未命中 playbook
- **THEN** 在 `docs/playbooks/_unknown.md` append 結構化條目（含日期、集群、phase、log 片段、LLM 推測）
- **AND** 同一指紋的失敗（相同 phase + 相似 log 開頭）只記一次

### Requirement: MVP 初始 Playbook 集合
系統 SHALL 在初次部署時提供至少 12 個常見失敗 playbook，涵蓋 quota、STS、AMI、bootstrap、ingress、Route53、ccoctl、machineset、teardown 等類別。

#### Scenario: 必備 playbook 列表
- **WHEN** MVP 完成
- **THEN** `docs/playbooks/` 至少存在以下 id：`quota-exceeded-vpc`、`quota-exceeded-eip`、`quota-exceeded-ec2`、`sts-expired`、`sts-mfa-failed`、`ami-not-found`、`bootstrap-stuck`、`ingress-degraded`、`route53-resolution-failed`、`ccoctl-s3-conflict`、`machineset-no-subnet`、`teardown-orphaned-resource`
- **AND** `docs/playbooks/_index.md` 列出全部 playbook 與其 `applies_to_phase`

