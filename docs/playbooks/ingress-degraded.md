---
id: ingress-degraded
applies_to_phase: [verifying]
signals:
  - source: oc_output
    pattern: "ingress.*Degraded.*True"
  - source: oc_output
    pattern: "router-default.*CrashLoopBackOff"
severity: warning
auto_fixable: no
---

## 症狀

`oc get co` 顯示 ingress operator Degraded：

```
NAME      VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE
ingress             False       True          True       15m
```

或：

```
NAME                              READY   STATUS             RESTARTS
router-default-7d9b8c5f4d-abcde   0/1     CrashLoopBackOff   5
```

cluster API 通了但 `*.apps.<cluster>` 開不起來。

## 原因

常見三種：

1. **NLB target health check 一直 fail**：worker 在 private subnet，但 NLB listener 往 worker 打 healthcheck 走錯 SG / 沒開 router pod port (1936)
2. **Worker SG 沒開 80/443 from NLB**：router pod 拿不到流量
3. **Route53 `*.apps.<cluster>.<basedomain>` 記錄沒建** 或指錯 NLB

## 建議動作

1. 看 ingress operator 詳細狀態：

   ```bash
   oc get co ingress -o yaml | grep -A5 conditions
   oc -n openshift-ingress-operator logs deploy/ingress-operator | tail -100
   ```

2. 看 router pod 為什麼起不來：

   ```bash
   oc -n openshift-ingress get pods -o wide
   oc -n openshift-ingress describe pod -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default
   oc -n openshift-ingress logs -l app=router --tail=200
   ```

3. 找 cluster 的 NLB，看 target group 健康度：

   ```bash
   CLUSTER=<cluster_name>
   aws elbv2 describe-load-balancers \
     --query "LoadBalancers[?contains(LoadBalancerName, '${CLUSTER}')].[LoadBalancerName,DNSName,LoadBalancerArn]" \
     --output table

   # 取上面的 ARN，看 target group health
   aws elbv2 describe-target-groups --load-balancer-arn <NLB_ARN> \
     --query 'TargetGroups[].TargetGroupArn' --output text | \
     xargs -n1 -I{} aws elbv2 describe-target-health --target-group-arn {}
   ```

   重點看 `TargetHealth.State`：`unhealthy` 並看 `Reason`（`Target.FailedHealthChecks` / `Target.Timeout`）。

4. 檢查 Route53 `*.apps` record 是否指向上面 NLB DNS：

   ```bash
   ZONE_ID=$(aws route53 list-hosted-zones \
     --query "HostedZones[?Name=='<basedomain>.'].Id" --output text)
   aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
     --query "ResourceRecordSets[?contains(Name, 'apps.${CLUSTER}')]"
   ```

5. 檢查 worker SG 有沒有開 80/443/1936 from NLB SG（NLB 是 IP-target NLB 時要從 NLB subnet CIDR 開）：

   ```bash
   aws ec2 describe-security-groups \
     --filters "Name=tag:Name,Values=${CLUSTER}-worker-sg" \
     --query 'SecurityGroups[].IpPermissions'
   ```

接著選一條路：

[a] **改 SG 補規則**（最常見修法）：在 worker SG 加上 80/443 from VPC CIDR，等 1–2 分鐘看 target health 翻 `healthy`。

[b] **改 Route53 record** 指向正確 NLB DNS。

[c] **若是 router pod CrashLoopBackOff 且 log 顯示其他奇怪錯**（如 cert 缺失、image pull fail），翻 `oc -n openshift-ingress-operator logs` 找根因，可能要重建 ingresscontroller：

```bash
oc -n openshift-ingress-operator delete ingresscontroller default
# operator 會自動重建
```

## 不會自動修復

ingress 涉及多個 AWS / cluster 元件交叉，根因要看具體 health check failure reason，不能盲目修。
