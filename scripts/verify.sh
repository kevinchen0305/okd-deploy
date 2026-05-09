#!/usr/bin/env bash
# verify.sh — Health-check a freshly-installed cluster and write
# clusters/<name>/verify-report.json. Promotes phase to `ready` on success.
#
# Usage:
#   scripts/verify.sh --cluster dev01 [--smoke] \
#     [--expect-masters 1] [--expect-workers 2] [--dry-run]
set -euo pipefail

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --cluster <name> [--smoke] \\
    [--expect-masters N] [--expect-workers N] [--dry-run]
EOF
  exit 2
}

main() {
  local args=()
  mapfile -t args < <(parse_dry_run_flag "$@")
  set -- "${args[@]+"${args[@]}"}"

  local cluster=""
  local smoke=false
  local expect_masters=1
  local expect_workers=2

  while (($# > 0)); do
    case "$1" in
      --cluster)         cluster="${2:?}";        shift 2 ;;
      --smoke)           smoke=true;              shift   ;;
      --expect-masters)  expect_masters="${2:?}"; shift 2 ;;
      --expect-workers)  expect_workers="${2:?}"; shift 2 ;;
      -h|--help)         usage ;;
      *) log_error "Unknown arg: $1"; usage ;;
    esac
  done
  [[ -n "$cluster" ]] || { log_error "--cluster is required"; usage; }

  require_cmd jq curl

  local cdir kc version tdir oc report
  cdir="$(cluster_dir "$cluster")"
  kc="$(cluster_kubeconfig "$cluster")"
  version="$(get_cluster_version "$cluster")"
  tdir="$(tools_dir "$version")"
  oc="$tdir/oc"
  report="$cdir/verify-report.json"

  [[ -f "$kc" ]] || { log_error "kubeconfig missing: $kc"; exit 1; }

  update_phase "$cluster" "verifying"

  # Initialise report.
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg c "$cluster" --arg ts "$now" '{
    cluster: $c,
    generated_at: $ts,
    checks: {},
    failures: [],
    all_passed: false
  }' >"$report"

  # ────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────
  record() {
    # record <name> <status: ok|fail|warn> [<detail>]
    local name="$1" status="$2" detail="${3:-}"
    local tmp
    tmp="$(mktemp)"
    jq --arg n "$name" --arg s "$status" --arg d "$detail" '
      .checks[$n] = {status:$s, detail:$d}
      | (if $s == "fail" then .failures += [$n] else . end)
    ' "$report" >"$tmp" && mv "$tmp" "$report"

    case "$status" in
      ok)   log_ok   "[$cluster] $name: ok${detail:+ ($detail)}" ;;
      warn) log_warn "[$cluster] $name: warn${detail:+ ($detail)}" ;;
      fail) log_error "[$cluster] $name: fail${detail:+ ($detail)}" ;;
    esac
  }

  oc_get_json() {
    "$oc" --kubeconfig="$kc" get "$@" -o json 2>/dev/null
  }

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] would run all oc/curl probes"
    record nodes              ok "dry-run"
    record cluster_operators  ok "dry-run"
    record core_pods          ok "dry-run"
    record console_http       ok "dry-run"
    record api_healthz        ok "dry-run"
    [[ "$smoke" == "true" ]] && record smoke_workload ok "dry-run"
    finalize_report "$cluster" "$report" true
    return 0
  fi

  # ────────────────────────────────────────────────────
  # Check 1: nodes Ready and counts match.
  # ────────────────────────────────────────────────────
  local nodes_json
  if nodes_json="$(oc_get_json nodes)"; then
    local total ready masters workers
    total="$(jq '.items | length' <<<"$nodes_json")"
    ready="$(jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' <<<"$nodes_json")"
    masters="$(jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] != null or .metadata.labels["node-role.kubernetes.io/control-plane"] != null)] | length' <<<"$nodes_json")"
    workers="$(jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/worker"] != null and .metadata.labels["node-role.kubernetes.io/master"] == null and .metadata.labels["node-role.kubernetes.io/control-plane"] == null)] | length' <<<"$nodes_json")"

    local detail="ready=$ready/$total masters=$masters/$expect_masters workers=$workers/$expect_workers"
    if (( ready == total )) && (( masters >= expect_masters )) && (( workers >= expect_workers )); then
      record nodes ok "$detail"
    else
      record nodes fail "$detail"
    fi
  else
    record nodes fail "oc get nodes failed"
  fi

  # ────────────────────────────────────────────────────
  # Check 2: ClusterOperators all Available=True, Progressing=False, Degraded=False.
  # ────────────────────────────────────────────────────
  local co_json
  if co_json="$(oc_get_json co)"; then
    local bad
    bad="$(jq -r '
      [ .items[]
        | { name: .metadata.name,
            avail: ((.status.conditions[]? | select(.type=="Available")    | .status) // "Unknown"),
            prog:  ((.status.conditions[]? | select(.type=="Progressing") | .status) // "Unknown"),
            degr:  ((.status.conditions[]? | select(.type=="Degraded")    | .status) // "Unknown") }
        | select(.avail != "True" or .prog != "False" or .degr != "False")
      ] | length
    ' <<<"$co_json")"

    if [[ "$bad" == "0" ]]; then
      record cluster_operators ok "all healthy"
    else
      local list
      list="$(jq -r '
        [ .items[]
          | { n: .metadata.name,
              a: ((.status.conditions[]? | select(.type=="Available")    | .status) // "?"),
              p: ((.status.conditions[]? | select(.type=="Progressing") | .status) // "?"),
              d: ((.status.conditions[]? | select(.type=="Degraded")    | .status) // "?") }
          | select(.a!="True" or .p!="False" or .d!="False")
          | "\(.n)(A=\(.a),P=\(.p),D=\(.d))"
        ] | join(",")
      ' <<<"$co_json")"
      record cluster_operators fail "$bad unhealthy: $list"
    fi
  else
    record cluster_operators fail "oc get co failed"
  fi

  # ────────────────────────────────────────────────────
  # Check 3: core pods Running in critical namespaces.
  # ────────────────────────────────────────────────────
  local pods_ok=true
  local pod_detail=""
  local ns
  for ns in openshift-ingress openshift-image-registry openshift-authentication; do
    local pj total_p running
    if ! pj="$(oc_get_json pods -n "$ns")"; then
      pods_ok=false
      pod_detail+=" $ns:get-failed"
      continue
    fi
    total_p="$(jq '.items | length' <<<"$pj")"
    running="$(jq '[.items[] | select(.status.phase=="Running" or .status.phase=="Succeeded")] | length' <<<"$pj")"
    pod_detail+=" $ns=$running/$total_p"
    if (( total_p == 0 )) || (( running != total_p )); then
      pods_ok=false
    fi
  done
  if [[ "$pods_ok" == "true" ]]; then
    record core_pods ok "${pod_detail# }"
  else
    record core_pods fail "${pod_detail# }"
  fi

  # ────────────────────────────────────────────────────
  # Check 4: console URL reachable.
  # ────────────────────────────────────────────────────
  local console_url
  console_url="$(jq -r '.console_url // ""' "$(cluster_status "$cluster")")"
  if [[ -z "$console_url" ]]; then
    record console_http warn "no console_url recorded in status.json"
  else
    local code
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 15 "$console_url" || echo 000)"
    if [[ "$code" == "200" || "$code" == "302" || "$code" == "303" ]]; then
      record console_http ok "$code"
    else
      record console_http fail "http=$code url=$console_url"
    fi
  fi

  # ────────────────────────────────────────────────────
  # Check 5: API server /healthz.
  # ────────────────────────────────────────────────────
  local api_url healthz_body
  api_url="$("$oc" --kubeconfig="$kc" whoami --show-server 2>/dev/null || true)"
  if [[ -n "$api_url" ]]; then
    healthz_body="$(curl -k -s --max-time 10 "$api_url/healthz" || echo "")"
    if [[ "$healthz_body" == "ok" ]]; then
      record api_healthz ok "ok"
    else
      record api_healthz fail "body='$healthz_body' url=$api_url/healthz"
    fi
  else
    record api_healthz fail "oc whoami --show-server failed"
  fi

  # ────────────────────────────────────────────────────
  # Check 6 (opt-in): smoke workload.
  # ────────────────────────────────────────────────────
  if [[ "$smoke" == "true" ]]; then
    local proj="okd-smoke-$$"
    local smoke_ok=true
    if ! run_cmd "$oc" --kubeconfig="$kc" new-project "$proj" >/dev/null 2>&1; then
      smoke_ok=false
    fi
    if [[ "$smoke_ok" == "true" ]]; then
      run_cmd "$oc" --kubeconfig="$kc" -n "$proj" run nginx --image=nginxinc/nginx-unprivileged --port=8080 >/dev/null 2>&1 || smoke_ok=false
      if "$oc" --kubeconfig="$kc" -n "$proj" wait --for=condition=Ready pod/nginx --timeout=180s >/dev/null 2>&1; then
        :
      else
        smoke_ok=false
      fi
    fi
    run_cmd "$oc" --kubeconfig="$kc" delete project "$proj" --wait=false >/dev/null 2>&1 || true
    if [[ "$smoke_ok" == "true" ]]; then
      record smoke_workload ok "nginx pod ran in $proj"
    else
      record smoke_workload fail "smoke workload failed in $proj"
    fi
  fi

  # ────────────────────────────────────────────────────
  # Finalise.
  # ────────────────────────────────────────────────────
  local fail_count
  fail_count="$(jq '.failures | length' "$report")"
  local all_passed=false
  [[ "$fail_count" == "0" ]] && all_passed=true

  finalize_report "$cluster" "$report" "$all_passed"
}

finalize_report() {
  local cluster="$1" report="$2" all_passed="$3"
  local tmp
  tmp="$(mktemp)"
  jq --argjson p "$all_passed" '.all_passed = $p' "$report" >"$tmp" && mv "$tmp" "$report"

  # Mirror summary into status.json.
  local summary
  summary="$(jq -c '{all_passed: .all_passed, checks: (.checks | with_entries(.value = .value.status))}' "$report")"
  set_status_field "$cluster" '.verify_summary' "$summary"

  if [[ "$all_passed" == "true" ]]; then
    update_phase "$cluster" "ready"
    log_ok "[$cluster] all verification checks passed → phase=ready"
  else
    fail_with_diagnose "$cluster" "verify failed: $(jq -r '.failures | join(",")' "$report")"
  fi
}

main "$@"
