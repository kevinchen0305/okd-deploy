---
id: quota-exceeded-eip
applies_to_phase: [provisioning_vpc, installing]
signals:
  - source: terraform_log
    pattern: "AddressLimitExceeded"
  - source: aws_api_error
    code: "AddressLimitExceeded"
severity: blocker
auto_fixable: no
---

## 症狀

Terraform 在建 NAT Gateway / worker EIP 階段失敗：

```
Error: allocating EIP: AddressLimitExceeded: The maximum number of addresses has been reached.
```

## 原因

Region 的 Elastic IP 配額（預設 5）用滿。這份 repo 的 VPC 模組每 cluster 會預配:

- 1 NAT Gateway EIP
- `var.worker_replicas` 個 worker EIP（給 `scripts/attach-worker-eips.sh` 之後綁到 worker EC2）
- 加 bootstrap 階段 installer 自己會臨時拉 1 個 public IP（非 EIP，不算）

換算:`worker_replicas=2` → 每 cluster 3 EIP;並行 build 2 clusters = 6 EIP → 已超 default quota 5。

**preflight 已經會在 build 前擋住** — 此 playbook 主要為 quota 在 build 中途被外部消耗(別人也在用同 region)而留。

## 建議動作

1. 列出所有 EIP，找出沒掛載到任何 instance / NAT 的孤兒（最浪費配額）：

   ```bash
   aws ec2 describe-addresses \
     --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId,Tags[?Key==`Name`].Value|[0]]' \
     --output table
   ```

2. 比對所有 EIP 的歸屬：

   ```bash
   aws ec2 describe-addresses \
     --query 'Addresses[].[PublicIp,InstanceId,NetworkInterfaceId,Tags[?Key==`Name`].Value|[0]]' \
     --output table
   ```

接著選一條路：

[a] **釋放孤兒 EIP**（最快）：

```bash
aws ec2 release-address --allocation-id <eipalloc-xxx>
```

[b] **拆掉閒置集群連帶釋放 EIP**：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<old_cluster_name>
../../scripts/teardown.sh
```

[c] **申請配額提升**：

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --desired-value 10
```

## 不會自動修復

EIP 一旦 release 無法復原（IP 會回到 AWS 池）。必須由人確認該 IP 沒被外部 DNS / 防火牆白名單依賴。
