> **註記（2026-05-09）**：本檔記載的手動流程已被 OpenSpec change `okd-ai-agent` 取代為 IaC + Skills 驅動的自動化版本。
> 日常使用請改用 `/okd-build <name>`（見 `README.md`）。本檔保留作為手動 fallback 與歷史參考。

## 手動在 AWS 上建立 VPC
### VPC 的配置
- VPC and more
- 輸入叢集名稱
- public 及 private subnet 各一個
- NAT gateway 選 In 1 AZ
- VPC endpoint 選 S3 Gateway

### vpc 下的 public subnet 開啟 "Enable auto-assign public IPv4 address"

## 安裝 openshift-install, ccoctl, oc
https://github.com/okd-project/okd/releases/download/4.18.0-okd-scos.10/openshift-install-linux-4.18.0-okd-scos.10.tar.gz
https://github.com/okd-project/okd/releases/download/4.18.0-okd-scos.10/ccoctl-linux-4.18.0-okd-scos.10.tar.gz
https://github.com/okd-project/okd/releases/download/4.18.0-okd-scos.10/openshift-client-linux-4.18.0-okd-scos.10.tar.gz

## 取得 AWS 的臨時憑證
目前是透過這份腳本
```shell=
#!/bin/bash

# 設定變數
ROLE_ARN="arn:aws:iam::404906229455:role/lab_kevin_access" # 使用有權限的Role
MFA_ARN="arn:aws:iam::404906229455:mfa/Kevin-MFA" # 修改成自己的 user MFA ARN
# MFA_SECRET="xxxxxxxxxx"  # 自動化用的目前不用理他，您的虛擬 MFA 設備密鑰
DURATION=43200  # 憑證有效時間（秒）


MFA_CODE="148915" # 看手機的Google Authenticator
# MFA_CODE=$(oathtool --base32 --totp $MFA_SECRET) #這行自動化用的，目前不用看

# 獲取 STS 臨時憑證
sts_response=$(aws sts assume-role \
  --role-arn $ROLE_ARN \
  --role-session-name "automated-session" \
  --serial-number $MFA_ARN \
  --token-code $MFA_CODE \
  --duration-seconds $DURATION \
  --output json \
  --profile lab_kevin)

# 提取憑證並設置為環境變數
export AWS_ACCESS_KEY_ID=$(echo $sts_response | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $sts_response | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $sts_response | jq -r '.Credentials.SessionToken')

echo "AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID";"
echo "AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY";"
echo "AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN
echo "STS 憑證已獲取並設置為環境變數，有效期為 $DURATION 秒"
```

## 開始 OKD 安裝
```shell
OKD_NAME=<OKD_NAME>

mkdir $OKD_NAME && cd $OKD_NAME

REGION="ap-northeast-1"

RELEASE_IMAGE=$(openshift-install version | awk '/release image/ {print $3}')

ccoctl aws create-key-pair
ccoctl aws create-identity-provider --name=$OKD_NAME --region=$REGION --public-key-file=serviceaccount-signer.public --create-private-s3-bucket

CLOUDFRONT_ID=$(
  sed -nE 's|.*https://([a-z0-9-]+)\.cloudfront\.net.*|\1|p' \
  $(pwd)/manifests/cluster-authentication-02-config.yaml
)

mkdir $(pwd)/credrequests

oc adm release extract --credentials-requests --cloud=aws --to=$(pwd)/credrequests --from=$RELEASE_IMAGE

ccoctl aws create-iam-roles --name=$OKD_NAME --region=$REGION --credentials-requests-dir=$(pwd)/credrequests --identity-provider-arn=arn:aws:iam::091798609788:oidc-provider/$CLOUDFRONT_ID.cloudfront.net

openshift-install create install-config
```

## 修改 install-config.yaml
主要加入 `credentialsMode`, aws 資訊等
```yaml=
credentialsMode: Manual # 加上這行
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      metadataService:
        authentication: Required
      amiID: ami-07da7dc69c82f82a5
      type: m5.4xlarge
      zones:
      - ap-northeast-1c #改subnetzone
  replicas: 2 
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      metadataService:
        authentication: Required
      amiID: ami-07da7dc69c82f82a5
      type: m5.2xlarge
  replicas: 1
platform:
  aws:
    region: ap-northeast-1
    userTags:
      owner: lab_kevin
      purpose: cafe_okd
    subnets:
    - subnet-0d1ee6a5361db4ac0
    - subnet-03340d09c63c35919
```

## 產生並修改 manifest
裡面有一個地方是寫private subnet ，把它修改成public subnet
```shell
mv manifests cco_manifests
openshift-install --dir=. create manifests

vi openshift/99_openshift-cluster-api_worker-machineset-0.yaml
```

## 安裝
```
cp cco_manifests/* manifests
cp credrequests/* manifests

openshift-install --dir=. create cluster
```