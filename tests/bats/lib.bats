#!/usr/bin/env bats
# Tests for scripts/_lib.sh helpers

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMPDIR_TEST="$(mktemp -d)"
  export REPO_ROOT TMPDIR_TEST

  mkdir -p "$TMPDIR_TEST/scripts" "$TMPDIR_TEST/clusters" "$TMPDIR_TEST/bin"
  cp "$REPO_ROOT/scripts/_lib.sh" "$TMPDIR_TEST/scripts/"

  # Override paths for testing
  cd "$TMPDIR_TEST"
  source scripts/_lib.sh
  CLUSTERS_DIR="$TMPDIR_TEST/clusters"
  BIN_DIR="$TMPDIR_TEST/bin"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "init_status: 建立 status.json 含正確欄位" {
  init_status "test01" "4.18.0-okd-scos.10" "ap-northeast-1" "ap-northeast-1c"
  [ -f clusters/test01/status.json ]

  run jq -r '.cluster_name' clusters/test01/status.json
  [ "$output" = "test01" ]

  run jq -r '.phase' clusters/test01/status.json
  [ "$output" = "pending" ]

  run jq -r '.region' clusters/test01/status.json
  [ "$output" = "ap-northeast-1" ]
}

@test "is_valid_phase: 已知 phase 通過、未知 phase 拒絕" {
  run is_valid_phase "ready"
  [ "$status" -eq 0 ]

  run is_valid_phase "garbage_phase"
  [ "$status" -ne 0 ]
}

@test "update_phase: 更新 status.json 的 phase 與 history" {
  init_status "test02" "4.18.0-okd-scos.10" "ap-northeast-1" "ap-northeast-1c"
  update_phase "test02" "provisioning_vpc"

  run jq -r '.phase' clusters/test02/status.json
  [ "$output" = "provisioning_vpc" ]

  run jq -r '.phase_history | length' clusters/test02/status.json
  [ "$output" = "1" ]

  run jq -r '.phase_history[0].phase' clusters/test02/status.json
  [ "$output" = "provisioning_vpc" ]

  run jq -r '.phase_history[0].ok' clusters/test02/status.json
  [ "$output" = "true" ]
}

@test "update_phase: 拒絕無效 phase" {
  init_status "test03" "4.18.0-okd-scos.10" "ap-northeast-1" "ap-northeast-1c"
  run update_phase "test03" "invalid_phase"
  [ "$status" -ne 0 ]
}

@test "set_last_error: 寫入 last_error 並 append history" {
  init_status "test04" "4.18.0-okd-scos.10" "ap-northeast-1" "ap-northeast-1c"
  set_last_error "test04" "test error message"

  run jq -r '.last_error.message' clusters/test04/status.json
  [ "$output" = "test error message" ]

  run jq -r '.phase_history[-1].ok' clusters/test04/status.json
  [ "$output" = "false" ]
}

@test "get_cluster_version: 讀回鎖定版本" {
  mkdir -p clusters/test05
  echo "4.18.0-okd-scos.10" >clusters/test05/version

  run get_cluster_version "test05"
  [ "$output" = "4.18.0-okd-scos.10" ]
}

@test "get_cluster_version: 缺檔時失敗" {
  run get_cluster_version "nonexistent_cluster"
  [ "$status" -ne 0 ]
}

@test "tools_dir: 工具齊全時回傳路徑" {
  mkdir -p bin/4.18.0-okd-scos.10
  for t in openshift-install ccoctl oc; do
    echo "#!/bin/sh" >"bin/4.18.0-okd-scos.10/$t"
    chmod +x "bin/4.18.0-okd-scos.10/$t"
  done

  run tools_dir "4.18.0-okd-scos.10"
  [[ "$output" == *"bin/4.18.0-okd-scos.10" ]]
}

@test "tools_dir: 工具缺失時失敗" {
  mkdir -p bin/missing-version
  run tools_dir "missing-version"
  [ "$status" -ne 0 ]
}

@test "DRY_RUN: run_cmd 在 dry-run 模式不執行" {
  DRY_RUN=true
  TARGET="$TMPDIR_TEST/should_not_exist"
  run_cmd touch "$TARGET" 2>/dev/null || true
  [ ! -f "$TARGET" ]
}

# Regression: parse_dry_run_flag 之前被包在 < <(...) process substitution
# 裡呼叫，子 shell 設的 DRY_RUN 出不來 parent。改成寫 global PARSED_ARGS
# 後必須在 caller shell 直接呼叫；以下測試鎖住這個契約。
@test "parse_dry_run_flag: --dry-run 在 args 內時設 DRY_RUN=true" {
  DRY_RUN=false
  parse_dry_run_flag --dry-run
  [ "$DRY_RUN" = "true" ]
}

@test "parse_dry_run_flag: --dry-run 從 PARSED_ARGS 內被濾掉，其他 args 保留順序" {
  parse_dry_run_flag --cluster dev01 --dry-run --version 4.18
  [ "${#PARSED_ARGS[@]}" -eq 4 ]
  [ "${PARSED_ARGS[0]}" = "--cluster" ]
  [ "${PARSED_ARGS[1]}" = "dev01" ]
  [ "${PARSED_ARGS[2]}" = "--version" ]
  [ "${PARSED_ARGS[3]}" = "4.18" ]
}

@test "parse_dry_run_flag: 沒 --dry-run 時 DRY_RUN 保持原值" {
  DRY_RUN=false
  parse_dry_run_flag --cluster dev01
  [ "$DRY_RUN" = "false" ]
  [ "${#PARSED_ARGS[@]}" -eq 2 ]
}

@test "parse_dry_run_flag: 重複呼叫會清空 PARSED_ARGS (不會累加)" {
  parse_dry_run_flag --foo --bar
  [ "${#PARSED_ARGS[@]}" -eq 2 ]
  parse_dry_run_flag --baz
  [ "${#PARSED_ARGS[@]}" -eq 1 ]
  [ "${PARSED_ARGS[0]}" = "--baz" ]
}

@test "parse_dry_run_flag: 在 subshell 呼叫時 DRY_RUN 不會洩漏到 parent (記錄已知限制)" {
  DRY_RUN=false
  ( parse_dry_run_flag --dry-run )    # 故意包在 subshell
  [ "$DRY_RUN" = "false" ]            # parent 不受影響 — 這是契約
}
