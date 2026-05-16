---
name: okd-diagnose
description: Use when an OKD operation fails, when a cluster is degraded, or when user runs /okd-diagnose. Reads cluster status + logs, matches against playbooks, presents structured suggestions
---

# okd-diagnose

當 OKD 操作失敗、集群 degraded、或使用者主動呼叫 `/okd-diagnose <name>` 時觸發。讀取 status + 對應 phase 的日誌，比對 `docs/playbooks/`，輸出**結構化建議**。**絕不自動修復**。

## 何時使用

- 使用者執行 `/okd-diagnose <name>`。
- 由 `okd-build` / `okd-verify` / `okd-teardown` 在失敗時自動 invoke。
- 由 `okd-preflight` 在某些失敗檢查（quota、sts、ami、account-id）命中對應 playbook 時 invoke。

## 參數

- 位置參數：一個 cluster 名稱。

## 整體流程

### 第 1 步：讀集群狀態

```bash
jq . clusters/<name>/status.json
```

抓出：
- `phase`（如 `installing`、`verifying`、`tearing_down`...）
- `last_error`（若有）
- `verify_summary`（若 phase 已過 `verifying`）

**Early exit — 「沒問題可診斷」**：若 `phase=ready` 且 `last_error=null` 且 `verify_summary.all_passed=true`，直接回覆：

```
Cluster <name> 健康。phase=ready, verify_summary 全綠, last_error=null。
無需 diagnose。如懷疑特定問題，重跑 /okd-verify <name> 取得最新狀態。
```

不進後續步驟、不寫 `_unknown.md`、不呼叫 playbook 比對。

### 第 2 步：依 phase 收集診斷材料

只收當下 phase 相關的東西，避免無謂讀取：

| phase | 收集內容 |
|---|---|
| `pending` | `clusters/<name>/status.json` 本身；通常代表 init 後就沒前進，看 last_error |
| `provisioning_vpc` | `clusters/<name>/terraform/terraform.log`（或 stderr 紀錄） |
| `getting_creds` / `setting_up_iam` | `scripts/ccoctl-setup.sh` 的 stdout/stderr 紀錄 |
| `rendering_config` | `scripts/render-config.sh` 輸出；檢查模板變數是否齊 |
| `patching_manifests` | `scripts/patch-machineset.sh` 輸出 |
| `installing` | `clusters/<name>/.openshift_install.log` 最後 200 行；`aws ec2 describe-instances --filters "Name=tag:cluster,Values=<name>"` |
| `verifying` | `oc get co -o yaml`、`oc get nodes -o yaml`、`clusters/<name>/verify-report.json` |
| `ready` | (Early exit 已處理；若使用者強制要再診斷，視同 `verifying` 收集 oc 狀態) |
| `tearing_down` | `clusters/<name>/terraform/terraform.log`；`openshift-install destroy` 紀錄；額外掃 `aws ec2 describe-network-interfaces / describe-vpc-endpoints / describe-security-groups` 找 GuardDuty / orphan ENI |
| `destroyed` | (健康狀態；若使用者跑 diagnose 多半是想確認真的清乾淨) — 掃 `aws ec2 describe-vpcs --filters Name=tag:Name,Values=<name>-vpc` 等驗證殘留 |

`oc` / `openshift-install` 一律走 `bin/<version>/`，version 取自 `clusters/<name>/version`。

### 第 3 步：載入 playbook 索引

```bash
cat docs/playbooks/_index.md
```

把所有 playbook 先按 `applies_to_phase` 過濾，只留與當前 phase 相關的候選集合。

### 第 4 步：對候選 playbook 做 signal 比對

每個 playbook 的 YAML frontmatter 內含 `signals`，每個 signal 形如：

```yaml
signals:
  - source: terraform_log         # terraform_log | installer_log | aws_api_error | oc_output
    pattern: "VpcLimitExceeded"   # regex
  - source: aws_api_error
    code: "VcpuLimitExceeded"
```

對收集到的材料逐個 signal 比對。**全部 signal 命中**才算該 playbook 命中（AND 邏輯）。

### 第 5 步：輸出

#### 命中 playbook → 結構化建議

讀該 playbook 內文，按以下格式渲染：

```
[playbook: quota-exceeded-vpc]
症狀：
  Terraform 在 aws_vpc 建立階段失敗，回傳 VpcLimitExceeded。
原因：
  Region ap-northeast-1 的 VPC 數已達 quota 上限（預設 5）。
建議動作：
  a) Teardown 一個閒置集群（建議 dev99）：執行 /okd-teardown dev99
  b) 對 AWS 申請提高 VPC quota：開 case，預估 1–2 工作天
  c) 降低本次併發數，分兩批 build

請輸入 a / b / c / skip。
```

**等待使用者選擇**，不自動執行。

#### 多個 playbook 命中

依 `severity`（critical > high > medium > low）排序全列；同 severity 比 signals 命中數，再多者優先。

#### 未命中任何 playbook → LLM 推測

1. 讀 log 摘要，列**最多 3** 個值得查的方向。
2. 計算 fingerprint = `<phase>:sha1(log_first_line)` 前 12 字元。
3. 檢查 `docs/playbooks/_unknown.md` 是否已有相同 fingerprint。
   - 已存在 → 不重複 append。
   - 不存在 → append 一筆：

     ```
     ### <date> · <cluster> · phase=<phase> · fp=<fingerprint>
     log_excerpt: |
       <最後 30 行 log，去敏感資料>
     llm_hypothesis:
       - <推測 1>
       - <推測 2>
       - <推測 3>
     ```
4. 在輸出**最開頭**明示：

   > **此為 LLM 推測，非已知 playbook。** 已記錄到 `docs/playbooks/_unknown.md` 供日後升格。

## 重要約束

- **絕不自動修復**：不跑任何 AWS 變更、不重跑 sts-creds、不改 manifests。即使建議 a) 寫得很明確也只是「建議」。
- **不汙染集群目錄**：只讀檔，不寫 status.json（status.json 由執行型 skill 推進）。
- **playbook 命中是 AND 邏輯**：所有 signals 都要對上，避免誤命中。
- **未命中也要給東西**：使用者跑 diagnose 是因為有問題，要提供 LLM 推測 + 紀錄到 `_unknown.md`。
- **Phase-aware**：絕不在 phase=`installing` 時去讀 `auth/kubeconfig`（還沒生成）。

## 範例

```
/okd-diagnose dev01
```

讀到 `clusters/dev01/status.json` 顯示 `phase=installing`、`last_error="bootstrap timeout"`，讀 `.openshift_install.log` 最後 200 行命中 `bootstrap-stuck` playbook → 輸出該 playbook 的症狀／原因／建議 a/b/c，等待使用者輸入。
