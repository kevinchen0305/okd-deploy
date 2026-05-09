---
id: quota-exceeded-eip
applies_to_phase: [provisioning_vpc]
signals:
  - source: terraform_log
    pattern: "AddressLimitExceeded"
  - source: aws_api_error
    code: "AddressLimitExceeded"
severity: blocker
auto_fixable: no
---

## 症狀

Terraform 在建 NAT Gateway / Bootstrap public IP 階段失敗：

```
Error: allocating EIP: AddressLimitExceeded: The maximum number of addresses has been reached.
```

## 原因

Region 的 Elastic IP 配額（預設 5）用滿。一個 OKD 集群通常吃 1–3 個 EIP（NAT GW × AZ 數，加 bootstrap public）。

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
