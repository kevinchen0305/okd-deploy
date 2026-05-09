#!/usr/bin/env bash
# tf-check.sh — fmt + init (no backend) + validate against modules/vpc/
# Usage: scripts/tf-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

MODULE_DIR="${MODULES_DIR}/vpc"

main() {
  require_cmd terraform

  if [[ ! -d "${MODULE_DIR}" ]]; then
    log_error "Terraform module directory not found: ${MODULE_DIR}"
    return 1
  fi

  log_info "Checking Terraform module: ${MODULE_DIR}"

  log_info "Step 1/3: terraform fmt -check"
  if ! terraform -chdir="${MODULE_DIR}" fmt -check -recursive; then
    log_error "terraform fmt -check failed — run 'terraform fmt -recursive ${MODULE_DIR}' to fix."
    return 1
  fi
  log_ok "fmt clean"

  log_info "Step 2/3: terraform init -backend=false"
  if ! terraform -chdir="${MODULE_DIR}" init -backend=false -input=false -no-color; then
    log_error "terraform init failed in ${MODULE_DIR}"
    return 1
  fi
  log_ok "init done"

  log_info "Step 3/3: terraform validate"
  if ! terraform -chdir="${MODULE_DIR}" validate -no-color; then
    log_error "terraform validate failed in ${MODULE_DIR}"
    return 1
  fi
  log_ok "validate clean"

  log_ok "All checks passed for ${MODULE_DIR}"
}

main "$@"
