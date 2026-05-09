## Why

現有 OKD 4.18 on AWS 的部署流程（`build-okd.md`）混合了 AWS Console 手動操作、shell script、與手動編輯 YAML，導致無法重現、易錯、無預檢、無驗證、無 teardown。Lab 場景需要頻繁 build/teardown 多個集群，痛點放大。引入 AI agent 介入後，主流程可由 IaC 與 skills 重複執行，AI 在預檢、診斷等難標準化的步驟提供判讀，使 Lab 工作流可重現、可並行、可診斷。

## What Changes

- **新增** Terraform 模組 `modules/vpc/`，取代手動 AWS Console VPC 建立
- **新增** `bin/<version>/` 目錄分版本管理 OKD 工具（openshift-install / ccoctl / oc），支援多 OKD 版本共存
- **新增** 7 個 shell 腳本，包裝 STS/MFA、ccoctl、install-config 渲染、machineset patch、installer、verify、teardown
- **新增** 5 個 Claude Code skill：`okd-preflight`、`okd-build`、`okd-verify`、`okd-teardown`、`okd-diagnose`，與對應 slash commands
- **新增** `clusters/<name>/` 每集群隔離目錄結構，含 terraform state、status.json、verify-report.json
- **新增** `docs/playbooks/` 失敗模式知識庫（~12 個初始 playbook），供 diagnose 對照
- **新增** 並行 build 能力：`/okd-build dev01 dev02 ...` 由子 agent 派發
- **新增** AWS quota 聚合預檢，撞上 quota 上限提前報錯並建議降併發
- **新增** `install-config.yaml.tmpl` 模板，取代手動編輯
- **棄用**（非 BREAKING） 原 `build-okd.md` 中的手動步驟，但檔案保留作參考

## Capabilities

### New Capabilities
- `okd-cluster-lifecycle`: build / verify / teardown OKD 4.18 集群於 AWS 的端到端流程，支援 N 個並行
- `okd-preflight-checks`: 在 AWS 動作前驗證 quota / IAM / STS / AMI / 工具版本 / 目錄衝突
- `okd-failure-diagnosis`: 讀 status + log + AWS state，比對 playbook，輸出建議讓人決定下一步
- `okd-tool-versions`: 多 OKD 版本工具管理（bin/<version>/ 目錄）與每集群版本鎖定

### Modified Capabilities
- 無（首次建立，現有 `openspec/specs/` 為空）

## Impact

- **新增程式碼**：`modules/vpc/`（Terraform）、`scripts/`（shell）、`templates/`、`.claude/skills/`、`.claude/commands/`、`docs/playbooks/`
- **新增執行依賴**：`terraform`、`aws` CLI、`jq`、`yq`、`oathtool`、`shellcheck`、`bats`（後兩者僅 dev）
- **AWS 帳號影響**：每集群動用 1 VPC + 1 NAT + 1 EIP + ~4 EC2 instance + 1 S3 bucket + 1 OIDC provider + 多個 IAM role；受 default quota 限制（VPC=5/region）
- **使用者工作流變更**：從「依 build-okd.md 手動點擊」轉為「Claude Code 內輸入 `/okd-build <name>`」
- **無 BREAKING changes**：是新增建置路徑，舊 `build-okd.md` 仍可手動執行
