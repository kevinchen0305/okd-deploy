#!/usr/bin/env bash
# attach-worker-eips.sh — Associate the EIPs pre-allocated by the VPC module
# (one per worker, var.worker_replicas) to the corresponding worker EC2
# instances after `openshift-install create cluster` finishes.
#
# Workers come up via the MachineSet controller after install completes;
# they get an auto-assigned public IP from the public subnet by default but
# that IP changes on stop/start. Associating a tagged EIP gives each worker
# a stable public address.
#
# Usage:
#   scripts/attach-worker-eips.sh --cluster <name> [--timeout 600] [--dry-run]
#
# Pre-conditions:
#   * Cluster install completed (auth/kubeconfig present).
#   * Worker MachineSet has, or will, reach desired replica count.
#   * Workers are in the public subnet (patch-machineset.sh already ran).
#
# Idempotent: pairs sorted(alloc_ids) with sorted(worker_instance_ids) and
# uses --allow-reassociation, so re-runs converge to the same mapping.
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> [--timeout SECONDS] [--dry-run]

  --timeout   How long to wait for workers to become Running (default 600s).
EOF
  exit 2
}

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local cluster=""
  local timeout=600
  while (($# > 0)); do
    case "$1" in
      --cluster) cluster="${2:?}"; shift 2 ;;
      --timeout) timeout="${2:?}"; shift 2 ;;
      -h|--help) usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done
  [[ -n "$cluster" ]] || { log_error "--cluster is required"; usage; }

  require_cmd aws jq terraform

  local cdir tfdir kc status_file region version tdir oc
  cdir="$(cluster_dir "$cluster")"
  tfdir="$(cluster_terraform "$cluster")"
  kc="$(cluster_kubeconfig "$cluster")"
  status_file="$(cluster_status "$cluster")"

  [[ -d "$tfdir" ]] || { log_error "Terraform dir missing: $tfdir"; exit 1; }
  [[ -f "$kc"    ]] || { log_error "kubeconfig missing: $kc";       exit 1; }

  region="$(jq -r '.region // empty' "$status_file")"
  [[ -n "$region" ]] || fail_with_diagnose "$cluster" "status.json missing .region"

  version="$(get_cluster_version "$cluster")"
  tdir="$(tools_dir "$version")"
  oc="$tdir/oc"

  # ────────────────────────────────────────────────────
  # 1. Pull the pre-allocated EIP allocation IDs from terraform state.
  # ────────────────────────────────────────────────────
  local alloc_json
  if [[ "$DRY_RUN" == "true" ]]; then
    alloc_json='["eipalloc-DRYRUN-0","eipalloc-DRYRUN-1"]'
  else
    alloc_json="$(terraform -chdir="$tfdir" output -json worker_eip_allocation_ids 2>/dev/null || echo '[]')"
  fi

  local n_alloc
  n_alloc="$(jq 'length' <<<"$alloc_json")"
  if (( n_alloc == 0 )); then
    log_warn "[$cluster] no worker EIPs in terraform output — nothing to attach"
    return 0
  fi

  local -a alloc_ids=()
  while IFS= read -r line; do
    alloc_ids+=("$line")
  done < <(jq -r '.[]' <<<"$alloc_json" | sort)
  log_info "[$cluster] $n_alloc worker EIP(s) pre-allocated: ${alloc_ids[*]}"

  # ────────────────────────────────────────────────────
  # 2. Poll worker MachineSet until N workers are Running.
  # ────────────────────────────────────────────────────
  local worker_iids_json="[]"
  local deadline=$(( $(date -u +%s) + timeout ))
  local now n_workers

  if [[ "$DRY_RUN" == "true" ]]; then
    worker_iids_json='["i-DRYRUN-0","i-DRYRUN-1"]'
    n_workers="$n_alloc"
    log_info "[DRY-RUN] would poll oc get machines until $n_alloc workers Running"
  else
    while :; do
      worker_iids_json="$(
        "$oc" --kubeconfig="$kc" -n openshift-machine-api get machines -o json 2>/dev/null \
        | jq -c '
            [ .items[]
              | select(.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == "worker")
              | select(.status.phase == "Running")
              | .status.providerStatus.instanceId
              | select(. != null and . != "")
            ]
          ' 2>/dev/null || echo '[]'
      )"
      n_workers="$(jq 'length' <<<"$worker_iids_json")"
      if (( n_workers >= n_alloc )); then
        break
      fi
      now="$(date -u +%s)"
      if (( now >= deadline )); then
        fail_with_diagnose "$cluster" \
          "timeout waiting for workers: have $n_workers Running, need $n_alloc (after ${timeout}s)"
      fi
      log_info "[$cluster] workers Running=$n_workers/$n_alloc — waiting (deadline in $(( deadline - now ))s)"
      sleep 20
    done
  fi

  local -a worker_iids=()
  while IFS= read -r line; do
    worker_iids+=("$line")
  done < <(jq -r '.[]' <<<"$worker_iids_json" | sort | head -n "$n_alloc")
  log_info "[$cluster] worker instance IDs: ${worker_iids[*]}"

  # ────────────────────────────────────────────────────
  # 3. Zip sorted(alloc_ids) with sorted(worker_iids) and associate.
  # ────────────────────────────────────────────────────
  local i assoc_json mapping_json='[]'
  for i in "${!alloc_ids[@]}"; do
    local aid="${alloc_ids[$i]}" iid="${worker_iids[$i]}"
    log_info "[$cluster] associate $aid → $iid"
    if [[ "$DRY_RUN" == "true" ]]; then
      assoc_json='{"AssociationId":"eipassoc-DRYRUN"}'
    else
      assoc_json="$(aws ec2 associate-address \
        --region "$region" \
        --instance-id "$iid" \
        --allocation-id "$aid" \
        --allow-reassociation \
        --output json 2>&1)" || \
        fail_with_diagnose "$cluster" "associate-address failed ($aid → $iid): $assoc_json"
    fi
    local assoc_id
    assoc_id="$(jq -r '.AssociationId // empty' <<<"$assoc_json" 2>/dev/null || echo "")"
    mapping_json="$(jq --arg a "$aid" --arg i "$iid" --arg s "$assoc_id" \
      '. += [{allocation_id:$a, instance_id:$i, association_id:$s}]' <<<"$mapping_json")"
  done

  # ────────────────────────────────────────────────────
  # 4. Record mapping into status.json.
  # ────────────────────────────────────────────────────
  if [[ "$DRY_RUN" != "true" ]]; then
    set_status_field "$cluster" '.worker_eips' "$mapping_json"
  fi
  log_ok "[$cluster] attached $n_alloc worker EIP(s)"
}

main "$@"
