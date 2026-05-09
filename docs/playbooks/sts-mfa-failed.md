---
id: sts-mfa-failed
applies_to_phase: [getting_creds]
signals:
  - source: aws_api_error
    code: "AccessDenied"
  - source: aws_api_error
    code: "MultiFactorAuthentication"
  - source: installer_log
    pattern: "InvalidUserToken"
severity: blocker
auto_fixable: no
---

## 症狀

`scripts/sts-creds.sh` 失敗：

```
An error occurred (AccessDenied) when calling the AssumeRole operation: MultiFactorAuthentication failed with invalid MFA one time pass code.
```

或 `InvalidUserToken`。

## 原因

TOTP 6 碼驗證失敗，常見三種原因：

1. **本機時鐘漂移**：TOTP 依賴時間，差 30 秒以上就會 fail
2. **secret 與 Authenticator 不同步**：`~/.aws/mfa-secret` 內容不是當初註冊到 Google Authenticator 的那組
3. **碼已過期**：TOTP 每 30 秒換一次，輸入時剛好跨界

## 建議動作

1. 檢查本機時鐘對 NTP 是否同步：

   ```bash
   # macOS
   sntp -sS time.apple.com
   # 或看當前時間 vs Google
   date -u
   curl -sI https://www.google.com | grep -i '^date:'
   ```

   兩者差異 >10 秒就要修。macOS：

   ```bash
   sudo sntp -sS time.apple.com
   ```

2. 比對 secret 是否和 Google Authenticator 上的 entry 同一組：

   ```bash
   # 看當前 secret 算出來的 6 碼
   oathtool --totp -b "$(cat ~/.aws/mfa-secret)"
   ```

   把它和手機 Authenticator 上的 6 碼對。**不一樣就是 secret 錯了**，要重新註冊：

   - AWS Console → IAM → Users → 自己 → Security credentials → Multi-factor authentication → Remove → Assign MFA device
   - 取得新 secret，存回 `~/.aws/mfa-secret`（覆蓋）
   - 同時掃 QR code 進 Authenticator

3. 若時鐘對、secret 也對，純粹是「6 碼正好過期」，重跑：

   ```bash
   source /Users/cfh00901239/Desktop/okd-deploy/scripts/sts-creds.sh
   ```

   建議在 6 碼剛跳新（畫面剩 25–30 秒）時下指令，不要在剩 < 5 秒時輸入。

## 不會自動修復

MFA 是雙因子設計，AI 不能也不該幫使用者輸入 TOTP；secret 重新註冊需要 AWS Console 操作。
