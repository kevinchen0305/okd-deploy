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
  local args=()
  mapfile -t args < <(parse_dry_run_flag "$@")
  set -- "${args[@]+"${args[@]}"}"

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
    log_info "[$cluster] terraform destroy in $tfdir"
    if ! run_cmd terraform -chdir="$tfdir" destroy -auto-approve; then
      log_warn "[$cluster] terraform destroy failed — manual cleanup may be needed"
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

# Delete IAM roles named <cluster>-*, OIDC providers tagged with cluster,
# S3 buckets named <cluster>-oidc / <cluster>-* prefix-matched.
# All deletions tolerate not-found.
cleanup_ccoctl_resources() {
  local cluster="$1"

  log_info "[$cluster] cleanup ccoctl IAM roles ($cluster-*)"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] aws iam list-roles | filter '${cluster}-*' | aws iam delete-role"
  else
    local roles role
    roles="$(aws iam list-roles \
        --query "Roles[?starts_with(RoleName, \`${cluster}-\`)].RoleName" \
        --output text 2>/dev/null || true)"
    for role in $roles; do
      [[ -n "$role" ]] || continue
      log_info "[$cluster] deleting IAM role $role"
      # Detach managed policies, delete inline policies, then the role.
      local pol pa pas
      pas="$(aws iam list-attached-role-policies --role-name "$role" \
          --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)"
      for pa in $pas; do
        [[ -n "$pa" ]] || continue
        aws iam detach-role-policy --role-name "$role" --policy-arn "$pa" >/dev/null 2>&1 || true
      done
      local inlines
      inlines="$(aws iam list-role-policies --role-name "$role" \
          --query 'PolicyNames[]' --output text 2>/dev/null || true)"
      for pol in $inlines; do
        [[ -n "$pol" ]] || continue
        aws iam delete-role-policy --role-name "$role" --policy-name "$pol" >/dev/null 2>&1 || true
      done
      aws iam delete-role --role-name "$role" >/dev/null 2>&1 || \
        log_warn "[$cluster] delete-role $role failed (may already be gone)"
    done
  fi

  log_info "[$cluster] cleanup OIDC provider"
  local cf_id="" oidc_arn=""
  if [[ "$DRY_RUN" != "true" ]]; then
    if [[ -f "$(cluster_status "$cluster")" ]]; then
      cf_id="$(jq -r '.oidc_cloudfront // ""' "$(cluster_status "$cluster")")"
    fi
    local arns arn
    arns="$(aws iam list-open-id-connect-providers \
        --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null || true)"
    for arn in $arns; do
      [[ -n "$arn" ]] || continue
      if [[ -n "$cf_id" && "$arn" == *"${cf_id}.cloudfront.net" ]]; then
        oidc_arn="$arn"
        break
      fi
    done
    if [[ -n "$oidc_arn" ]]; then
      log_info "[$cluster] deleting OIDC provider $oidc_arn"
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" \
        >/dev/null 2>&1 || log_warn "[$cluster] delete-open-id-connect-provider failed"
    else
      log_info "[$cluster] no matching OIDC provider found (cf_id=${cf_id:-<unknown>})"
    fi
  else
    log_info "[DRY-RUN] aws iam delete-open-id-connect-provider (matched by cluster's cloudfront id)"
  fi

  log_info "[$cluster] cleanup S3 buckets prefixed ${cluster}-"
  if [[ "$DRY_RUN" != "true" ]]; then
    local buckets b
    buckets="$(aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, \`${cluster}-\`)].Name" \
        --output text 2>/dev/null || true)"
    for b in $buckets; do
      [[ -n "$b" ]] || continue
      log_info "[$cluster] removing S3 bucket s3://$b"
      aws s3 rb "s3://$b" --force >/dev/null 2>&1 || \
        log_warn "[$cluster] rb s3://$b failed"
    done
  else
    log_info "[DRY-RUN] aws s3 rb (cluster-prefixed buckets)"
  fi
}

main "$@"
