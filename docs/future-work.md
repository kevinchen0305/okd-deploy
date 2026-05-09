# Future Work

未來可能展開為新 OpenSpec change 的構想清單。每項提案標註預估效益、影響範圍與已知未解。

## 成本基準（單集群、每月、預設 m5.2xlarge + 2× m5.4xlarge）

| 項目 | 月成本 |
|---|---:|
| 1× master m5.2xlarge | ~$280 |
| 2× worker m5.4xlarge | ~$1,121 |
| NAT Gateway | ~$33 + 流量 |
| EBS（4 × 120 GB gp3） | ~$38 |
| 其他（EIP、S3、Route53） | <$5 |
| **合計** | **~$1,500** |

Lab FinOps 的目標：把每月帳單壓到 $200 以下（真用幾天 × 真用的時數）。

---

## 🟢 Quick Wins（建議優先）

### FW-1：Pre-build 成本估算
在 `okd-preflight` 加成本估算：呼叫 AWS Pricing API 或 hardcode 表，算 `instance_type × replicas × hours × price`，preflight 報告印每小時／每天／每月成本，並要求確認。撞 quota 時順便建議「換 m5.large 省 80%」。
- **效益**：把成本意識內建到流程
- **影響**：preflight skill + scripts/preflight.sh + 新增 pricing 資料

### FW-2：自動 teardown
寫 `scripts/auto-teardown.sh` 接 cron / EventBridge，預設「找 phase=ready 但最後 oc 活動 > 4h 的集群 → teardown」。或 build 時帶 `--ttl 8h`，背景 at job 到期執行 teardown。
- **效益**：解決最常見浪費（忘了拆）
- **影響**：新 skill + scripts + 可能加 lambda
- **未解**：判斷「有沒有在用」的標準（API 呼叫、CPU 使用率？）

### FW-3：status.json 加 cost tracking + `/okd-cost`
`status.json` 多兩欄 `estimated_hourly_cost` 與 `running_since`。新 skill `/okd-cost` 列所有 active 集群與啟動到現在的累積花費。
- **效益**：fleet-wide 一眼看
- **影響**：_lib.sh 加欄位、新 skill

### FW-4：AWS Budgets 警報
一支 `terraform/budgets/` 模組，建每集群 / 每月 budget alert：日帳超過 $50 或月帳超過 $300 寄信。
- **效益**：兜底防呆
- **影響**：新 terraform 模組、build skill 改一下

---

## 🟡 Medium

### FW-5：Spot worker MachineSet
worker 改用 spot 省 70%。改 machineset：`spec.template.spec.providerSpec.value.spotMarketOptions: {}`。Master 不能用 spot。
- **效益**：每集群月省 ~$780
- **影響**：patch-machineset.sh 多一個 patch
- **未解**：spot 被收回時的容忍策略

### FW-6：Lab profile（換 instance type）
新增 `--profile lab|dev|prod`：
- `lab`：1× m5.large + 1× m5.xlarge（compact-ish）
- `dev`：當前預設
- `prod`：3 master + 3 worker HA

| 角色 | 預設 | lab profile |
|---|---|---|
| Master | m5.2xlarge ($280/m) | m5.large ($70/m) |
| Worker | m5.4xlarge × 2 ($1,121/m) | m5.xlarge × 2 ($280/m) |

- **效益**：lab profile 月省 ~$1,050
- **影響**：render-config.sh + 新增 profile 表

### FW-7：NAT 替代方案
- **方案 A**：NAT Gateway → NAT Instance（t3.nano + iptables）。$33/m → $4/m，每集群省 $29
- **方案 B**：worker 改放 public subnet（本來 build-okd.md 就是這做），完全省掉 NAT
- **影響**：modules/vpc/main.tf
- **未解**：方案 A 的單點失效在 lab 是否可接受（應該可以）

### FW-8：Single-node OKD（compact cluster）
`controlPlane.replicas: 1`、`compute.replicas: 0`。control plane 兼跑 workload。
- **效益**：~$1,500/m → ~$300/m
- **影響**：render-config.sh 新增 single-node 模式
- **未解**：OKD 4.18 single-node 的限制（某些 operator 不支援）

---

## 🔴 Strategic

### FW-9：重新評估 VPC 模型 → Model 2（共用 VPC）
若常駐 ≥3 集群，Model 1（每集群獨立 VPC）比 Model 2（共用 VPC）每年多花 $400/cluster。
- **觸發條件**：穩定有 3+ 集群並存
- **影響**：全套 terraform 重構、teardown 邏輯改動

### FW-10：OpenCost 安裝為標配
verify.sh 結束時自動裝 OpenCost（CNCF sandbox，免費）。集群內看 namespace / pod 級成本。
- **效益**：知道「OKD 上 lab 跑什麼最貴」
- **影響**：verify.sh 加 helm install 步驟

### FW-11：Tag-based Cost Dashboard
build 已打 tag `owner / purpose / cluster`。用 AWS Cost Explorer + tag filter 做每日 dashboard：每集群一條線。
- **效益**：一眼看到誰忘了 teardown
- **影響**：terraform 建 Cost Anomaly Detection + dashboard、或寫 lambda 推 Slack

### FW-12：Idle detector + 自動回收
Lambda 每小時對所有 active 集群跑 `oc top nodes`，CPU <5% 持續 6h 寄信問拆，三次沒回自動 teardown。
- **效益**：徹底解決遺忘
- **影響**：新 lambda + 對 build skill 加 metadata
- **未解**：誤殺風險（人在思考、集群空閒中）

---

## 推薦的下一輪 OpenSpec change

把 **FW-1（成本估算）+ FW-2（自動 teardown）+ FW-5（Spot workers）+ FW-11（Cost dashboard）** 包成一個 change `okd-finops`，重跑 brainstorm → propose → apply。優先理由：
- FW-2 一週回本
- FW-5 立即省 70%
- FW-1 + FW-11 給 visibility，後續決策才有依據
