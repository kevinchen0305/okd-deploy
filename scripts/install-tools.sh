#!/usr/bin/env bash
# install-tools.sh — Download openshift-install / ccoctl / oc tarballs from
# the okd-project GitHub release page into bin/<version>/.
#
# Usage:
#   scripts/install-tools.sh --version 4.18.0-okd-scos.10 [--force] [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --version <v> [--force] [--dry-run]

Downloads openshift-install, ccoctl, oc tarballs for the given OKD version
from https://github.com/okd-project/okd/releases/download/<v>/ into bin/<v>/.

Idempotent: re-running skips already-extracted tools unless --force.
EOF
  exit 2
}

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local version=""
  local force=false

  while (($# > 0)); do
    case "$1" in
      --version) version="${2:?--version requires a value}"; shift 2 ;;
      --force)   force=true; shift ;;
      -h|--help) usage ;;
      *)
        log_error "Unknown arg: $1"
        usage
        ;;
    esac
  done

  [[ -n "$version" ]] || { log_error "--version is required"; usage; }

  require_cmd curl tar uname

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ "$force" != "true" ]]; then
      log_error "macOS detected. okd-project releases ship linux binaries only."
      log_error "Re-run with --force to download anyway (binaries will not run on macOS)."
      exit 1
    fi
    log_warn "macOS detected; --force given. Downloading linux binaries — they will NOT run locally."
  fi

  local target_dir="$BIN_DIR/$version"
  mkdir -p "$target_dir"

  local base_url="https://github.com/okd-project/okd/releases/download/${version}"
  local -a tarballs=(
    "openshift-install-linux-${version}.tar.gz"
    "ccoctl-linux-${version}.tar.gz"
    "openshift-client-linux-${version}.tar.gz"
  )

  # Map tarball → primary binary we expect inside it (for idempotence + verify).
  local -a expected_binaries=(
    "openshift-install"
    "ccoctl"
    "oc"
  )

  local i
  for i in "${!tarballs[@]}"; do
    local tar="${tarballs[$i]}"
    local bin_name="${expected_binaries[$i]}"
    local bin_path="$target_dir/$bin_name"

    if [[ -x "$bin_path" && "$force" != "true" ]]; then
      log_info "$bin_name already present at $bin_path — skipping (use --force to redownload)"
      continue
    fi

    local url="${base_url}/${tar}"
    local tmp
    tmp="$(mktemp -d)"
    log_info "Downloading $url"
    if ! run_cmd curl -fL --progress-bar --retry 3 --retry-delay 2 -o "$tmp/$tar" "$url"; then
      rm -rf "$tmp"
      fail_download "$url"
    fi

    log_info "Extracting $tar → $target_dir"
    if [[ "$DRY_RUN" != "true" ]]; then
      tar -xzf "$tmp/$tar" -C "$target_dir"
    else
      log_info "[DRY-RUN] tar -xzf $tmp/$tar -C $target_dir"
    fi
    rm -rf "$tmp"

    if [[ "$DRY_RUN" != "true" ]]; then
      [[ -f "$bin_path" ]] || { log_error "Extracted tarball but $bin_path missing"; exit 1; }
      chmod +x "$bin_path"
    fi
  done

  # Verify each tool runs --version (skipped in dry-run because binaries may not exist).
  if [[ "$DRY_RUN" != "true" ]]; then
    local tool
    for tool in openshift-install ccoctl oc; do
      local p="$target_dir/$tool"
      [[ -x "$p" ]] || { log_error "$p missing or not executable"; exit 1; }
      if [[ "$(uname -s)" == "Darwin" ]]; then
        log_warn "Skipping $tool --version (macOS cannot run linux binaries)"
        continue
      fi
      log_info "Verifying: $p version"
      if ! "$p" version >/dev/null 2>&1 && ! "$p" --version >/dev/null 2>&1; then
        log_warn "$tool failed --version probe (non-fatal; binary present)"
      fi
    done
  fi

  log_ok "Tools for $version installed at $target_dir"
}

fail_download() {
  log_error "Download failed: $1"
  log_error "Hint: confirm the version tag exists at https://github.com/okd-project/okd/releases"
  exit 1
}

main "$@"
