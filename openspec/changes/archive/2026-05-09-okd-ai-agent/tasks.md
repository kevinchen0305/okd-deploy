## 1. 基礎設施與工具

- [x] 1.1 建立 `bin/` 目錄；寫 `scripts/install-tools.sh`，接受 version 參數，下載 openshift-install / ccoctl / oc 到 `bin/<version>/`
- [ ] 1.2 跑 `scripts/install-tools.sh 4.18.0-okd-scos.10` 把預設版本工具下載完成並驗證可執行 _(deferred — user runs; ~200MB download)_
- [x] 1.3 建立 `templates/install-config.yaml.tmpl`，把 build-okd.md 中 hardcode 的值改為 `${VAR}` 變數（cluster_name、region、az、ami_id、subnet_public、subnet_private、worker_replicas、master_replicas、user_tags 等）
- [x] 1.4 建立 `docs/playbooks/_index.md` 與 `docs/playbooks/_unknown.md` 空殼

## 2. Terraform VPC 模組

- [x] 2.1 建立 `modules/vpc/variables.tf`：cluster_name、region、az、cidr（預設 10.0.0.0/16）、tags
- [x] 2.2 建立 `modules/vpc/main.tf`：VPC + 1 public subnet + 1 private subnet + IGW + NAT Gateway（in 1 AZ）+ S3 Gateway endpoint + route tables + 在 public subnet 開啟 auto-assign public IPv4
- [x] 2.3 建立 `modules/vpc/outputs.tf`：vpc_id、public_subnet_id、private_subnet_id、nat_gateway_id
- [x] 2.4 寫 `terraform validate` 與 `terraform plan` 對照 expected resource count 的檢查腳本

## 3. Shell 腳本層

- [x] 3.1 `scripts/_lib.sh`：共用函式（`update_phase`、`set_last_error`、`get_cluster_version`、`tools_dir`、`fail_with_diagnose`），其他腳本共用
- [x] 3.2 `scripts/sts-creds.sh`：用 oathtool 算 MFA → assume-role → 寫 env 檔；接受 `--profile`、`--mfa-secret-file`、`--duration`
- [x] 3.3 `scripts/ccoctl-setup.sh`：包 5 步（create-key-pair → create-identity-provider 含 S3 → 抓 CLOUDFRONT_ID → oc adm release extract --credentials-requests → ccoctl create-iam-roles），接受 `--cluster <name>`
- [x] 3.4 `scripts/render-config.sh`：用 envsubst 把 `templates/install-config.yaml.tmpl` 渲染到 `clusters/<name>/install-config.yaml`
- [x] 3.5 `scripts/patch-machineset.sh`：用 yq 把 `clusters/<name>/openshift/99_openshift-cluster-api_worker-machineset-0.yaml` 內 private subnet 換成 public subnet
- [x] 3.6 `scripts/install.sh`：把 cco_manifests 與 credrequests 拷貝到 manifests，跑 `openshift-install --dir create cluster`，過程中持續更新 status.json phase
- [x] 3.7 `scripts/verify.sh`：用 `oc --kubeconfig=clusters/<name>/auth/kubeconfig` 跑 nodes / co / core workloads / networking / smoke workload 五組檢查，輸出 `clusters/<name>/verify-report.json` 並更新 status.json
- [x] 3.8 `scripts/teardown.sh`：依當前 phase 決定要拆什麼層；先 `openshift-install destroy cluster`、再 `terraform destroy`、再清 ccoctl 建的 S3 / IAM / OIDC provider；接受 `--purge` 整目錄刪
- [x] 3.9 為每個 script 加 `--dry-run` 旗標：印出會執行的指令但不真的呼叫 aws / openshift-install
- [x] 3.10 跑 `shellcheck scripts/*.sh` 修掉所有 warning
- [x] 3.11 寫 `bats` 單元測試覆蓋 `render-config.sh` 模板填值與 `patch-machineset.sh` 的 yq 改動（~10 個測試）

## 4. Preflight Skill 與檢查

- [x] 4.1 `scripts/preflight.sh`：聚合所有 preflight 檢查，接受 `--clusters <name1,name2,...>` 與 `--version <v>`
- [x] 4.2 在 preflight.sh 內實作 quota 聚合：呼叫 `aws service-quotas get-service-quota` 與相應 describe API 算 (request, available, quota)
- [x] 4.3 實作 STS 有效性檢查（`aws sts get-caller-identity` + 解析剩餘有效期）
- [x] 4.4 實作 AMI 存在性檢查（`aws ec2 describe-images --image-ids` + region 過濾）
- [x] 4.5 實作工具版本存在性檢查（`bin/<version>/{openshift-install,ccoctl,oc}` 是否可執行）
- [x] 4.6 實作集群名稱衝突檢查（`clusters/<name>/` 是否存在）
- [x] 4.7 實作 Account ID 一致性檢查（STS 解出的 account ID 對照 install-config / IAM role ARN）
- [x] 4.8 確保 preflight 不寫任何檔到 `clusters/<name>/`、不變更 AWS 狀態
- [x] 4.9 建立 `.claude/skills/okd-preflight/SKILL.md`：description 觸發條件、呼叫 `scripts/preflight.sh`、解讀回傳結果並建議

