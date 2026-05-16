#!/usr/bin/env bash
# tools-version.sh — Helper to print which tool versions are installed
# locally and/or which version a given cluster is locked to.
#
# Usage:
#   scripts/tools-version.sh                    # list all bin/<v>/ dirs
#   scripts/tools-version.sh --cluster dev01    # print that cluster's locked version
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--cluster <name>] [--dry-run]

Without args:    lists every bin/<version>/ directory and which of
                 (openshift-install, ccoctl, oc) it has.
With --cluster:  prints the version recorded in clusters/<name>/version.
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

  if [[ -n "$cluster" ]]; then
    local v
    if v="$(get_cluster_version "$cluster")"; then
      printf '%s\n' "$v"
      exit 0
    else
      exit 1
    fi
  fi

  if [[ ! -d "$BIN_DIR" ]]; then
    log_warn "$BIN_DIR does not exist — no tools installed"
    exit 0
  fi

  local found=0
  local d
  for d in "$BIN_DIR"/*/; do
    [[ -d "$d" ]] || continue
    found=1
    local version="${d%/}"
    version="${version##*/}"
    local present=()
    local missing=()
    local t
    for t in openshift-install ccoctl oc; do
      if [[ -x "$d$t" ]]; then
        present+=("$t")
      else
        missing+=("$t")
      fi
    done
    local mark="[OK] "
    (( ${#missing[@]} == 0 )) || mark="[INC]"
    printf '%s %-40s present=%s missing=%s\n' \
      "$mark" "$version" \
      "${present[*]:-none}" \
      "${missing[*]:-none}"
  done

  if (( found == 0 )); then
    log_warn "No tool versions found under $BIN_DIR"
    exit 0
  fi

  # Also list which clusters reference each version.
  if [[ -d "$CLUSTERS_DIR" ]]; then
    printf '\n--- clusters → version ---\n'
    local c name v
    for c in "$CLUSTERS_DIR"/*/; do
      [[ -d "$c" ]] || continue
      name="${c%/}"
      name="${name##*/}"
      if v="$(cat "$c/version" 2>/dev/null)" && [[ -n "$v" ]]; then
        printf '  %-30s %s\n' "$name" "$v"
      else
        printf '  %-30s %s\n' "$name" "(no version file)"
      fi
    done
  fi
}

main "$@"
