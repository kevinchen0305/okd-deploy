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
auto_fixable: no
---

## 症狀

Terraform 在 `provisioning_vpc` 階段卡住，log 出現：

```
Error: creating EC2 VPC: VpcLimitExceeded: The maximum number of VPCs has been reached.
```

或 `MaxNumberOfVpcsExceeded`、AWS API `LimitExceeded`。

## 原因

當前 region 的 VPC 配額（預設 5）已用滿。可能原因：

- 之前的 OKD 集群 teardown 不完整，殘留 VPC
- 同一 region 同時開太多測試集群
- 其他團隊也在用這個帳號

## 建議動作

1. 列出當前 region 所有 VPC，找出哪些是閒置的：

   ```bash
   aws ec2 describe-vpcs \
     --query 'Vpcs[?IsDefault==`false`].[VpcId,Tags[?Key==`Name`].Value|[0],CidrBlock]' \
     --output table
   ```

2. 比對本地 `clusters/*/status.json`，看哪些 VPC 沒對應 active 集群（即使 status.json 不存在但 VPC 還在 = 殘留）：

   ```bash
   ls /Users/cfh00901239/Desktop/okd-deploy/clusters/*/status.json
   ```

接著選一條路：

[a] **拆掉閒置集群**（推薦，最安全）：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<old_cluster_name>
../../scripts/teardown.sh
```

若 cluster 目錄已不存在但 VPC 殘留，跳到 `teardown-orphaned-resource` playbook。

[b] **申請配額提升**（要等 1–3 天）：

```bash
aws service-quotas request-service-quota-increase \
  --service-code vpc \
  --quota-code L-F678F1CE \
  --desired-value 10
```

[c] **換 region 重建**：編輯 `.env`，把 `AWS_REGION` 改成沒滿的 region（如 `us-east-2`），重跑 `scripts/build.sh`。注意 AMI ID 也要對應換掉，否則會打到 `ami-not-found`。

## 不會自動修復

刪 VPC 是破壞性動作（連帶刪 subnet/IGW/NAT），可能誤刪別人的環境。必須由人確認 VPC 歸屬後再執行 teardown。
