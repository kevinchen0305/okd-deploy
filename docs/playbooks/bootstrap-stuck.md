---
id: bootstrap-stuck
applies_to_phase: [installing]
signals:
  - source: installer_log
    pattern: "Bootstrap status: complete: false \\(expected\\)"
  - source: installer_log
    pattern: "waiting for the cluster API"
  - source: installer_log
    pattern: "context deadline exceeded"
severity: blocker
auto_fixable: no
---

## 症狀

`openshift-install` 卡在 bootstrap 階段超過 30 分鐘，log 不斷重複：

```
level=debug msg=Bootstrap status: complete: false (expected)
level=info msg=Waiting up to 20m0s for the Kubernetes API at https://api.<cluster>.<base>:6443...
level=error msg=failed to wait for bootstrapping to complete: context deadline exceeded
```

## 原因

Bootstrap EC2 已經 running，但 cluster API 從外部 / master 連不到。常見三種：

1. **Security Group 缺 port 6443 ingress**：master SG 沒讓 bootstrap / API LB 進來
2. **Route53 private zone 沒建好或沒 associate 到 VPC**：master 自己 resolve 不了 `api-int.<cluster>` → 起不來
3. **Ignition fetch 失敗**：master/bootstrap 從 S3 抓 ignition，但 IAM role 沒權限或 S3 bucket policy 擋掉 → bootstrap log 會看到 403

## 建議動作

1. 找 bootstrap instance ID：

   ```bash
   CLUSTER=<cluster_name>
   BOOTSTRAP_ID=$(aws ec2 describe-instances \
     --filters "Name=tag:Name,Values=${CLUSTER}-bootstrap" \
               "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' \
     --output text)
   echo "$BOOTSTRAP_ID"
   ```

2. 撈 bootstrap 主機 console 看 ignition / kubelet 啟動有沒有錯：

   ```bash
   aws ec2 get-console-output --instance-id "$BOOTSTRAP_ID" --output text | tail -200
   ```

   重點看：
   - `Failed to fetch` / `403 Forbidden` → ignition / S3 IAM 問題
   - `dial tcp ... no route to host` → SG / route table 問題
   - `lookup api-int.* no such host` → Route53 問題（同時參考 `route53-resolution-failed`）

3. 檢查 master SG 是否允許 6443 from API LB / bootstrap：

   ```bash
   aws ec2 describe-security-groups \
     --filters "Name=tag:Name,Values=${CLUSTER}-master-sg" \
     --query 'SecurityGroups[].IpPermissions[?FromPort==`6443`]'
   ```

4. 檢查 Route53 private zone 是否 associate 到 cluster VPC：

   ```bash
   aws route53 list-hosted-zones-by-vpc \
     --vpc-id <cluster_vpc_id> \
     --vpc-region "$AWS_REGION"
   ```

接著選一條路：

[a] **若是 SG / Route53 缺 record，手動補完後重跑 wait-for**：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER
openshift-install wait-for bootstrap-complete --log-level=debug
```

[b] **若是 ignition / S3 IAM 問題，幾乎只能整個 teardown 重來**（因為 ignition 已經寫死在 user-data）：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER
../../scripts/teardown.sh
../../scripts/build.sh
```

[c] **保留 bootstrap 撈 log 後再拆**：

```bash
# bootstrap 還活著時，撈 journalctl
ssh -i <key> core@<bootstrap_public_ip> "sudo journalctl -u bootkube --no-pager" > bootstrap.log
# 完整撈完再 teardown
```

## 不會自動修復

bootstrap 失敗有 N 種子原因，沒看 console output 不能盲目重跑。必須由人讀 console output 後決定。
