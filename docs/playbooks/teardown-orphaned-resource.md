---
id: teardown-orphaned-resource
applies_to_phase: [tearing_down]
signals:
  - source: terraform_log
    pattern: "DependencyViolation"
  - source: terraform_log
    pattern: "has dependencies and cannot be deleted"
  - source: aws_api_error
    code: "DependencyViolation"
severity: warning
auto_fixable: no
---

## 症狀

`terraform destroy` 在收尾階段卡住：

```
Error: deleting EC2 Subnet (subnet-0xxxx): DependencyViolation: The subnet 'subnet-0xxxx' has dependencies and cannot be deleted.
```

或：

```
Error: deleting EC2 Security Group (sg-0xxxx): DependencyViolation: resource sg-0xxxx has a dependent object
```

或：

```
Error: deleting EC2 VPC (vpc-0xxxx): DependencyViolation
```

## 原因

AWS 資源刪除有依賴鏈，常見三種殘留：

1. **ENI 還掛在已刪除 instance 上**（eventual consistency，instance state=terminated 但 ENI 還沒回收）
2. **SG 被另一個 SG rule 引用**（A 的 rule 引用 B，B 想刪 → 卡住）
3. **Route53 record 還在 hosted zone 裡**（Terraform 不管 ccoctl / installer 自己建的 record）
4. **NLB / target group / load balancer interface** 還在

## 建議動作

1. 先找出 cluster 的 VPC ID：

   ```bash
   CLUSTER=<cluster_name>
   VPC_ID=$(aws ec2 describe-vpcs \
     --filters "Name=tag:Name,Values=${CLUSTER}-vpc" \
     --query 'Vpcs[0].VpcId' --output text)
   echo "$VPC_ID"
   ```

2. 列出該 VPC 內所有殘留 ENI（最常見元兇）：

   ```bash
   aws ec2 describe-network-interfaces \
     --filters "Name=vpc-id,Values=${VPC_ID}" \
     --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Description,Attachment.InstanceId]' \
     --output table
   ```

3. 列出殘留的 SG（看 rule 依賴）：

   ```bash
   aws ec2 describe-security-groups \
     --filters "Name=vpc-id,Values=${VPC_ID}" \
     --query 'SecurityGroups[].[GroupId,GroupName]' \
     --output table
   ```

4. 列出殘留的 NLB / classic LB：

   ```bash
   aws elbv2 describe-load-balancers \
     --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,LoadBalancerArn,State.Code]" \
     --output table
   ```

5. 列出 Route53 殘留 record：

   ```bash
   ZONE_ID=$(aws route53 list-hosted-zones \
     --query "HostedZones[?contains(Name, '${CLUSTER}')].Id" --output text)
   [ -n "$ZONE_ID" ] && aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID"
   ```

接著選一條路：

[a] **手動清殘留 ENI / NLB 後重跑 destroy**（推薦）：

```bash
# 刪殘留 ENI（先 detach，再 delete）
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | tr '\t' '\n' | \
  xargs -I{} aws ec2 delete-network-interface --network-interface-id {}

# 刪殘留 NLB
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text | \
  tr '\t' '\n' | xargs -I{} aws elbv2 delete-load-balancer --load-balancer-arn {}

# 等 30 秒讓 ENI 真的釋放
sleep 30

# 重跑 teardown
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER
../../scripts/teardown.sh
```

[b] **SG 互相引用解法**：先把 cross-reference 規則 revoke 再刪：

```bash
# 列出 cross-reference rule，手動 revoke
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[].IpPermissions[?contains(UserIdGroupPairs[].GroupId, `sg-`)]'

# revoke 範例
aws ec2 revoke-security-group-ingress \
  --group-id <sg-A> \
  --source-group <sg-B> --protocol tcp --port 6443
```

[c] **暴力清乾淨**（最後手段，確認 VPC 真的是該 cluster 的才能用）：

```bash
# 用官方 AWS Tag-Based 清理腳本（OpenShift 提供 cluster-uninstaller，但需要單獨裝）
# 或手動順序：instance → ENI → NLB → SG → subnet → IGW/NAT → VPC
# 上面那些 list 命令逐個 delete-* 對應資源
```

## 不會自動修復

殘留資源涉及跨資源依賴，盲目刪可能誤刪正在運行的別 cluster。AI 只能列清單，最後 destroy 要由人確認後 trigger。
