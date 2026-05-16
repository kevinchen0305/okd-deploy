---
id: teardown-guardduty-vpc-residue
applies_to_phase: [tearing_down]
signals:
  - source: terraform_log
    pattern: "DependencyViolation"
  - source: terraform_log
    pattern: "GuardDuty"
severity: warning
auto_fixable: partial
---

## 症狀

`terraform destroy` 在拆 VPC / Subnet / SG 時報 `DependencyViolation`，且 VPC 內可以看到非 terraform 建的東西：

```
=== ENIs in VPC ===
| Desc | VPC Endpoint Interface vpce-064463cbaa359c14c | <- 不是 NAT GW、不是 LB
| Sgs  | sg-0755a7db42c3e3bfe                          |

=== Security groups ===
| Id | sg-0755a7db42c3e3bfe                                 |
| Name | GuardDutyManagedSecurityGroup-vpc-053513aa60509427e |

=== VPC endpoints ===
| vpce-064463cbaa359c14c | com.amazonaws.<region>.guardduty-data | available |
```

關鍵 signal：endpoint service 名稱含 `guardduty-data`、SG 名以 `GuardDutyManagedSecurityGroup-` 開頭。

## 原因

AWS 帳號啟用 GuardDuty 的 **Runtime Monitoring**（或 EKS / Lambda / EC2 runtime monitoring）後，AWS 會**自動在每個新建 VPC 內**塞兩樣東西：

1. **VPC interface endpoint** `com.amazonaws.<region>.guardduty-data` — 給 GuardDuty agent 回 traffic 用
2. **Managed security group** `GuardDutyManagedSecurityGroup-vpc-<id>` — 套在那個 endpoint 的 ENI 上

這兩個 **不是 terraform 建的**、**不在 tfstate 內**，所以 `terraform destroy` 不知道它們存在；但它們存在於 subnet / 引用 VPC，導致 subnet / VPC / SG 都無法刪。

## 建議動作

### [a] 手動清 GuardDuty 殘留後重跑 destroy（推薦）

```bash
VPC_ID=<vpc id, 從 terraform state 或 .env 對應的 cluster_name 反查>

# 1. 找出 GuardDuty endpoint
EP_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=service-name,Values=com.amazonaws.*.guardduty-data" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text)
echo "GuardDuty endpoints: $EP_IDS"

# 2. 刪 endpoint（會 async 釋放 ENI）
[[ -n "$EP_IDS" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $EP_IDS

# 3. 等 ENI 變 available（最多 60s）
sleep 30

# 4. 砍 orphan ENI（有時 AWS GC 不夠快）
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | tr '\t' '\n' \
  | xargs -r -I{} aws ec2 delete-network-interface --network-interface-id {}

# 5. 砍 GuardDuty managed SG
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" \
  --query 'SecurityGroups[].GroupId' --output text)
[[ -n "$SG_IDS" ]] && for sg in $SG_IDS; do aws ec2 delete-security-group --group-id "$sg"; done

# 6. 重跑 teardown（teardown.sh 自己會帶 -var 重 destroy）
scripts/teardown.sh --cluster <name>
```

### [b] 從 GuardDuty 那側關掉 VPC integration（一次性解法）

開 GuardDuty Console → Settings → VPC Flow Logs / Runtime Monitoring → 取消對應功能。**會影響整個帳號的 GuardDuty 偵測能力**，務必跟 security team 確認。

### [c] 接受殘留、手動 cascade 刪 VPC

如果 destroy 已經跑爛、tfstate 也壞了（典型：`--purge` 把 tfstate 連目錄一起刪），照下面 cascade 順序逐個 aws cli 刪。**特別注意 EIP**：刪掉 NAT GW 後立刻用 `NetworkInterfaceId==null` 篩 EIP 會撈不到（AWS 那邊 association 尚未刷新）— 改用 cluster tag 抓：

```bash
CLUSTER=<name>
REGION=<region>
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=${CLUSTER}-vpc --query 'Vpcs[0].VpcId' --output text)

# 1. VPC endpoints (含 GuardDuty)
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID \
  --query 'VpcEndpoints[].VpcEndpointId' --output text | tr '\t' '\n' \
  | xargs -r aws ec2 delete-vpc-endpoints --vpc-endpoint-ids

# 2. NAT GW (async)
NAT_ID=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID \
  Name=state,Values=available,pending --query 'NatGateways[0].NatGatewayId' --output text)
[[ "$NAT_ID" != "None" ]] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
until [ "$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
       --query 'NatGateways[0].State' --output text 2>/dev/null)" = "deleted" ]; do sleep 15; done

# 3. EIPs (by cluster tag, NOT by NetworkInterfaceId — 後者剛刪完 NAT GW 會 false-negative)
aws ec2 describe-addresses --query "Addresses[?Tags[?Value=='${CLUSTER}']].AllocationId" --output text \
  | tr '\t' '\n' | xargs -r -I{} aws ec2 release-address --allocation-id {}

# 4. IGW
IGW=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
[[ "$IGW" != "None" ]] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" \
  && aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"

# 5. custom route tables (non-main)
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text | tr '\t' '\n' \
  | while read -r RT; do
      [[ -z "$RT" ]] && continue
      aws ec2 describe-route-tables --route-table-ids "$RT" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text \
        | xargs -r -n1 aws ec2 disassociate-route-table --association-id
      aws ec2 delete-route-table --route-table-id "$RT"
    done

# 6. 殘留 ENI (GuardDuty endpoint 砍完 ENI 通常還在 available 一陣子)
sleep 30
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID Name=status,Values=available \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | tr '\t' '\n' \
  | xargs -r -I{} aws ec2 delete-network-interface --network-interface-id {}

# 7. subnets
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].SubnetId' --output text | tr '\t' '\n' \
  | xargs -r -I{} aws ec2 delete-subnet --subnet-id {}

# 8. GuardDuty SG
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
  Name=group-name,Values=GuardDutyManagedSecurityGroup-* \
  --query 'SecurityGroups[].GroupId' --output text | tr '\t' '\n' \
  | xargs -r -I{} aws ec2 delete-security-group --group-id {}

# 9. VPC
aws ec2 delete-vpc --vpc-id "$VPC_ID"
```

## 不會自動修復

GuardDuty 是 security 服務，盲目刪 endpoint / 改 GuardDuty settings 都可能違反 org policy。AI 只能列出殘留 + 建議命令，實際執行要人確認。

## 相關

- [[teardown-orphaned-resource]] — DependencyViolation 一般情況
