#!/usr/bin/env bash
# patch-machineset.sh — Replace the worker MachineSet's subnet reference so
# workers land in the public subnet instead of the private one (matches the
# manual `vi openshift/99_openshift-cluster-api_worker-machineset-0.yaml`
# step in build-okd.md).
#
# Usage:
#   scripts/patch-machineset.sh --cluster dev01 [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> [--dry-run]
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

  require_cmd terraform yq

  local cdir tdir machineset
  cdir="$(cluster_dir "$cluster")"
  tdir="$(cluster_terraform "$cluster")"
  machineset="$cdir/openshift/99_openshift-cluster-api_worker-machineset-0.yaml"

  [[ -d "$tdir"      ]] || { log_error "Terraform dir missing: $tdir";        exit 1; }
  [[ -f "$machineset" ]] || { log_error "MachineSet manifest missing: $machineset"; exit 1; }

  update_phase "$cluster" "patching_manifests"

  # Read subnet ids from terraform outputs.
  local public_id="" private_id=""
  if [[ "$DRY_RUN" == "true" ]]; then
    public_id="subnet-PUBLIC-DRYRUN"
    private_id="subnet-PRIVATE-DRYRUN"
    log_info "[DRY-RUN] using placeholder subnet ids"
  else
    public_id="$(terraform -chdir="$tdir" output -raw public_subnet_id 2>/dev/null || true)"
    private_id="$(terraform -chdir="$tdir" output -raw private_subnet_id 2>/dev/null || true)"
  fi
  [[ -n "$public_id"  ]] || fail_with_diagnose "$cluster" "terraform output public_subnet_id is empty"
  [[ -n "$private_id" ]] || fail_with_diagnose "$cluster" "terraform output private_subnet_id is empty"
  log_info "[$cluster] public_subnet=$public_id private_subnet=$private_id"

  # Inspect current value. The exact YAML path is providerSpec.value.subnet.id
  # (kept as `.id`) under the worker machineset's pod template.
  local jq_path='.spec.template.spec.providerSpec.value.subnet.id'
  local current=""
  if [[ "$DRY_RUN" != "true" ]]; then
    current="$(yq eval "$jq_path // \"\"" "$machineset")"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] yq -i \"$jq_path = \\\"$public_id\\\"\" $machineset"
  elif [[ -z "$current" ]]; then
    # Maybe the manifest uses a filters[] entry instead of an id; try filters path.
    local filters
    filters="$(yq eval '.spec.template.spec.providerSpec.value.subnet.filters // []' "$machineset")"
    if [[ "$filters" != "[]" && -n "$filters" ]]; then
      log_warn "[$cluster] MachineSet uses subnet.filters (no .id); skipping replacement (no-op)"
    else
      fail_with_diagnose "$cluster" "Could not locate subnet.id in $machineset"
    fi
  elif [[ "$current" == "$private_id" ]]; then
    log_info "[$cluster] replacing subnet.id $private_id → $public_id"
    yq eval -i "$jq_path = \"$public_id\"" "$machineset"
  elif [[ "$current" == "$public_id" ]]; then
    log_info "[$cluster] subnet.id already public ($public_id) — no change"
  else
    log_warn "[$cluster] subnet.id is $current (neither public nor private terraform output) — leaving as-is"
  fi

  log_ok "[$cluster] machineset patch complete"
}

main "$@"
