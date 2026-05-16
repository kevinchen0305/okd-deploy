#!/usr/bin/env bash
# 共用函式 — 由其他 scripts/*.sh source 進來
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

set -euo pipefail

# ──────────────────────────────────────────────────────────
# 路徑常數
# ──────────────────────────────────────────────────────────
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
CLUSTERS_DIR="$REPO_ROOT/clusters"
BIN_DIR="$REPO_ROOT/bin"
TEMPLATES_DIR="$REPO_ROOT/templates"
MODULES_DIR="$REPO_ROOT/modules"
PLAYBOOKS_DIR="$REPO_ROOT/docs/playbooks"

# ──────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────
log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" >&2; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*" >&2; }

# ──────────────────────────────────────────────────────────
# Cluster 路徑工具
# ──────────────────────────────────────────────────────────
cluster_dir()        { printf '%s/%s' "$CLUSTERS_DIR" "$1"; }
cluster_status()     { printf '%s/%s/status.json' "$CLUSTERS_DIR" "$1"; }
cluster_version()    { printf '%s/%s/version' "$CLUSTERS_DIR" "$1"; }
cluster_terraform()  { printf '%s/%s/terraform' "$CLUSTERS_DIR" "$1"; }
cluster_kubeconfig() { printf '%s/%s/auth/kubeconfig' "$CLUSTERS_DIR" "$1"; }

# 讀某集群的 OKD 版本（spec 要求：所有腳本依此挑工具）
get_cluster_version() {
  local cluster="$1"
  local v_file
  v_file="$(cluster_version "$cluster")"
  if [[ ! -f "$v_file" ]]; then
    log_error "找不到 $v_file — 集群 $cluster 未鎖定版本"
    return 1
  fi
  cat "$v_file"
}

# 取某版本對應的 bin 目錄；若工具缺失則 fail
tools_dir() {
  local version="$1"
  local dir="$BIN_DIR/$version"
  if [[ ! -d "$dir" ]]; then
    log_error "工具版本目錄不存在：$dir — 請先跑 scripts/install-tools.sh $version"
    return 1
  fi
  for tool in openshift-install ccoctl oc; do
    if [[ ! -x "$dir/$tool" ]]; then
      log_error "工具 $dir/$tool 不存在或不可執行"
      return 1
    fi
  done
  printf '%s' "$dir"
}

# ──────────────────────────────────────────────────────────
# Status.json 操作
# ──────────────────────────────────────────────────────────
# 嚴格列舉 phase
declare -ag VALID_PHASES=(
  pending
  provisioning_vpc
  getting_creds
  setting_up_iam
  rendering_config
  patching_manifests
  installing
  verifying
  ready
  tearing_down
  destroyed
)

is_valid_phase() {
  local p="$1"
  for valid in "${VALID_PHASES[@]}"; do
    [[ "$p" == "$valid" ]] && return 0
  done
  return 1
}

# 初始化 status.json — 在建立集群目錄時呼叫
init_status() {
  local cluster="$1" version="$2" region="$3" az="$4"
  local s
  s="$(cluster_status "$cluster")"
  mkdir -p "$(dirname "$s")"
  cat >"$s" <<EOF
{
  "cluster_name": "$cluster",
  "okd_version": "$version",
  "region": "$region",
  "az": "$az",
  "phase": "pending",
  "phase_history": [],
  "vpc_id": null,
  "subnet_ids": {},
  "console_url": null,
  "verify_summary": {},
  "last_error": null
}
EOF
}

# 更新 phase 與 history
update_phase() {
  local cluster="$1" new_phase="$2"
  if ! is_valid_phase "$new_phase"; then
    log_error "Invalid phase: $new_phase"
    return 1
  fi
  local s ts
  s="$(cluster_status "$cluster")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp
  tmp="$(mktemp)"
  jq --arg p "$new_phase" --arg ts "$ts" '
    .phase = $p
    | .phase_history += [{phase: $p, at: $ts, ok: true}]
  ' "$s" >"$tmp" && mv "$tmp" "$s"
  log_info "[$cluster] phase → $new_phase"
}

set_last_error() {
  local cluster="$1" err="$2"
  local s ts
  s="$(cluster_status "$cluster")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp
  tmp="$(mktemp)"
  jq --arg e "$err" --arg ts "$ts" '
    .last_error = {message: $e, at: $ts}
    | .phase_history += [{phase: .phase, at: $ts, ok: false, error: $e}]
  ' "$s" >"$tmp" && mv "$tmp" "$s"
}

# 在 status.json 設任意欄位（jq 路徑語法）
set_status_field() {
  local cluster="$1" jq_path="$2" value="$3"
  local s tmp
  s="$(cluster_status "$cluster")"
  tmp="$(mktemp)"
  jq --argjson v "$value" "$jq_path = \$v" "$s" >"$tmp" && mv "$tmp" "$s"
}

# ──────────────────────────────────────────────────────────
# 失敗即 invoke diagnose
# ──────────────────────────────────────────────────────────
fail_with_diagnose() {
  local cluster="$1" err="$2"
  set_last_error "$cluster" "$err"
  log_error "$err"
  log_warn "建議跑 /okd-diagnose $cluster 查找原因"
  return 1
}

# ──────────────────────────────────────────────────────────
# Dry-run 支援
# ──────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# 解析共用 --dry-run 旗標。設定全域 DRY_RUN，並把剩餘 args 寫入全域
# PARSED_ARGS 陣列。必須在 caller 的 shell 直接呼叫 (不要包在 process
# substitution / command substitution 裡)，否則 DRY_RUN 出不來。
#
# 用法：
#   parse_dry_run_flag "$@"
#   set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"
parse_dry_run_flag() {
  PARSED_ARGS=()
  local a
  for a in "$@"; do
    if [[ "$a" == "--dry-run" ]]; then
      DRY_RUN=true
      export DRY_RUN
    else
      PARSED_ARGS+=("$a")
    fi
  done
}

# ──────────────────────────────────────────────────────────
# 依賴檢查
# ──────────────────────────────────────────────────────────
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      log_error "缺少必要指令：$c"
      return 1
    }
  done
}
