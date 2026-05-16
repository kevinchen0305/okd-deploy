#!/usr/bin/env bash
# ccoctl-setup.sh — Run the ccoctl + oc adm release extract + IAM-roles
# pipeline for one cluster. Wraps the manual flow in build-okd.md.
#
# Usage:
#   scripts/ccoctl-setup.sh --cluster dev01 --region ap-northeast-1 [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> --region <region> [--dry-run]
EOF
  exit 2
}

main() {
  parse_dry_run_flag "$@"
  set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

  local cluster="" region=""
  while (($# > 0)); do
    case "$1" in
      --cluster) cluster="${2:?}"; shift 2 ;;
      --region)  region="${2:?}";  shift 2 ;;
      -h|--help) usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done

  [[ -n "$cluster" && -n "$region" ]] || { log_error "--cluster and --region required"; usage; }

  require_cmd aws jq sed mkdir awk

  local cdir version tdir
  cdir="$(cluster_dir "$cluster")"
  [[ -d "$cdir" ]] || { log_error "Cluster dir not found: $cdir — run preflight + render-config first"; exit 1; }

  version="$(get_cluster_version "$cluster")"
  tdir="$(tools_dir "$version")"
  log_info "[$cluster] version=$version tools=$tdir"

  update_phase "$cluster" "setting_up_iam"

  # Step (a): work inside cluster dir for the duration of ccoctl/oc commands.
  pushd "$cdir" >/dev/null

  # Step (b): create EC2 key pair (also drops serviceaccount-signer.{public,private}).
  log_info "[$cluster] ccoctl aws create-key-pair"
  if ! run_cmd "$tdir/ccoctl" aws create-key-pair; then
    popd >/dev/null
    fail_with_diagnose "$cluster" "ccoctl create-key-pair failed"
  fi

  # Step (c): create OIDC identity provider with private S3 bucket.
  log_info "[$cluster] ccoctl aws create-identity-provider --name=$cluster --region=$region"
  if ! run_cmd "$tdir/ccoctl" aws create-identity-provider \
      --name="$cluster" \
      --region="$region" \
      --public-key-file=serviceaccount-signer.public \
      --create-private-s3-bucket; then
    popd >/dev/null
    fail_with_diagnose "$cluster" "ccoctl create-identity-provider failed"
  fi

  # Step (d): extract CloudFront distribution id from the rendered manifest.
  local manifest="manifests/cluster-authentication-02-config.yaml"
  local cloudfront_id=""
  if [[ "$DRY_RUN" == "true" && ! -f "$manifest" ]]; then
    cloudfront_id="DRYRUNCFID"
    log_info "[DRY-RUN] using placeholder CLOUDFRONT_ID=$cloudfront_id"
  else
    [[ -f "$manifest" ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "$manifest missing after create-identity-provider"; }
    cloudfront_id="$(
      sed -nE 's|.*https://([a-z0-9-]+)\.cloudfront\.net.*|\1|p' "$manifest" | head -n1
    )"
  fi
  [[ -n "$cloudfront_id" ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "Could not extract CLOUDFRONT_ID from $manifest"; }
  log_info "[$cluster] CLOUDFRONT_ID=$cloudfront_id"

  # Step (e): credrequests dir.
  mkdir -p credrequests

  # Step (f): pull credentials-request manifests for the running release image.
  local release_image=""
  if [[ "$DRY_RUN" == "true" ]]; then
    release_image="quay.io/okd/scos-release:dryrun"
    log_info "[DRY-RUN] release_image=$release_image"
  else
    release_image="$("$tdir/openshift-install" version | awk '/release image/ {print $3}')"
  fi
  [[ -n "$release_image" ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "Could not detect release image"; }

  log_info "[$cluster] oc adm release extract --credentials-requests --from=$release_image"
  if ! run_cmd "$tdir/oc" adm release extract \
      --credentials-requests \
      --cloud=aws \
      --to=credrequests \
      --from="$release_image"; then
    popd >/dev/null
    fail_with_diagnose "$cluster" "oc adm release extract failed"
  fi

  # Step (g): account id and create-iam-roles.
  local account_id=""
  if [[ "$DRY_RUN" == "true" ]]; then
    account_id="000000000000"
  else
    account_id="$(aws sts get-caller-identity --query Account --output text)"
  fi
  [[ -n "$account_id" && "$account_id" != "None" ]] || { popd >/dev/null; fail_with_diagnose "$cluster" "Could not detect AWS account id"; }
  log_info "[$cluster] AWS account=$account_id"

  local idp_arn="arn:aws:iam::${account_id}:oidc-provider/${cloudfront_id}.cloudfront.net"
  log_info "[$cluster] ccoctl aws create-iam-roles (idp=$idp_arn)"
  if ! run_cmd "$tdir/ccoctl" aws create-iam-roles \
      --name="$cluster" \
      --region="$region" \
      --credentials-requests-dir=credrequests \
      --identity-provider-arn="$idp_arn"; then
    popd >/dev/null
    fail_with_diagnose "$cluster" "ccoctl create-iam-roles failed"
  fi

  popd >/dev/null

  # Persist account_id + cloudfront for later reference (read-only audit field).
  if [[ "$DRY_RUN" != "true" ]]; then
    set_status_field "$cluster" '.aws_account_id'  "\"$account_id\""
    set_status_field "$cluster" '.oidc_cloudfront' "\"$cloudfront_id\""
  fi

  log_ok "[$cluster] ccoctl + IAM roles ready"
}

main "$@"
