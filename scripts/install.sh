#!/usr/bin/env bash
# install.sh — Run `openshift-install create cluster` for one cluster.
# Copies cco_manifests + credrequests into manifests/, then invokes the
# installer with full logging captured to .openshift_install.log.
#
# Usage:
#   scripts/install.sh --cluster dev01 [--dry-run]
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

  require_cmd jq

  local cdir version tdir
  cdir="$(cluster_dir "$cluster")"
  [[ -d "$cdir" ]] || { log_error "Cluster dir missing: $cdir"; exit 1; }
  version="$(get_cluster_version "$cluster")"
  tdir="$(tools_dir "$version")"

  pushd "$cdir" >/dev/null

  # Copy ccoctl outputs back into manifests/ — match build-okd.md exactly.
  # Note: legacy build-okd.md mentioned `cp cco_manifests/* manifests/`, but
  # current ccoctl (create-identity-provider + create-iam-roles) writes the
  # cluster-auth + 6 credential secret manifests directly into manifests/.
  # No cco_manifests/ dir is ever produced, so we no longer check for it.

  if [[ -d credrequests ]]; then
    # CredentialsRequest CR templates — STS Manual mode CCO uses them to
    # match against the Secrets ccoctl already created in manifests/.
    log_info "[$cluster] cp credrequests/* manifests/"
    if [[ "$DRY_RUN" != "true" ]]; then
      cp -r credrequests/. manifests/
    fi
  else
    log_warn "[$cluster] credrequests/ not found — assuming already merged"
  fi

  update_phase "$cluster" "installing"

  local log_file=".openshift_install.log"
  log_info "[$cluster] openshift-install create cluster (log: $cdir/$log_file)"

  set +e
  run_cmd "$tdir/openshift-install" --dir=. create cluster --log-level=info \
    >>"$log_file" 2>&1
  local rc=$?
  set -e

  if (( rc != 0 )); then
    popd >/dev/null
    fail_with_diagnose "$cluster" "openshift-install create cluster failed (rc=$rc); see $cdir/$log_file"
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    [[ -f auth/kubeadmin-password ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "auth/kubeadmin-password missing"; }
    [[ -f auth/kubeconfig         ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "auth/kubeconfig missing"; }

    # Capture console URL — installer prints it on the final line.
    local console_url
    # Exclude quotes: installer logs the URL twice (plain + timestamped form);
    # the timestamped form ends with `"` which would land inside the captured
    # URL and break the JSON we hand to set_status_field.
    console_url="$(grep -Eo 'https://console-openshift-console\.apps\.[^ "]+' "$log_file" | tail -n1 || true)"
    if [[ -n "$console_url" ]]; then
      popd >/dev/null
      set_status_field "$cluster" '.console_url' "\"$console_url\""
      log_info "[$cluster] console_url=$console_url"
    else
      log_warn "[$cluster] could not parse console URL from $log_file"
      popd >/dev/null
    fi
  else
    popd >/dev/null
  fi

  log_ok "[$cluster] cluster install completed (phase remains 'installing' until verify.sh)"
}

main "$@"
