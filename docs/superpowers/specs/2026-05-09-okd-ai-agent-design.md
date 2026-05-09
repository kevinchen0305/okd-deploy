# OKD 4.18 AWS 部署 — AI Agent 介入設計

**日期**：2026-05-09
**狀態**：Draft，待 user 審核
**範圍**：把現有手動 OKD 4.18 on AWS 建置流程，改造成 IaC + Claude Code Skills 驅動的可重複、可並行、可診斷的工作流。

## 1. 背景與動機

### 現況
現有部署流程（`build-okd.md`）由七步組成：

1. AWS Console 手動建 VPC（含 1 public + 1 private subnet、NAT Gateway、S3 endpoint）
2. 下載 `openshift-install` / `ccoctl` / `oc` 4.18 工具
3. 用 STS assume-role + 手動填 MFA code 取得臨時憑證
4. 跑 `ccoctl` 建 IDP / IAM roles
5. 手動編輯 `install-config.yaml`（AMI、instance type、subnet、zone）
6. 手動 `vi` 改 machineset，把 private subnet 換成 public
7. `openshift-install create cluster`

### 痛點
- VPC 純手動，無法重現
- MFA code hardcode 在腳本
- `install-config.yaml` 與 machineset 都需手改，易錯
- Account ID 在腳本中可能不一致（`091798609788` vs `404906229455`）
- 無預檢、無驗證、無 teardown
- 沒有任何錯誤狀態下的恢復路徑

### 目標
讓 AI agent 介入流程，扮演三個角色：**預檢與驗證**、**全自動執行者**、**故障排除與診斷**。AI 不取代 IaC，而是補強 IaC 不擅長的判讀與決策。

### 非目標
- 集群升級流程（4.18 → 4.19）
- 監控 / 告警接入（Prometheus、Slack）
- 多 region / 多 account 切換
- 現有運行中集群的 day-2 operations
- AI 自動修復（playbook 預留欄位，MVP 不啟用）

## 2. 關鍵設計決策

| 決策點 | 選擇 | 理由 |
|---|---|---|
| 流程模型 | IaC 骨幹 + AI 邊緣決策 | 主流程可重現、低 token 成本；AI 只在難標準化的判讀步驟介入 |
| 執行環境 | Claude Code Skills + Slash Commands | 已在 Claude Code 內，skills 自動觸發、slash commands 顯式控制 |
| 集群生命週期 | Lab，常 build / 常 teardown | 重視 teardown 乾淨度與並行能力，而非長期穩定 |
| 修復強度 | 輕量：診斷 + 建議，人決定 | Lab 場景下「重建」通常比「修復」快且乾淨 |
| 架構 | Approach A — 5 個獨立 skill | 各 skill 可單獨呼叫，符合 Claude Code skill 設計慣例 |
| 多集群 | 支援 N 個並行 | per-cluster terraform state + 並行子 agent 派發 |
| VPC 模型 | Model 1 — 每集群一個 VPC | 完全隔離、teardown 簡單；犧牲共用 NAT 的成本節省 |
| 工具版本 | `bin/<version>/` 目錄分版本 | 不引入 Docker；多 OKD 版本共存 |

## 3. 系統架構

### 3.1 目錄結構

