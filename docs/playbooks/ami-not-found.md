---
id: ami-not-found
applies_to_phase: [rendering_config, installing]
signals:
  - source: preflight
    pattern: "AMI not found"
  - source: aws_api_error
    code: "InvalidAMIID.NotFound"
severity: blocker
auto_fixable: no
---

## 症狀

Preflight 階段：

```
[preflight] AMI not found: ami-0abcd1234 in region us-west-2
```

或 installer/Terraform 階段：

```
InvalidAMIID.NotFound: The image id '[ami-0abcd1234]' does not exist
```

## 原因

`.env` 裡 `AMI_ID` 對不上當前 region：

- 換了 region 但忘了換 AMI（AMI ID 是 region-specific）
- 該 AMI 已被 Fedora CoreOS / OKD 上游退版
- AMI 在另一個 AWS account 且沒分享給你

## 建議動作

1. 確認當前用的 region 和 AMI：

   ```bash
   cd /Users/cfh00901239/Desktop/okd-deploy
   grep -E '^(AWS_REGION|AMI_ID)=' .env
   ```

2. 在當前 region 找最新 OKD-compatible Fedora CoreOS AMI：

   ```bash
   AWS_REGION=$(grep '^AWS_REGION=' .env | cut -d= -f2)
   aws ec2 describe-images \
     --region "$AWS_REGION" \
     --owners 125523088429 \
     --filters "Name=name,Values=fedora-coreos-*-x86_64" \
               "Name=state,Values=available" \
     --query 'sort_by(Images, &CreationDate)[-5:].[ImageId,Name,CreationDate]' \
     --output table
   ```

   （Owner `125523088429` = Fedora CoreOS official）

3. 取最新一筆 ImageId，更新 `.env`：

   ```bash
   # 編輯 .env，把 AMI_ID=... 換成新的
   ${EDITOR:-vi} /Users/cfh00901239/Desktop/okd-deploy/.env
   ```

4. 重跑 preflight + 從失敗 phase 續：

   ```bash
   cd /Users/cfh00901239/Desktop/okd-deploy/clusters/<cluster_name>
   ../../scripts/build.sh resume
   ```

   若 phase 已過 `rendering_config`，要先回到 `rendering_config` 重新生 ignition：

   ```bash
   ../../scripts/build.sh --from rendering_config
   ```

## 不會自動修復

選 AMI 影響穩定性（OKD release 對應的 FCOS 版本是綁的，亂換可能 boot 不起來）。必須由人確認 OKD 文件上對應的 FCOS 版本範圍。
