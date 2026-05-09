---
id: ccoctl-s3-conflict
applies_to_phase: [setting_up_iam]
signals:
  - source: aws_api_error
    code: "BucketAlreadyOwnedByYou"
  - source: aws_api_error
    code: "BucketAlreadyExists"
  - source: installer_log
    pattern: "create-identity-provider.*failed"
severity: blocker
auto_fixable: partial
---

## 症狀

`scripts/ccoctl-setup.sh` 失敗：

```
level=error msg=failed to create identity provider: BucketAlreadyOwnedByYou: Your previous request to create the named bucket succeeded and you already own it.
```

或：

```
BucketAlreadyExists: The requested bucket name is not available.
```

## 原因

之前 build 失敗 / 沒徹底 teardown，留下了 ccoctl 建的 OIDC S3 bucket（命名通常 `<cluster_name>-oidc`），新跑 `ccoctl create all` 撞名。

## 建議動作

1. 找出殘留的 OIDC bucket：

   ```bash
   CLUSTER=<cluster_name>
   aws s3 ls | grep -i "${CLUSTER}"
   ```

   通常會看到一條 `<cluster_name>-oidc` 或類似的。

2. 確認 bucket 確實是 ccoctl 留下（內容是 OIDC keys / discovery doc）而非別人的：

   ```bash
   aws s3 ls "s3://${CLUSTER}-oidc/" --recursive
   ```

   應看到 `keys.json`、`.well-known/openid-configuration`。

3. 一併查 IAM OIDC provider 是否殘留：

   ```bash
   aws iam list-open-id-connect-providers \
     --query "OpenIDConnectProviderList[?contains(Arn, '${CLUSTER}')]"
   ```

接著選一條路：

[a] **完整清掉殘留再重跑 ccoctl-setup.sh**（推薦）：

```bash
# 1. 清 S3 bucket（--force 連帶刪 objects + versions）
aws s3 rb "s3://${CLUSTER}-oidc" --force

# 2. 清 IAM OIDC provider（如果存在）
PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '${CLUSTER}')].Arn" \
  --output text)
[ -n "$PROVIDER_ARN" ] && aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "$PROVIDER_ARN"

# 3. 清 ccoctl 建的 IAM roles（命名 <cluster>-<component>-credentials）
aws iam list-roles \
  --query "Roles[?contains(RoleName, '${CLUSTER}')].RoleName" \
  --output text | tr '\t' '\n' | while read role; do
    # 先 detach policies 才能刪
    aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | \
      xargs -I{} aws iam detach-role-policy --role-name "$role" --policy-arn {}
    aws iam delete-role --role-name "$role"
  done

# 4. 重跑
cd /Users/cfh00901239/Desktop/okd-deploy
scripts/ccoctl-setup.sh "$CLUSTER"
```

[b] **若不確定 bucket 歸屬，只刪自己 cluster 目錄裡的 manifest 重新生**：

```bash
cd /Users/cfh00901239/Desktop/okd-deploy/clusters/$CLUSTER
rm -rf manifests/openshift-cluster-csi-drivers-* manifests/openshift-image-registry-*
../../scripts/build.sh --from setting_up_iam
```

## 不會自動修復

刪 S3 bucket 是不可逆操作，要確認該 bucket 真的是孤兒（不是別人活的 cluster）才能動。AI 不該主動刪。
