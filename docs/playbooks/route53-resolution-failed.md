---
id: route53-resolution-failed
applies_to_phase: [installing, verifying]
signals:
  - source: installer_log
    pattern: "no such host"
  - source: oc_output
    pattern: "no such host"
  - source: installer_log
    pattern: "lookup .* on .*: no such host"
severity: blocker
auto_fixable: no
---

## 症狀

installer 或 oc 解 cluster 域名失敗：

```
dial tcp: lookup api.<cluster>.<basedomain> on 10.0.0.2:53: no such host
```

或：

```
Get "https://api.<cluster>.<basedomain>:6443/...": dial tcp: lookup api...: no such host
```

## 原因

兩種主要情境：

1. **Private hosted zone 沒 associate 到 cluster VPC**：master 在 VPC 內 resolve `api-int.<cluster>` 走的是 VPC resolver → private zone，但 zone 沒掛上 VPC 就會 NXDOMAIN
2. **`<basedomain>` 在外部 DNS 沒正確 delegate 給 Route53 public zone**：你從外部 `dig api.<cluster>.<basedomain>` 失敗，但 NS 對不到 AWS 的 NS

## 建議動作

1. 列出所有 hosted zone（看 public + private）：

   ```bash
   aws route53 list-hosted-zones \
     --query 'HostedZones[].[Id,Name,Config.PrivateZone]' \
     --output table
   ```

2. 看 cluster 的 private zone 有沒有 associate 到 VPC：

   ```bash
   ZONE_ID=<private_zone_id>
   aws route53 get-hosted-zone --id "$ZONE_ID" \
     --query 'VPCs[].[VPCId,VPCRegion]' --output table
   ```

   如果空的或對不到 cluster VPC ID，就是問題所在。

3. 看 private zone 裡有沒有 `api`、`api-int`、`*.apps` records：

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
     --query 'ResourceRecordSets[].[Name,Type,AliasTarget.DNSName]' \
     --output table
   ```

4. 從外部測 public 解析（在自己 mac 上跑）：

   ```bash
   dig +short api.<cluster>.<basedomain> @8.8.8.8
   dig +short NS <basedomain> @8.8.8.8
   ```

   `NS` 應該指向 4 個 `ns-*.awsdns-*.*` 才對。

接著選一條路：

[a] **手動 associate private zone 到 VPC**：

```bash
aws route53 associate-vpc-with-hosted-zone \
  --hosted-zone-id "$ZONE_ID" \
  --vpc VPCRegion="$AWS_REGION",VPCId=<cluster_vpc_id>
```

[b] **若 record 缺失**，多半是 installer 中途死，建議整個 teardown 重來：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<cluster_name>
../../scripts/teardown.sh
../../scripts/build.sh
```

[c] **若是外部 NS delegation 錯**，到 domain registrar (Cloudflare / GoDaddy / etc.) 把 NS records 改指向 AWS Route53 的 4 個 NS。改完要等 TTL（最多 48 小時，但通常 < 1 小時）。

## 不會自動修復

NS delegation 在 registrar 端，AWS 內 script 改不到。private zone 的 VPC association 雖可 script，但要先確定不是另一個 staler zone 才能動。