```
okd-deploy/
├── .claude/
│   ├── skills/
│   │   ├── okd-preflight/SKILL.md
│   │   ├── okd-build/SKILL.md
│   │   ├── okd-verify/SKILL.md
│   │   ├── okd-teardown/SKILL.md
│   │   └── okd-diagnose/SKILL.md
│   └── commands/
│       ├── okd-build.md       → /okd-build <name...> [--version X]
│       ├── okd-teardown.md    → /okd-teardown <name...>
│       ├── okd-verify.md      → /okd-verify <name>
│       └── okd-diagnose.md    → /okd-diagnose <name>
│
├── bin/
│   └── <version>/                  例：4.18.0-okd-scos.10/
│       ├── openshift-install
│       ├── ccoctl
│       └── oc
│
├── modules/vpc/                    共用 Terraform 模組
│   ├── main.tf                     VPC + 1 public + 1 private subnet + NAT + IGW + S3 endpoint
│   ├── variables.tf                cluster_name, region, az, cidr
│   └── outputs.tf                  vpc_id, public_subnet_id, private_subnet_id
│
├── scripts/
│   ├── sts-creds.sh               oathtool 自動 MFA → assume-role → export env
│   ├── ccoctl-setup.sh            包 5 步：create-key-pair → create-identity-provider
│   │                                  （含 private S3 bucket）→ extract CLOUDFRONT_ID →
│   │                                  oc adm release extract --credentials-requests →
│   │                                  ccoctl create-iam-roles
│   ├── render-config.sh           填 install-config.yaml.tmpl 的變數
│   ├── patch-machineset.sh        yq 把 private subnet 換成 public
│   ├── install.sh                 openshift-install create cluster + 寫 status
│   ├── verify.sh                  oc get co/nodes/ingress smoke + 寫 verify-report
│   └── teardown.sh                installer destroy → tf destroy → 清 S3/IAM/IDP
│
├── templates/
│   └── install-config.yaml.tmpl
│
├── clusters/<cluster_name>/        每集群一份完全隔離狀態
│   ├── version                    例：4.18.0-okd-scos.10
│   ├── terraform/                 含 main.tf（引用 modules/vpc）+ tfvars + tfstate
│   ├── install-config.yaml
│   ├── manifests/
│   ├── auth/                      kubeconfig、kubeadmin-password
│   ├── .openshift_install.log
│   ├── status.json
│   └── verify-report.json
│
└── docs/
    ├── superpowers/specs/         本 spec 所在
    └── playbooks/                 失敗模式知識庫（diagnose 對照）
        ├── _index.md
        ├── _unknown.md            未匹配條目記錄區
        ├── quota-exceeded-vpc.md
        ├── quota-exceeded-eip.md
        ├── quota-exceeded-ec2.md
        ├── sts-expired.md
        ├── sts-mfa-failed.md
        ├── ami-not-found.md
        ├── bootstrap-stuck.md
        ├── ingress-degraded.md
        ├── route53-resolution-failed.md
        ├── ccoctl-s3-conflict.md
        ├── machineset-no-subnet.md
        └── teardown-orphaned-resource.md
```

### 3.2 五個 Skill 的職責邊界

| Skill | 觸發方式 | 主要動作 | 不做什麼 |
|---|---|---|---|
| `okd-preflight` | 由 build/teardown 內部呼叫；可獨立 invoke | quota 聚合檢查、STS 有效性、AMI 存在性、tool 版本、目錄衝突 | 僅 read-only AWS API；不修改 AWS 狀態、不寫集群目錄 |
| `okd-build` | `/okd-build <name...>`（顯式） | 派發 parallel agents，每個 agent 跑 terraform → ccoctl → installer → verify | 不取代 preflight；不修錯（轉 diagnose） |
| `okd-verify` | `/okd-verify <name>` 或裝完自動 | 跑 oc smoke check，寫 verify-report | 不修錯 |
| `okd-teardown` | `/okd-teardown <name...>`（顯式） | installer destroy → tf destroy → 清 S3 bucket / IAM role / IDP / OIDC provider | 不問人；過 phase=ready 才能避開 installer destroy |
| `okd-diagnose` | `/okd-diagnose <name>` 或其他 skill 出錯時自動 | 讀 status + log，比對 playbook，輸出建議 | 不動手；連結到 playbook 列出選項 |

## 4. 資料流：`/okd-build dev01 dev02` 完整生命週期

