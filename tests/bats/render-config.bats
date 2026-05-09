#!/usr/bin/env bats
# Tests for scripts/render-config.sh

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMPDIR_TEST="$(mktemp -d)"
  export REPO_ROOT TMPDIR_TEST

  # 拷貝模板與 _lib 到測試目錄結構
  mkdir -p "$TMPDIR_TEST/templates" "$TMPDIR_TEST/scripts" "$TMPDIR_TEST/clusters"
  cp "$REPO_ROOT/templates/install-config.yaml.tmpl" "$TMPDIR_TEST/templates/"
  cp "$REPO_ROOT/scripts/_lib.sh" "$TMPDIR_TEST/scripts/"
  cp "$REPO_ROOT/scripts/render-config.sh" "$TMPDIR_TEST/scripts/"

  export BASE_DOMAIN="example.com"
  export AMI_ID="ami-07da7dc69c82f82a5"
  export REGION="ap-northeast-1"
  export AZ="ap-northeast-1c"
  export SUBNET_PUBLIC="subnet-aaa"
  export SUBNET_PRIVATE="subnet-bbb"
  export VPC_CIDR="10.0.0.0/16"
  export PULL_SECRET='{"auths":{"fake":{"auth":"x"}}}'
  SSH_KEY_FILE="$(mktemp)"
  echo "ssh-rsa AAAAfake test@host" >"$SSH_KEY_FILE"
  export SSH_KEY="$SSH_KEY_FILE"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  rm -f "$SSH_KEY"
}

@test "render-config: 建立有效 install-config.yaml" {
  cd "$TMPDIR_TEST"
  mkdir -p clusters/test01
  echo "4.18.0-okd-scos.10" >clusters/test01/version
  bash scripts/render-config.sh --cluster test01

  [ -f clusters/test01/install-config.yaml ]
  run yq eval '.metadata.name' clusters/test01/install-config.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "test01" ]
}

@test "render-config: 變數正確替換" {
  cd "$TMPDIR_TEST"
  mkdir -p clusters/test02
  echo "4.18.0-okd-scos.10" >clusters/test02/version
  bash scripts/render-config.sh --cluster test02

  run yq eval '.platform.aws.region' clusters/test02/install-config.yaml
  [ "$output" = "ap-northeast-1" ]

  run yq eval '.compute[0].platform.aws.amiID' clusters/test02/install-config.yaml
  [ "$output" = "ami-07da7dc69c82f82a5" ]

  run yq eval '.platform.aws.subnets[0]' clusters/test02/install-config.yaml
  [ "$output" = "subnet-aaa" ]

  run yq eval '.platform.aws.subnets[1]' clusters/test02/install-config.yaml
  [ "$output" = "subnet-bbb" ]
}

@test "render-config: credentialsMode 設為 Manual" {
  cd "$TMPDIR_TEST"
  mkdir -p clusters/test03
  echo "4.18.0-okd-scos.10" >clusters/test03/version
  bash scripts/render-config.sh --cluster test03

  run yq eval '.credentialsMode' clusters/test03/install-config.yaml
  [ "$output" = "Manual" ]
}

@test "render-config: 缺必要 env 時失敗" {
  cd "$TMPDIR_TEST"
  mkdir -p clusters/test04
  echo "4.18.0-okd-scos.10" >clusters/test04/version
  unset AMI_ID

  run bash scripts/render-config.sh --cluster test04
  [ "$status" -ne 0 ]
}

@test "render-config: PULL_SECRET 內 \$ 不被 envsubst 破壞" {
  cd "$TMPDIR_TEST"
  mkdir -p clusters/test05
  echo "4.18.0-okd-scos.10" >clusters/test05/version
  export PULL_SECRET='{"auths":{"x":{"auth":"$NOT_A_VAR_just_a_dollar"}}}'
  bash scripts/render-config.sh --cluster test05

  run yq eval '.pullSecret' clusters/test05/install-config.yaml
  [[ "$output" == *'$NOT_A_VAR_just_a_dollar'* ]]
}
