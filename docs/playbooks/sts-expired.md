---
id: sts-expired
applies_to_phase: ["*"]
signals:
  - source: aws_api_error
    code: "ExpiredToken"
  - source: aws_api_error
    code: "ExpiredTokenException"
  - source: terraform_log
    pattern: "expired"
severity: blocker
auto_fixable: partial
---

## 症狀

任何 phase 都可能突然冒出：

```
An error occurred (ExpiredToken) when calling the XxxOperation: The provided token has expired.
```

或 Terraform：

```
Error: ... ExpiredTokenException: The security token included in the request is expired
```

## 原因

STS session token 過期。OKD 安裝/teardown 動輒 30–60 分鐘，session 預設只有 1 小時，跑到一半就掛。

## 建議動作

1. 重新拿 STS credentials（會跳 MFA prompt，輸入 6 碼）：

   ```bash
   cd /Users/cfh00901239/Desktop/okd-deploy
   source scripts/sts-creds.sh
   ```

2. 確認新 credentials 生效：

   ```bash
   aws sts get-caller-identity
   ```

   應看到 `Arn` 含 `assumed-role/...`，且 `Expiration` 是新的時間。

3. 從失敗的 phase 續跑：

   ```bash
   # 看當前 phase
   cat /Users/cfh00901239/Desktop/okd-deploy/clusters/<cluster_name>/status.json | jq .phase

   # build 流程
   cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<cluster_name>
   ../../scripts/build.sh resume

   # teardown 流程
   ../../scripts/teardown.sh
   ```

如果是 `installing` phase 中途過期，installer 自己會 retry 直到 timeout，多半要再下 `build.sh resume`，installer 會接著等 cluster ready。

## 不會自動修復

MFA TOTP 一定要人手敲（或硬體 token），無法自動化。但拿到 creds 後續流程是 partial-auto。