```
1. User    /okd-build dev01 dev02 --version 4.18.0-okd-scos.10
              │
2. Slash    解析參數，呼叫 okd-build skill
              │
3. okd-build  共用 preflight：
              • bin/4.18.0-okd-scos.10/ 工具齊全
              • AWS quota 是否夠 N 集群（VPC×2、EIP×2、EC2×2×4、NAT×2）
              • STS 憑證有效性與剩餘時間
              • AMI ID 在 region 存在
              • 衝突：clusters/dev01 / clusters/dev02 不存在
              │ pass
              │
              派 parallel agents（superpowers/dispatching-parallel-agents）
              │
       ┌──────┴──────┐
       ▼             ▼
  Agent[dev01]  Agent[dev02]    各自序列跑：
       │             │            ① terraform apply        → status: provisioning_vpc
       │             │            ② sts-creds.sh           → status: getting_creds
       │             │            ③ ccoctl-setup.sh        → status: setting_up_iam
       │             │            ④ render-config.sh       → status: rendering_config
       │             │            ⑤ patch-machineset.sh    → status: patching_manifests
       │             │            ⑥ install.sh             → status: installing (~30-45 min)
       │             │            ⑦ verify.sh              → status: verifying
       │             │                                       → status: ready
       └──────┬──────┘
              ▼
     聚合 status.json，主對話回報：
       ✓ dev01 ready → kubeconfig: clusters/dev01/auth/kubeconfig
       ✓ dev02 ready → kubeconfig: clusters/dev02/auth/kubeconfig
```

### 4.1 `clusters/<name>/status.json` 結構

```json
{
  "cluster_name": "dev01",
  "okd_version": "4.18.0-okd-scos.10",
  "region": "ap-northeast-1",
  "az": "ap-northeast-1c",
  "phase": "ready",
  "phase_history": [
    {"phase": "provisioning_vpc", "at": "2026-05-09T10:00:00Z", "ok": true},
    {"phase": "installing",       "at": "2026-05-09T10:05:00Z", "ok": true},
    {"phase": "ready",            "at": "2026-05-09T10:42:00Z", "ok": true}
  ],
  "vpc_id": "vpc-xxx",
  "subnet_ids": {"public": "subnet-aaa", "private": "subnet-bbb"},
  "console_url": "https://console-openshift-console.apps.dev01.example",
  "verify_summary": {"nodes": "ok", "operators": "ok", "ingress": "ok"},
  "last_error": null
}
```

**寫者**：每個腳本完成自己步驟時用 `jq` 更新對應欄位。
**讀者**：`okd-verify` / `okd-diagnose` / `okd-teardown` 都先讀 status.json 決定下一步。

### 4.2 Phase 列舉（嚴格定義）

建立 `clusters/<name>/` 時 phase 寫入 `pending`；preflight pass 後第一個 agent 動作時轉 `provisioning_vpc`：

`pending` → `provisioning_vpc` → `getting_creds` → `setting_up_iam` → `rendering_config` → `patching_manifests` → `installing` → `verifying` → `ready`

任何步驟失敗 → phase 停在當下值，`last_error` 寫入摘要。teardown 啟動 → phase 改為 `tearing_down` → 完成後 → `destroyed`（保留 status.json 一段時間，方便事後查；可加 `--purge` 真正刪目錄）。

### 4.3 Preflight Quota 聚合

```
preflight 執行時：
  needed = {
    "vpc": N,
    "eip": N,
    "nat_gateway": N,
    "ec2_m5_4xlarge": 2*N,   # worker
    "ec2_m5_2xlarge": 1*N,   # master
    "ec2_m5_large":  1*N,    # bootstrap (estimate)
  }
  for resource, count in needed.items():
    quota = aws service-quotas get-service-quota ...
    used  = aws describe ... | wc -l
    available = quota - used
    if count > available:
      collect_failure(resource, count, available, quota)

  if any failure:
    print 報告 + 三選一建議（teardown / 申請 quota / 降併發）
    exit 1
```

## 5. 錯誤處理與 Diagnose 流程

### 5.1 Playbook 格式（`docs/playbooks/<id>.md`）

