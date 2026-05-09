---
id: machineset-no-subnet
applies_to_phase: [patching_manifests, installing]
signals:
  - source: installer_log
    pattern: "subnet not found"
  - source: oc_output
    pattern: "could not find subnet"
severity: blocker
auto_fixable: partial
---

## 症狀

installer 或 machine controller 報錯：

```
error: subnet not found: subnet-0xxxxxxx
```

或 `oc -n openshift-machine-api logs` 顯示：

```
could not find subnet for availability zone us-west-2a
```

worker MachineSet 一直 `Replicas: 0/2`。

## 原因

`scripts/patch-machineset.sh` 沒成功把 placeholder 換成真的 subnet ID。常見原因：

- patch-machineset.sh 跑時 Terraform output 還沒寫好（race）
- 拿到的 subnet 是 public subnet ID 而非 private（worker 應該在 private）
- AZ 數量對不上（machineset.yaml 有 3 份對應 3 AZ，但 VPC 只開 2 AZ）

## 建議動作

1. 看當前 manifest 裡 subnet 設定到底是什麼：

   ```bash
   CLUSTER=<cluster_name>
   cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER
   grep -A2 'subnet' manifests/99_openshift-cluster-api_worker-machineset-*.yaml
   ```

   重點看是不是還是 placeholder（如 `__SUBNET_PRIVATE_A__`）或空字串。

2. 對比 Terraform output 的 subnet 列表：

   ```bash
   cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER/terraform
   terraform output -json | jq '.private_subnets.value, .public_subnets.value'
   ```

3. 確認那些 subnet ID 真的存在於該 VPC 且為 private：

   ```bash
   aws ec2 describe-subnets \
     --subnet-ids <subnet-id-1> <subnet-id-2> <subnet-id-3> \
     --query 'Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' \
     --output table
   ```

   `MapPublicIpOnLaunch` 應該都是 `False`。

接著選一條路：

[a] **重跑 patch-machineset.sh**（最常見修法，phase=patching_manifests 就死的）：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy
scripts/patch-machineset.sh "$CLUSTER"

# 確認 manifest 已被替換
grep 'subnet:' clusters/$CLUSTER/manifests/99_openshift-cluster-api_worker-machineset-*.yaml
```

[b] **手動編輯 machineset 後續跑**（cluster 已 install 起來，machineset live 但 subnet 錯）：

```bash
# 取出 machineset
oc -n openshift-machine-api get machineset -o name | while read ms; do
  oc -n openshift-machine-api edit "$ms"
  # 在編輯器裡修 .spec.template.spec.providerSpec.value.subnet.id
done

# 看 machineset 是否啟動 instance
oc -n openshift-machine-api get machineset
oc -n openshift-machine-api get machine
```

[c] **AZ 數對不上**（VPC 只 2 AZ 但 machineset 期待 3 AZ）：刪掉多的 machineset：

```bash
oc -n openshift-machine-api delete machineset <cluster>-worker-us-west-2c
```

或回去調 install-config.yaml 的 `compute[0].platform.aws.zones`，整個 teardown 重 build。

## 不會自動修復

手動 edit live machineset 是 destructive 操作（會殺重建 worker），要由人決定時機。partial-auto 限於「重跑 patch-machineset.sh」這條。
