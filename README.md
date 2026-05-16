# okd-deploy

OKD 4.18 on AWS 部署自動化（Lab 用）— IaC + Claude Code Skills 驅動的可重複、可並行、可診斷工作流。

## 一次性設定

```bash
# 1. 安裝外部工具（自己安裝）
#    需要：terraform >=1.5、aws CLI、jq、yq、oathtool、envsubst
#    開發/測試用（選擇性）：shellcheck、bats

# 2. 下載 OKD 工具到 bin/<version>/
./scripts/install-tools.sh 4.18.0-okd-scos.10

# 3. 準備環境變數（建議放 .env，git ignore）
export BASE_DOMAIN="your-domain.example"
export AMI_ID="ami-07da7dc69c82f82a5"
export REGION="ap-northeast-1"
export AZ="ap-northeast-1c"
export VPC_CIDR="10.0.0.0/16"
export PULL_SECRET=$(cat ~/pull-secret.json)
export SSH_KEY=~/.ssh/id_rsa.pub

# Sizing — 沒有 default，必須明確設定（避免無意中跑大機型）
export MASTER_INSTANCE_TYPE="m5.2xlarge"   # lab 推薦；prod HA 用更大
export WORKER_INSTANCE_TYPE="m5.xlarge"    # lab 推薦；重 workload 用 m5.4xlarge
export MASTER_REPLICAS=1                   # lab=1, prod=3
export WORKER_REPLICAS=2

# 4. 設定 STS / MFA 機制（lab：以 oathtool 自動 TOTP）
echo "<base32-mfa-secret>" > ~/.okd-mfa-secret
chmod 600 ~/.okd-mfa-secret
./scripts/sts-creds.sh \
  --profile lab_kevin \
  --role-arn arn:aws:iam::404906229455:role/lab_kevin_access \
  --mfa-arn arn:aws:iam::404906229455:mfa/Kevin-MFA \
  --mfa-secret-file ~/.okd-mfa-secret \
  --out ~/.okd-creds.env
source ~/.okd-creds.env
```

## 日常使用（在 Claude Code 內）

```
/okd-build dev01                  # 建一個集群
/okd-build dev01 dev02 dev03      # 並行建三個
/okd-verify dev01                 # 驗證健康
/okd-diagnose dev01               # 失敗時找原因
/okd-teardown dev01               # 拆除集群
/okd-teardown dev01 --purge       # 拆完連目錄一起刪
/okd-preflight dev01              # 純預檢，不動 AWS
```

## 不開 Claude Code 也能跑

所有 skill 都是腳本的薄殼，可直接在 shell 跑：

```bash
./scripts/preflight.sh --clusters dev01 --version 4.18.0-okd-scos.10 --region ap-northeast-1
./scripts/ccoctl-setup.sh --cluster dev01 --region ap-northeast-1
./scripts/render-config.sh --cluster dev01
./scripts/install.sh --cluster dev01
./scripts/verify.sh --cluster dev01
./scripts/teardown.sh --cluster dev01
```

每個腳本都支援 `--dry-run` 印出將執行的指令而不實際呼叫 AWS。

## 目錄結構

```
.
├── .claude/{skills,commands}/    # Claude Code skills 與 slash commands
├── bin/<version>/                # OKD 工具按版本分（多版本共存）
├── modules/vpc/                  # Terraform VPC 模組
├── scripts/                      # 11 個 shell 腳本
├── templates/                    # install-config.yaml.tmpl
├── clusters/<name>/              # 每集群獨立目錄（terraform state、status、logs）
├── docs/playbooks/               # 失敗模式知識庫（給 diagnose 對照）
├── docs/superpowers/specs/       # 設計 spec（brainstorming 產出）
├── openspec/                     # OpenSpec 工作流產物
├── tests/bats/                   # 腳本單元測試
├── build-okd.md                  # 原手動流程（保留作 fallback / 參考）
└── README.md                     # 本檔
```

## 設計原則

1. **IaC 是骨幹，AI 是邊緣** — 標準化流程用 terraform + shell；AI 只做預檢、診斷
2. **Lab-only 配置** — 1 master + 2 worker、單 AZ；production 不適用
3. **每集群完全隔離** — 獨立 VPC、獨立 tfstate、獨立目錄，並行不衝突
4. **多 OKD 版本共存** — `bin/<version>/` 分目錄，集群版本鎖在 `clusters/<name>/version`
5. **失敗不修，建議重建** — diagnose 只給建議，由人決定 teardown / retry / 修

## 相關文件

- `docs/superpowers/specs/2026-05-09-okd-ai-agent-design.md` — 完整設計（brainstorming 產出）
- `openspec/changes/okd-ai-agent/` — OpenSpec change：proposal / design / specs / tasks
- `docs/playbooks/_index.md` — 已收錄的失敗模式列表
- `build-okd.md` — 原手動流程
