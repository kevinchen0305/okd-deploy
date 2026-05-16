#!/usr/bin/env bash
# render-config.sh — Render install-config.yaml from templates/install-config.yaml.tmpl
# using envsubst, then validate the output with yq.
#
# Required env: BASE_DOMAIN AMI_ID REGION AZ SUBNET_PUBLIC SUBNET_PRIVATE
#               VPC_CIDR PULL_SECRET SSH_KEY (path to public key file)
#
# Optional env (defaults): ARCH=amd64 WORKER_INSTANCE_TYPE=m5.4xlarge
#               MASTER_INSTANCE_TYPE=m5.2xlarge WORKER_REPLICAS=2 MASTER_REPLICAS=1
#               OWNER_TAG=lab_kevin PURPOSE_TAG=cafe_okd
#
# Usage:
#   scripts/render-config.sh --cluster dev01 [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> [--dry-run]

Required env vars:
  BASE_DOMAIN AMI_ID REGION AZ SUBNET_PUBLIC SUBNET_PRIVATE
  VPC_CIDR PULL_SECRET SSH_KEY (path to public key)

Optional (defaults):
  ARCH=amd64 WORKER_INSTANCE_TYPE=m5.4xlarge MASTER_INSTANCE_TYPE=m5.2xlarge
  WORKER_REPLICAS=2 MASTER_REPLICAS=1 OWNER_TAG=lab_kevin PURPOSE_TAG=cafe_okd
EOF
  exit 2
}

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local cluster=""
  while (($# > 0)); do
    case "$1" in
      --cluster) cluster="${2:?}"; shift 2 ;;
      -h|--help) usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done
  [[ -n "$cluster" ]] || { log_error "--cluster is required"; usage; }

  require_cmd envsubst yq

  # Required env vars.
  local v
  for v in BASE_DOMAIN AMI_ID REGION AZ SUBNET_PUBLIC SUBNET_PRIVATE VPC_CIDR PULL_SECRET SSH_KEY; do
    if [[ -z "${!v:-}" ]]; then
      log_error "Required env var $v is not set"
      exit 1
    fi
  done

  # Optional defaults.
  : "${ARCH:=amd64}"
  : "${WORKER_INSTANCE_TYPE:=m5.4xlarge}"
  : "${MASTER_INSTANCE_TYPE:=m5.2xlarge}"
  : "${WORKER_REPLICAS:=2}"
  : "${MASTER_REPLICAS:=1}"
  : "${OWNER_TAG:=lab_kevin}"
  : "${PURPOSE_TAG:=cafe_okd}"

  # Read SSH public key file content.
  [[ -r "$SSH_KEY" ]] || { log_error "SSH_KEY file not readable: $SSH_KEY"; exit 1; }
  local ssh_key_content
  ssh_key_content="$(tr -d '\n' <"$SSH_KEY")"
  [[ -n "$ssh_key_content" ]] || { log_error "SSH_KEY file empty: $SSH_KEY"; exit 1; }

  local cdir tmpl out
  cdir="$(cluster_dir "$cluster")"
  tmpl="$TEMPLATES_DIR/install-config.yaml.tmpl"
  out="$cdir/install-config.yaml"

  [[ -f "$tmpl" ]] || { log_error "Template missing: $tmpl"; exit 1; }
  mkdir -p "$cdir"

  update_phase "$cluster" "rendering_config"

  # Export everything envsubst will substitute.
  export CLUSTER_NAME="$cluster"
  export BASE_DOMAIN AMI_ID REGION AZ SUBNET_PUBLIC SUBNET_PRIVATE VPC_CIDR
  export PULL_SECRET ARCH WORKER_INSTANCE_TYPE MASTER_INSTANCE_TYPE
  export WORKER_REPLICAS MASTER_REPLICAS OWNER_TAG PURPOSE_TAG
  export SSH_KEY="$ssh_key_content"   # template uses ${SSH_KEY} as content, not path

  log_info "[$cluster] rendering $tmpl → $out"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] envsubst < $tmpl > $out"
  else
    # Restrict envsubst to the variables we actually use, so $-prefixed strings
    # in pull secrets / keys don't get mangled. Single-quoted on purpose:
    # envsubst wants the literal "${VAR}" tokens, not their bash-expanded values.
    # shellcheck disable=SC2016
    local -r vars='${CLUSTER_NAME} ${BASE_DOMAIN} ${AMI_ID} ${REGION} ${AZ} ${SUBNET_PUBLIC} ${SUBNET_PRIVATE} ${VPC_CIDR} ${PULL_SECRET} ${ARCH} ${WORKER_INSTANCE_TYPE} ${MASTER_INSTANCE_TYPE} ${WORKER_REPLICAS} ${MASTER_REPLICAS} ${OWNER_TAG} ${PURPOSE_TAG} ${SSH_KEY}'
    envsubst "$vars" <"$tmpl" >"$out.tmp"
    mv "$out.tmp" "$out"
  fi

  # Validate YAML parses.
  if [[ "$DRY_RUN" != "true" ]]; then
    if ! yq eval '.' "$out" >/dev/null 2>&1; then
      fail_with_diagnose "$cluster" "Rendered $out is not valid YAML"
    fi
    # Sanity: required keys present.
    local name region_out
    name="$(yq -r '.metadata.name' "$out")"
    region_out="$(yq -r '.platform.aws.region' "$out")"
    [[ "$name"       == "$cluster" ]] || fail_with_diagnose "$cluster" "Rendered metadata.name=$name (expected $cluster)"
    [[ "$region_out" == "$REGION"  ]] || fail_with_diagnose "$cluster" "Rendered region=$region_out (expected $REGION)"
  fi

  log_ok "[$cluster] install-config.yaml rendered"
}

main "$@"