每個 playbook 是 markdown，前段 YAML frontmatter 給 AI 做模式比對，後段給人看。

```markdown
---
id: quota-exceeded-vpc
applies_to_phase: [provisioning_vpc]
signals:
  - source: terraform_log
    pattern: "VpcLimitExceeded"
  - source: terraform_log
    pattern: "MaxNumberOfVpcsExceeded"
  - source: aws_api_error
    code: "LimitExceeded"
severity: blocker
auto_fixable: false
---

## 症狀
Terraform apply 在建 VPC 時失敗，AWS 回 quota 超限。

## 原因
AWS 帳號 region 內 VPC 數量達上限（default 5）。

## 建議動作
1. 列出當前 VPC：`aws ec2 describe-vpcs --query 'Vpcs[].VpcId'`
2. 對照 `clusters/*/status.json` 的 vpc_id 找閒置的
3. 三選一：
   - `/okd-teardown <閒置集群>` 釋放
   - 申請 quota 增加（1-2 工作天）
   - 換 region：`--region ap-northeast-3`

## 不會自動修復
增加 quota 需 AWS support ticket，AI 不能代為操作。
```

### 5.2 `okd-diagnose` 決策流

```
/okd-diagnose dev01
   │
   ▼
1. 讀 clusters/dev01/status.json
   → phase（如 "installing"）、last_error
   │
   ▼
2. 收集診斷材料（依 phase）：
   • clusters/dev01/.openshift_install.log（tail 200 行）
   • clusters/dev01/terraform/terraform.log
   • aws ec2 describe-instances --filter tag:cluster=dev01
   • oc get co / oc get nodes（若 kubeconfig 已存在）
   │
   ▼
3. 比對 docs/playbooks/_index.md，挑 applies_to_phase 含當前 phase 的，
   依序檢查 signals（regex / API code）
   │
   ▼
4a. 命中 → 印出 playbook 的「症狀 + 原因 + 建議動作」，列選項
4b. 未命中 → Claude 直接讀 log 摘要，列 3 個值得查的方向，
              並寫一筆到 _unknown.md（給未來升格）
```

### 5.3 呈現格式（呼應「輕量：診斷 + 建議人決定」）

```
✗ dev01 卡在 installing 階段（已 12 分鐘無進展）

匹配 playbook: bootstrap-stuck

症狀：
  bootstrap EC2 instance 已 Running，但 cluster API 連不上

可能原因（按可能性排序）：
  1. SG 沒開 6443 → master（最常見）
  2. Route53 private hosted zone 沒建好
  3. ignition 檔抓不到（S3 access denied）

建議：
  [a] 看 bootstrap console log: aws ec2 get-console-output --instance-id i-xxx
  [b] 對 master 開 SG: ./scripts/diag/check-sg.sh dev01
  [c] 放棄重建: /okd-teardown dev01 && /okd-build dev01

要我幫你跑哪個？(a/b/c/skip)
```

只到「建議＋給選項」，不擅自動手。

### 5.4 跨 skill 觸發 diagnose

- `okd-build` 任何 phase 失敗 → 自動 invoke diagnose
- `okd-verify` 偵測到 ClusterOperator degraded → 自動 invoke diagnose
- `okd-teardown` `terraform destroy` 失敗（常見：殘留 ENI/SG）→ 自動 invoke diagnose

### 5.5 `_unknown.md` 與 playbook 成長

每個 `_unknown.md` 條目代表一個沒人寫過 playbook 的失敗模式。日後可手動把它整理成正式 `playbooks/<id>.md`。錯誤知識庫會隨使用次數成長。

## 6. 驗證策略

### 6.1 Cluster 層 — `okd-verify` smoke check

```
oc --kubeconfig=clusters/<name>/auth/kubeconfig 一系列檢查：

Nodes
  • get nodes → 全部 Ready，數量 = 1 master + 2 worker
  • node condition 沒有 Pressure

ClusterOperators
  • get co → 全部 Available=True, Progressing=False, Degraded=False

Core workloads
  • -n openshift-ingress 的 router pods Running
  • -n openshift-image-registry Running
  • -n openshift-authentication oauth Running

Networking
  • console route 解得到 IP
  • curl -k https://console-... 回 200/302
  • API endpoint 回 healthz

Smoke workload（選用）
  • oc new-project verify-$(date +%s)
  • oc run nginx --image=nginx，等 Ready，curl 通，刪 namespace
```

每項通過/失敗寫入 `clusters/<name>/verify-report.json`，更新 `status.json` 的 `verify_summary`。

### 6.2 IaC 與腳本層

**Terraform**：`terraform validate` + `terraform plan` 對照 expected resource count。不引入 terratest。

**Shell scripts**：
- `shellcheck scripts/*.sh`
- 每個 script 接受 `--dry-run`
- `bats` 為關鍵函式（`render-config.sh`、`patch-machineset.sh`）寫 ~10 個 unit test

**Skill 層**：不寫自動化測試（markdown 行為由 LLM 決定）。改用「演練清單」：每次大改 skill 後手動跑一輪 `/okd-build → /okd-verify → /okd-teardown`。

### 6.3 MVP 驗收標準

設計能不能落地，看下面這條 path 通不通：

- [ ] `/okd-build dev01` 一條龍跑完 → `phase=ready`，全程不需人介入
- [ ] `/okd-verify dev01` 全綠
- [ ] `/okd-teardown dev01` 完整清乾淨：AWS Console 看不到任何含 `dev01` tag 的 EC2、VPC、Subnet、IGW、NAT、EIP、SG、IAM role、S3 bucket、Route53 zone
- [ ] `/okd-build dev01 dev02` 並行成功，證明 per-cluster 隔離有效
- [ ] 故意把 `install-config` 的 AMI 改錯，跑 `/okd-build dev01` → preflight 在 terraform 之前攔下，匹配 `ami-not-found` playbook
- [ ] 故意把 quota 設成 0（用 stub），跑 `/okd-build dev01..dev05` → preflight 匹配 `quota-exceeded-vpc` 並建議降併發

通過這 6 條 → 設計成立、可開始用。

## 7. 開放問題與未來工作

| 主題 | 何時處理 |
|---|---|
| 集群升級 4.18 → 4.19 | 另立 spec |
| 監控 / 告警接入 | 另立 spec |
| 多 region / 多 account | 另立 spec |
| Day-2 operations（加 worker、改 storage class） | 另立 spec |
| AI 自動修復（啟用 playbook 的 `auto_fixable`） | MVP 後依信心決定 |
| Containerfile（CI / 跨機器一致性） | 有需要時補 |
| 跨集群錯誤知識共享 | 等 `_unknown.md` 累積到一定量再考慮 |

## 8. 已知風險

| 風險 | 影響 | 緩解 |
|---|---|---|
| AWS quota 預設僅支援約 4 個並行 VPC | 多人並用時撞牆 | preflight 提前報、給降併發建議；長期申請 quota |
| OKD 工具版本與集群版本綁死 | 拿錯版本工具動老集群可能弄壞 | `clusters/<name>/version` + 腳本嚴格依該檔挑 `bin/<version>/` |
| STS 憑證 12 小時過期 | 長 build 中途斷 | install 前重新跑 sts-creds；過期錯誤匹配 `sts-expired` playbook |
| `_unknown.md` 不被人定期整理 | 知識庫不成長 | 每月 review；或寫 skill 自動 summarise |
| Account ID hardcode 不一致風險 | ccoctl IAM role 對不上 | preflight 把 STS 解出的 account ID 與 install-config 內所有 ARN 比對 |
| Single AZ + 1 master 的脆弱性 | 一台 master 掛 = 集群掛 | Lab 場景接受；spec 文件明示為 lab-only 配置 |
