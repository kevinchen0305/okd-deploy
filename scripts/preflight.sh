#!/usr/bin/env bash
# preflight.sh — Read-only pre-build checks for one or more clusters.
# Verifies tools exist, STS is valid, names don't conflict, AMI exists,
# and AWS quota is sufficient for N clusters.
#
# Usage:
#   scripts/preflight.sh \
#     --clusters dev01,dev02 \
#     --version 4.18.0-okd-scos.10 \
#     --region ap-northeast-1 \
#     [--worker-replicas N] [--json] [--dry-run]
#
# --worker-replicas defaults to env WORKER_REPLICAS or 2. Drives the EIP
# quota check: each cluster needs (1 NAT + N worker) EIPs.
#
# Exit: 0 = all pass, 2 = preflight failure, 1 = generic error.
# IMPORTANT: this script never modifies AWS state nor creates clusters/<name>/.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --clusters <n1,n2,...> --version <v> --region <r> [--json] [--dry-run]

Reads env AMI_ID for AMI existence check (optional but recommended).
Read-only: never modifies AWS state or filesystem under clusters/.
EOF
  exit 2
}

# ────────────────────────────────────────────────────
# Globals (mutated by check_*).
# ────────────────────────────────────────────────────
REPORT_TMP=""

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local clusters_csv="" version="" region=""
  local json_out=false
  local worker_replicas="${WORKER_REPLICAS:-2}"
  while (($# > 0)); do
    case "$1" in
      --clusters)        clusters_csv="${2:?}";    shift 2 ;;
      --version)         version="${2:?}";         shift 2 ;;
      --region)          region="${2:?}";          shift 2 ;;
      --worker-replicas) worker_replicas="${2:?}"; shift 2 ;;
      --json)            json_out=true;            shift   ;;
      -h|--help)         usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done
  [[ -n "$clusters_csv" && -n "$version" && -n "$region" ]] || \
    { log_error "--clusters, --version, --region all required"; usage; }
  [[ "$worker_replicas" =~ ^[0-9]+$ ]] || \
    { log_error "--worker-replicas must be a non-negative integer (got: $worker_replicas)"; exit 1; }

  require_cmd aws jq

  local -a clusters=()
  IFS=',' read -ra clusters <<<"$clusters_csv"
  local n=${#clusters[@]}
  (( n > 0 )) || { log_error "Empty --clusters list"; exit 1; }

  REPORT_TMP="$(mktemp)"
  jq -n --arg v "$version" --arg r "$region" --argjson cs "$(printf '%s\n' "${clusters[@]}" | jq -R . | jq -s .)" '
    {
      version: $v,
      region: $r,
      clusters: $cs,
      checks: [],
      all_passed: false
    }
  ' >"$REPORT_TMP"

  # Run checks.
  check_tools     "$version"
  check_sts
  check_name_conflicts "${clusters[@]}"
  check_ami       "$region"
  check_account_consistency
  check_quotas    "$region" "$n" "$worker_replicas"

  # Compute final pass/fail.
  local fails warns
  fails="$(jq '[.checks[] | select(.status=="fail")] | length' "$REPORT_TMP")"
  warns="$(jq '[.checks[] | select(.status=="warn")] | length' "$REPORT_TMP")"
  local passed=false
  [[ "$fails" == "0" ]] && passed=true
  jq --argjson p "$passed" '.all_passed = $p' "$REPORT_TMP" >"${REPORT_TMP}.x" && \
    mv "${REPORT_TMP}.x" "$REPORT_TMP"

  print_summary "$json_out"
  rm -f "$REPORT_TMP"

  if [[ "$passed" == "true" ]]; then
    log_ok "preflight passed (warnings=$warns)"
    exit 0
  else
    log_error "preflight failed (failures=$fails warnings=$warns)"
    exit 2
  fi
}

# Append one check entry to the report.
add_check() {
  local name="$1" status="$2" detail="${3:-}" suggestion="${4:-}"
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --arg d "$detail" --arg sg "$suggestion" '
    .checks += [{name:$n, status:$s, detail:$d, suggestion:$sg}]
  ' "$REPORT_TMP" >"$tmp" && mv "$tmp" "$REPORT_TMP"
}

