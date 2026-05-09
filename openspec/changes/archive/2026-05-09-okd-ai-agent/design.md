## Context

現有 `build-okd.md` 是部分自動化的 OKD 4.18 建置流程：VPC 全手動，install-config 與 machineset 需手動編輯，STS MFA code 寫死在 script。Lab 場景需頻繁 build / teardown 多集群，現行流程無法重現也無預檢與診斷。本設計以 IaC 為骨幹、Claude Code Skills 為使用介面，AI 只在難標準化的判讀步驟（preflight、diagnose）介入。完整背景與資料流參見 `docs/superpowers/specs/2026-05-09-okd-ai-agent-design.md`。

## Goals / Non-Goals

**Goals:**
- 把 7 個手動步驟全部 IaC / 腳本化，可重複、可 diff
- 支援 N 個集群並行 build / teardown
- AI agent 在預檢與診斷兩處主動介入，提供結構化建議讓人決定
- Teardown 完整清乾淨，無 AWS 殘留資源
- 工具版本與集群綁定（每集群鎖在自己的 OKD 版本）
- 不開啟 Claude Code 也能跑（IaC + 腳本獨立可用，AI 是加分）

**Non-Goals:**
- 集群升級（4.18 → 4.19）
- 監控 / 告警接入（Prometheus、Slack）
- 多 region / 多 account 切換
- Day-2 operations（加 worker、改 storage class）
- AI 自動修復（playbook 預留 `auto_fixable` 欄位但 MVP 不啟用）
- Production-grade HA（MVP 用 1 master，明確標示為 lab-only）

## Decisions

### D1：IaC 骨幹 + AI 邊緣決策（不選「AI 全程驅動」）
所有可標準化的步驟（terraform、shell）放在 IaC 與腳本，AI 只負責預檢、診斷。
- **替代方案**：AI 全程驅動每一步（讀 build-okd.md 當劇本）
- **不選原因**：每次 build 跨許多 token、行為難預測；標準化步驟用 IaC 一勞永逸

### D2：5 個獨立 skill（Approach A，不選 mega-skill 也不選 operator+knowledge 分離）
`okd-preflight` / `okd-build` / `okd-verify` / `okd-teardown` / `okd-diagnose` 各一個 skill。
- **替代方案 B**：單一 mega-skill 用動詞當參數
- **替代方案 C**：operator + knowledge 分離（playbook 知識庫獨立成 skill）
- **不選原因**：B 的 skill 描述難精準（Claude Code 用 description 觸發）；C 對 Lab 規模殺雞用牛刀，knowledge 可用 `docs/playbooks/` markdown 檔達成

### D3：每集群獨立 VPC（Model 1，不選共用 VPC Model 2/3）
每集群一份完整 VPC + Subnet + NAT。
- **替代方案 Model 2**：共用 VPC、每集群獨立 subnet pair（省 NAT 成本 ~$33×N/月）
- **替代方案 Model 3**：完全共用 VPC + subnets
- **不選原因**：Lab 偏好「teardown 時 destroy 整 VPC = 完全乾淨」的明確語意；N 通常 ≤4 落在 default quota 內，省下的 NAT 不重要

### D4：`bin/<version>/` 多版本管理（不用 Docker）
工具按版本放在 `bin/4.18.0-okd-scos.10/`、`bin/4.19.0-.../`。每集群 `clusters/<name>/version` 鎖版本，腳本依該檔挑工具。
- **替代方案**：Docker image per version
- **不選原因**：Docker 多一層 volume / env / UID 對應雜訊；STS 憑證傳遞與 MFA 互動體驗變差；Skill 每個 Bash 指令要 `docker run` 包裝；目錄分版本已能解相同問題

### D5：並行 build 用 superpowers/dispatching-parallel-agents
`/okd-build dev01 dev02 dev03` 派 N 個 sub-agent，每個負責一個集群完整生命週期，主 agent 聚合 status。
- **替代方案**：序列建置 / 用 `xargs -P` shell 級並行
- **不選原因**：序列慢；shell 級並行無法把錯誤訊息聚合成可讀報告，sub-agent 能在自己上下文中跑 diagnose