## 5. Build Skill 與並行派發

- [x] 5.1 `.claude/commands/okd-build.md`：解析 `<name1> <name2>... [--version X]` 參數，呼叫 okd-build skill
- [x] 5.2 `.claude/skills/okd-build/SKILL.md`：先呼叫 preflight 一次（聚合 N 集群），通過後派發子 agent
- [x] 5.3 在 build skill 內整合 superpowers/dispatching-parallel-agents：每集群一個子 agent，依序跑 terraform → sts → ccoctl → render → patch → install → verify
- [x] 5.4 子 agent 完成後寫 status.json；主 agent 聚合報告：列每集群的最終 phase、kubeconfig 路徑、console_url
- [x] 5.5 任一子 agent 失敗時，自動 invoke `okd-diagnose` 並把建議放進主對話的回報

## 6. Verify / Teardown Skills

- [x] 6.1 `.claude/commands/okd-verify.md` + `.claude/skills/okd-verify/SKILL.md`：呼叫 `scripts/verify.sh`，degraded 自動 invoke diagnose
- [x] 6.2 `.claude/commands/okd-teardown.md` + `.claude/skills/okd-teardown/SKILL.md`：呼叫 `scripts/teardown.sh`，失敗自動 invoke diagnose；多參數時並行派發
- [x] 6.3 在 teardown skill 加 `--purge` 旗標，明示是否刪集群目錄

## 7. Diagnose Skill 與 Playbooks

- [x] 7.1 `.claude/commands/okd-diagnose.md` + `.claude/skills/okd-diagnose/SKILL.md`：讀 status + log，比對 playbooks，輸出建議
- [x] 7.2 在 diagnose skill 內實作 phase-aware 材料收集（依 phase 決定讀什麼 log / 跑什麼 aws describe）
- [x] 7.3 實作 playbook 比對演算法：載入 `docs/playbooks/_index.md`、依 `applies_to_phase` 過濾、依序檢查 `signals` 的 regex / API code
- [x] 7.4 未命中時 fallback 到 LLM 自由摘要 + 寫入 `_unknown.md`（含去重指紋）
- [x] 7.5 建立 12 個初始 playbook：`quota-exceeded-vpc`、`quota-exceeded-eip`、`quota-exceeded-ec2`、`sts-expired`、`sts-mfa-failed`、`ami-not-found`、`bootstrap-stuck`、`ingress-degraded`、`route53-resolution-failed`、`ccoctl-s3-conflict`、`machineset-no-subnet`、`teardown-orphaned-resource`，每個含完整 frontmatter + 症狀 / 原因 / 建議
- [x] 7.6 更新 `docs/playbooks/_index.md` 列出全部 playbook 與 `applies_to_phase`

## 8. 集群目錄與狀態管理

- [x] 8.1 在 build skill 內定義 status.json 初始 schema（cluster_name、okd_version、region、az、phase=pending、phase_history=[]、vpc_id=null、subnet_ids={}、console_url=null、verify_summary={}、last_error=null）
- [x] 8.2 確保所有腳本透過 `_lib.sh` 的 `update_phase` 函式更新 status.json，phase 遵守嚴格列舉
- [x] 8.3 在 cluster 目錄建立時寫入 `clusters/<name>/version`，後續所有腳本透過 `get_cluster_version` 讀取

## 9. MVP 驗收測試

- [ ] 9.1 跑 `/okd-build dev01` 一條龍跑完，phase 抵達 ready _(deferred — needs real AWS, user runs)_
- [ ] 9.2 跑 `/okd-verify dev01` 全綠 _(deferred — depends on 9.1)_
- [ ] 9.3 跑 `/okd-teardown dev01`，AWS Console 無殘留 dev01 tag 資源 _(deferred — depends on 9.1)_
- [ ] 9.4 跑 `/okd-build dev01 dev02` 並行成功 _(deferred — needs real AWS)_
- [ ] 9.5 故意把 install-config 的 AMI 改錯，跑 `/okd-build dev01`，preflight 在 terraform 之前攔下並命中 `ami-not-found` playbook _(deferred — needs real AWS)_
- [ ] 9.6 故意把 quota 設成 0 stub，跑 `/okd-build dev01..dev05`，preflight 命中 `quota-exceeded-vpc` 並建議降併發 _(deferred — needs real AWS)_

## 10. 文件與收尾

- [x] 10.1 在 `okd-deploy/README.md` 寫快速上手：先 `scripts/install-tools.sh`，再 `/okd-build <name>`
- [x] 10.2 在 `build-okd.md` 開頭加註：「現已被 OpenSpec change `okd-ai-agent` 取代為 IaC + skills 流程；本檔保留為手動 fallback 與歷史參考」
- [x] 10.3 確認所有新增檔案沒有寫死 account ID / region / AMI；皆從 tfvars / template 變數取