# ────────────────────────────────────────────────────
# Check: tool binaries.
# ────────────────────────────────────────────────────
check_tools() {
  local version="$1"
  local dir="$BIN_DIR/$version"
  local missing=()
  local t
  for t in openshift-install ccoctl oc; do
    [[ -x "$dir/$t" ]] || missing+=("$t")
  done
  if (( ${#missing[@]} == 0 )); then
    add_check tools_installed ok "$dir has openshift-install/ccoctl/oc" ""
  else
    add_check tools_installed fail \
      "missing in $dir: ${missing[*]}" \
      "scripts/install-tools.sh --version $version"
  fi
}

# ────────────────────────────────────────────────────
# Check: STS valid + remaining lifetime.
# ────────────────────────────────────────────────────
check_sts() {
  local out
  if ! out="$(aws sts get-caller-identity --output json 2>&1)"; then
    add_check sts_valid fail \
      "aws sts get-caller-identity failed: ${out//$'\n'/ }" \
      "Re-run scripts/sts-creds.sh and 'source' the output file"
    return 0
  fi
  local arn
  arn="$(jq -r '.Arn' <<<"$out")"

  if [[ -n "${AWS_STS_EXPIRATION:-}" ]]; then
    local now_epoch exp_epoch remaining
    now_epoch="$(date -u +%s)"
    if exp_epoch="$(date -u -d "$AWS_STS_EXPIRATION" +%s 2>/dev/null)" || \
       exp_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "${AWS_STS_EXPIRATION/Z/+0000}" +%s 2>/dev/null)"; then
      remaining=$(( exp_epoch - now_epoch ))
      if (( remaining < 3600 )); then
        add_check sts_valid warn \
          "STS valid (arn=$arn) but only $((remaining/60)) min left" \
          "Re-run scripts/sts-creds.sh to extend the session"
        return 0
      fi
    fi
  fi
  add_check sts_valid ok "arn=$arn" ""
}

# ────────────────────────────────────────────────────
# Check: cluster name conflicts.
# ────────────────────────────────────────────────────
check_name_conflicts() {
  local conflicts=()
  local c
  for c in "$@"; do
    if [[ -e "$CLUSTERS_DIR/$c" ]]; then
      conflicts+=("$c")
    fi
  done
  if (( ${#conflicts[@]} == 0 )); then
    add_check name_conflict ok "no clusters/$* directory exists" ""
  else
    add_check name_conflict fail \
      "name(s) already used: ${conflicts[*]}" \
      "Pick a different name or scripts/teardown.sh --cluster <name> --purge"
  fi
}

# ────────────────────────────────────────────────────
# Check: AMI exists in region.
# ────────────────────────────────────────────────────
check_ami() {
  local region="$1"
  if [[ -z "${AMI_ID:-}" ]]; then
    add_check ami_exists warn \
      "AMI_ID env not set; skipping AMI existence check" \
      "Export AMI_ID=ami-xxxx (the OKD-compatible Fedora CoreOS image for $region)"
    return 0
  fi
  local count
  count="$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$region" \
            --query 'length(Images)' --output text 2>/dev/null || echo "0")"
  if [[ "$count" == "1" ]]; then
    add_check ami_exists ok "$AMI_ID in $region" ""
  else
    add_check ami_exists fail \
      "AMI $AMI_ID not found in $region" \
      "Match playbook ami-not-found: pick a valid Fedora CoreOS AMI for the region"
  fi
}

# ────────────────────────────────────────────────────
# Check: account ID consistency (record current account).
# ────────────────────────────────────────────────────
check_account_consistency() {
  local acc
  acc="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  if [[ -z "$acc" || "$acc" == "None" ]]; then
    add_check account_consistency warn \
      "could not determine STS account id" \
      "Re-run sts-creds.sh"
    return 0
  fi
  # No install-config exists yet on first build; just record.
  add_check account_consistency ok "STS account=$acc (no install-config to compare against yet)" ""
}

# ────────────────────────────────────────────────────
# Check: AWS Service Quotas — VPC, EIP, NAT GW, m5 vCPUs.
#
# AWS Service Quotas codes (as of 2024-2025; if a code is rejected by your
# account/region, surface a warn rather than a hard fail so we don't block
# preflight on documentation drift):
#   service=vpc
#     L-F678F1CE  VPCs per Region
#     L-FE5A380F  NAT gateways per AZ
#   service=ec2
#     L-0263D0A3  EC2-VPC Elastic IPs
#     L-1216C47A  Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances (vCPUs)
# ────────────────────────────────────────────────────
check_quotas() {
  local region="$1" n="$2" worker_replicas="$3"

  # Per-cluster usage estimate.
  # Rough: 1 master m5.2xlarge (8 vCPU) + 2 worker m5.4xlarge (16 vCPU each = 32) + bootstrap (8) ≈ 48 vCPUs/cluster.
  # Net steady-state (post-bootstrap) ≈ 40, but use 48 to allow bootstrap overlap.
  # EIPs: 1 for NAT GW + one per worker (terraform pre-allocates them so
  #       attach-worker-eips.sh can associate after install).
  local need_vpcs=$n
  local need_eips=$(( n * (1 + worker_replicas) ))
  local need_nats=$n
  local need_vcpus=$(( n * 48 ))

  _check_quota_limit_usage \
    quota_vpcs vpc L-F678F1CE \
    "$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)" \
    "$need_vpcs" "VPCs"

  _check_quota_limit_usage \
    quota_nat_gws vpc L-FE5A380F \
    "$(aws ec2 describe-nat-gateways --region "$region" \
        --filter Name=state,Values=available,pending \
        --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)" \
    "$need_nats" "NAT gateways"

  _check_quota_limit_usage \
    quota_eips ec2 L-0263D0A3 \
    "$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)" \
    "$need_eips" "EIPs"

  _check_quota_limit_usage \
    quota_vcpus_m5 ec2 L-1216C47A \
    "0" \
    "$need_vcpus" "vCPUs (Standard On-Demand; current usage not enumerated)"
}

# Arg order: name service code current_usage need label
_check_quota_limit_usage() {
  local name="$1" service="$2" code="$3" current="$4" need="$5" label="$6"
  local quota_json limit
  quota_json="$(aws service-quotas get-service-quota \
      --service-code "$service" --quota-code "$code" 2>/dev/null || true)"

  if [[ -z "$quota_json" ]]; then
    add_check "$name" warn \
      "service-quotas $service/$code unavailable; skipping ($label)" \
      "Verify quota manually in AWS console for $label"
    return 0
  fi

  limit="$(jq -r '.Quota.Value // empty' <<<"$quota_json")"
  if [[ -z "$limit" ]]; then
    add_check "$name" warn "no Quota.Value returned for $service/$code" ""
    return 0
  fi

  # current may not be numeric (when usage couldn't be enumerated).
  local current_num=0
  [[ "$current" =~ ^[0-9]+$ ]] && current_num=$current
  local limit_int=${limit%.*}
  local remaining=$(( limit_int - current_num ))

  local detail
  detail="limit=$limit_int used=$current_num remaining=$remaining need=$need ($label)"

  if (( remaining >= need )); then
    add_check "$name" ok "$detail" ""
  else
    add_check "$name" fail "$detail" \
      "Either: (1) teardown idle clusters, (2) request quota increase for $service/$code, or (3) reduce concurrency"
  fi
}

# ────────────────────────────────────────────────────
# Output.
# ────────────────────────────────────────────────────
print_summary() {
  local json_out="$1"
  if [[ "$json_out" == "true" ]]; then
    jq '.' "$REPORT_TMP"
  fi
  printf '\n=== preflight summary ===\n' >&2
  jq -r '
    .checks[]
    | "  [" + (.status|ascii_upcase) + "] " + .name +
      (if .detail   != "" then ": " + .detail   else "" end) +
      (if .suggestion != "" then "\n      → " + .suggestion else "" end)
  ' "$REPORT_TMP" >&2
  printf '=========================\n' >&2
}

main "$@"