### D6：Per-cluster Terraform state（不用 workspace）
每集群一份 `clusters/<name>/terraform/`，內含獨立 tfstate；`modules/vpc/` 為共用模組。
- **替代方案**：terraform workspaces
- **不選原因**：workspace 在「同一 state 檔換命名空間」，視覺上不直觀；獨立目錄 + 獨立 state 與 `clusters/<name>/` 結構自然對齊，teardown 時可整個目錄清掉

### D7：輕量診斷模式（AI 不擅自動手）
`okd-diagnose` 讀 status + log，比對 playbook，列「症狀 + 原因 + 建議動作 (a/b/c)」，由人選。
- **替代方案**：AI 中度自動修復（quota / STS 過期等常見問題自己修）
- **不選原因**：Lab 場景下「重建」常比「修復」快且乾淨；MVP 先把 playbook 累積起來再決定哪些升級為自動修復

### D8：Phase 機讀化的 status.json
每集群一份 `status.json`，phase 嚴格列舉（`pending` → `provisioning_vpc` → ... → `ready`）。所有腳本透過 `jq` 更新；diagnose / verify / teardown 都先讀此檔決定行為。
- **替代方案**：靠檔案存在性推斷（如 `auth/kubeconfig` 在 = installed）
- **不選原因**：失敗中段時推斷不準；jq 讀寫單一 JSON 易維護

## Risks / Trade-offs

| 風險 | 緩解 |
|---|---|
| AWS quota 預設僅支援 ~4 並行 VPC | preflight 提前報、給降併發建議；長期送 quota 增加申請 |
| OKD 工具版本與集群綁死，拿錯版本可能弄壞老集群 | `clusters/<name>/version` + 腳本嚴格依該檔挑 `bin/<version>/` |
| STS 憑證 12 小時過期，長 build 中段斷 | install 前重跑 sts-creds；過期錯誤匹配 `sts-expired` playbook |
| `_unknown.md` 不被人定期整理 → 知識庫不成長 | 每月 review；可寫 skill 自動 summarise |
| Account ID 在 build-okd.md 中可能不一致 | preflight 把 STS 解出的 account ID 與 install-config 內 ARN 比對 |
| Single AZ + 1 master 的脆弱性 | 接受，spec 明示為 lab-only；production 配置另立 spec |
| MFA 自動化（oathtool）需把 secret 寫進機器 | 標示為 lab-only；production 應用 SSO / 短期 token 替代 |
| Skill 行為靠 LLM 解讀 markdown，難寫黃金測試 | 改用「演練清單」：大改後手動跑一輪 build → verify → teardown |
| Playbook 模式比對不命中時 AI 推測可能離譜 | 不命中時也記到 `_unknown.md`，並明示「此為 LLM 推測非 playbook」 |

## Migration Plan

本變更為新增式（greenfield），無既有系統需遷移。落地步驟：

1. **第一階段（基礎）**：`modules/vpc/` + `scripts/sts-creds.sh` + `bin/4.18.0-okd-scos.10/` 工具下載
2. **第二階段（端到端 build）**：其餘 6 個 scripts + `templates/install-config.yaml.tmpl` + 5 個 skills + slash commands；通過「單集群 build → verify → teardown」驗收
3. **第三階段（並行與診斷）**：parallel agent 派發 + 12 個初始 playbooks；通過「並行 N 集群」與「故意觸發 quota / AMI 錯誤命中 playbook」驗收

無 rollback 需要（純新增）。舊 `build-okd.md` 保留作 fallback 與參考。

## Open Questions

- `_unknown.md` 何時、由誰升格為正式 playbook？建議每月 review，但實際節奏待用過幾輪後定。
- 是否需要 `okd-tools` skill 提供 `install/list/remove` 操作？或寫成純腳本即可？傾向後者，簡單。
- preflight 對 quota 的查詢是否要 cache？AWS service-quotas API 有頻率限制但 lab 用量低，MVP 不 cache。
- 失敗的集群 `clusters/<name>/` 應何時清理？目前設計是 `okd-teardown` 會保留 `status.json`，要不要加 `--purge` 參數整目錄刪？傾向加但設為非預設。
