#!/usr/bin/env bash
# teardown.sh — Tear down a cluster's AWS resources in the right order
# based on the current phase. Cleans installer-created assets, terraform-
# managed VPC, and ccoctl-created IAM/S3/OIDC objects.
#
# Usage:
#   scripts/teardown.sh --cluster dev01 [--purge] [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> [--purge] [--dry-run]

  --purge   After teardown, rm -rf clusters/<name>/
EOF
  exit 2
}

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local cluster=""
  local purge=false
  while (($# > 0)); do
    case "$1" in
      --cluster) cluster="${2:?}"; shift 2 ;;
      --purge)   purge=true;       shift   ;;
      -h|--help) usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done
  [[ -n "$cluster" ]] || { log_error "--cluster is required"; usage; }

  require_cmd jq aws terraform

  local cdir status_file
  cdir="$(cluster_dir "$cluster")"
  status_file="$(cluster_status "$cluster")"

  if [[ ! -d "$cdir" ]]; then
    log_warn "[$cluster] cluster dir $cdir does not exist — nothing to tear down"
    return 0
  fi

  # Read CURRENT phase before transitioning.
  local current_phase="unknown"
  if [[ -f "$status_file" ]]; then
    current_phase="$(jq -r '.phase // "unknown"' "$status_file")"
  fi
  log_info "[$cluster] starting teardown from phase=$current_phase"

  update_phase "$cluster" "tearing_down"

  local version="" tdir=""
  if version="$(get_cluster_version "$cluster" 2>/dev/null)"; then
    tdir="$(tools_dir "$version" 2>/dev/null || true)"
  fi

  # ────────────────────────────────────────────────────
  # Layer 1: installer-created resources (only if installer ran).
  # ────────────────────────────────────────────────────
  case "$current_phase" in
    installing|verifying|ready|tearing_down)
      if [[ -n "$tdir" && -x "$tdir/openshift-install" ]]; then
        log_info "[$cluster] openshift-install destroy cluster"
        if ! run_cmd "$tdir/openshift-install" --dir="$cdir" destroy cluster --log-level=info; then
          log_warn "[$cluster] openshift-install destroy returned non-zero — continuing with terraform/ccoctl cleanup"
        fi
      else
        log_warn "[$cluster] tools dir not available — skipping openshift-install destroy"
      fi
      ;;
    *)
      log_info "[$cluster] phase=$current_phase: skipping openshift-install destroy"
      ;;
  esac

  # ────────────────────────────────────────────────────
  # Layer 2: terraform destroy (always, idempotent).
  # ────────────────────────────────────────────────────
  local tfdir
  tfdir="$(cluster_terraform "$cluster")"
  if [[ -d "$tfdir" && -f "$tfdir/terraform.tfstate" ]]; then
    # terraform destroy needs the same -var inputs as apply; the VPC module
    # marks cluster_name/region/az as required and the AWS provider itself
    # needs AWS_REGION env. Pull both from status.json so callers don't have
    # to remember to re-export .env before teardown.
    local tf_region tf_az
    tf_region="$(jq -r '.region // empty' "$status_file" 2>/dev/null)"
    tf_az="$(jq -r '.az // empty' "$status_file" 2>/dev/null)"
    if [[ -z "$tf_region" || -z "$tf_az" ]]; then
      log_warn "[$cluster] status.json missing region/az — terraform destroy may fail"
    fi

    log_info "[$cluster] terraform destroy in $tfdir (region=$tf_region az=$tf_az)"
    if ! AWS_REGION="$tf_region" AWS_DEFAULT_REGION="$tf_region" \
         run_cmd terraform -chdir="$tfdir" destroy -auto-approve \
           -var "cluster_name=$cluster" \
           -var "region=$tf_region" \
           -var "az=$tf_az"; then
      log_warn "[$cluster] terraform destroy failed — manual cleanup may be needed (see docs/playbooks/teardown-guardduty-vpc-residue.md for the AWS-GuardDuty-injected-endpoint case)"
    fi
  else
    log_info "[$cluster] no terraform.tfstate — skipping terraform destroy"
  fi

  # ────────────────────────────────────────────────────
  # Layer 3: ccoctl-created resources (always, idempotent).
  # ────────────────────────────────────────────────────
  cleanup_ccoctl_resources "$cluster"

  update_phase "$cluster" "destroyed"
  log_ok "[$cluster] teardown complete"

  if [[ "$purge" == "true" ]]; then
    log_warn "[$cluster] --purge: removing $cdir"
    if [[ "$DRY_RUN" != "true" ]]; then
      rm -rf "$cdir"
    else
      log_info "[DRY-RUN] rm -rf $cdir"
    fi
  fi
}

# Delegate ccoctl-created resource cleanup (IAM roles, OIDC provider,
# S3 bucket, **and** CloudFront distribution) to ccoctl's own delete
# subcommand. ccoctl knows the full set of objects it created, including
# the CloudFront distribution that the previous manual cleanup missed.
cleanup_ccoctl_resources() {
  local cluster="$1"

  local version tdir
  if ! version="$(get_cluster_version "$cluster" 2>/dev/null)"; then
    log_warn "[$cluster] cluster version unknown — skipping ccoctl delete"
    return 0
  fi
  tdir="$(tools_dir "$version" 2>/dev/null || true)"
  if [[ -z "$tdir" || ! -x "$tdir/ccoctl" ]]; then
    log_warn "[$cluster] ccoctl not available in $tdir — skipping ccoctl delete"
    return 0
  fi

  local region
  region="$(jq -r '.region // empty' "$(cluster_status "$cluster")" 2>/dev/null || true)"
  if [[ -z "$region" ]]; then
    log_warn "[$cluster] region not in status.json — skipping ccoctl delete"
    return 0
  fi

  log_info "[$cluster] ccoctl aws delete --name=$cluster --region=$region"
  if ! run_cmd "$tdir/ccoctl" aws delete --name="$cluster" --region="$region"; then
    log_warn "[$cluster] ccoctl aws delete failed — manual cleanup may be needed (IAM roles, OIDC, S3, CloudFront)"
  fi
}

main "$@"
