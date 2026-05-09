---
id: quota-exceeded-ec2
applies_to_phase: [installing]
signals:
  - source: installer_log
    pattern: "VcpuLimitExceeded"
  - source: installer_log
    pattern: "InstanceLimitExceeded"
  - source: aws_api_error
    code: "VcpuLimitExceeded"
severity: blocker
auto_fixable: no
---

## 症狀

`openshift-install create cluster` 在啟 master/worker 時報錯：

```
level=error msg=failed to create instance: VcpuLimitExceeded: You have requested more vCPU capacity than your current vCPU limit of 32 allows for the instance bucket that the specified instance type belongs to.
```

或 `InstanceLimitExceeded`。

## 原因

OKD 預設用 m5 系列（master m5.xlarge × 3 = 12 vCPU；worker m5.large × 2 = 4 vCPU；bootstrap m5.large × 1 = 2 vCPU；總計 18 vCPU）。新帳號 m5 family 預設配額常常只有 5–32 vCPU，不夠。

## 建議動作

1. 查當前 region 的 m5 family vCPU 配額：

   ```bash
   aws service-quotas get-service-quota \
     --service-code ec2 \
     --quota-code L-1216C47A \
     --query 'Quota.[QuotaName,Value]' --output table
   ```

   （L-1216C47A = Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances）

2. 看當前已用了多少 vCPU：

   ```bash
   aws ec2 describe-instances \
     --filters "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
     --output table
   ```

接著選一條路：

[a] **申請配額提升**（最常見，要等幾小時 ~ 1 天）：

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 64
```

[b] **拆掉其他 running EC2 釋放配額**，然後重跑：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<cluster_name>
../../scripts/build.sh resume
```

[c] **降規格**（不推薦，OKD master 至少要 4 vCPU + 16 GB）：編輯 `install-config.yaml` 把 worker 改 m5.large → 不會再降，因為 master 不能再降。

## 不會自動修復

申請配額提升要 AWS 審核，無法 in-script 完成。
