#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Resolver migration readiness helper.

Purpose:
  Non-destructive operational checks before enabling resolver-driven routing.

Checks:
  1) Write endpoint parity basics:
     - GET  <write-url>/~meta@1.0/info
     - OPTIONS <write-url>/~scheduler@1.0/schedule
  2) Domain smoke for configured demo domains:
     - HTTPS root status
     - HB meta status
  3) (Optional) DNS proof checks:
     - _darkmesh.<domain> TXT via DNS JSON resolver API
  4) AO registry + resolver contract endpoint availability:
     - site-by-host probe
     - Legacy probe shape + v1 probe shape
  5) (Optional strict) src migration readiness:
     - Contract endpoint probe (site-by-host)
     - Route resolver endpoint probe (resolve-route)
     - Site runtime bundle URL probe (if configured)
  6) AO cutover endpoints (configurable paths):
     - GetTemplateActionContract
     - GetSiteRuntimeBundle
     - ResolveHostPolicyBundle

Exit behavior:
  - Exits non-zero only on hard blockers.
  - WARN findings do not fail the command.

Usage:
  check-resolver-migration-readiness.sh [options] [domain...]

Options:
  --write-url <url>         Write/control-plane base URL.
                            Default: https://write.darkmesh.fun
  --resolver-url <url>      Resolver contract URL.
                            Default: https://hyperbeam.darkmesh.fun/api/public/site-by-host
  --resolver-method <verb>  HTTP method for resolver probe (GET|POST).
                            Default: POST
  --resolver-host <host>    Host passed to resolver probe.
                            Default: first configured domain
  --dns-proof               Enable _darkmesh TXT checks for all domains.
  --strict-dns-proof        Make missing _darkmesh TXT a hard blocker.
  --dns-resolver-url <url>  DNS JSON resolver endpoint (GET).
                            Default: https://dns.google/resolve
  --src-contract-url <url>  AO contract endpoint URL for src-migration check.
                            Default: same as --resolver-url
  --src-route-resolver-url <url>
                            AO route resolver URL for src-migration check.
                            Default: derived from --resolver-url when possible
  --site-runtime-bundle-url <url>
                            Optional runtime bundle URL to probe with GET.
  --ao-base-url <url>       AO base URL for cutover endpoint probes.
                            Default: origin derived from --resolver-url
  --ao-path-site-by-host <path>
                            Default: /api/public/site-by-host
  --ao-path-get-template-action-contract <path>
                            Default: /api/public/GetTemplateActionContract
  --ao-path-get-site-runtime-bundle <path>
                            Default: /api/public/GetSiteRuntimeBundle
  --ao-path-resolve-host-policy-bundle <path>
                            Default: /api/public/ResolveHostPolicyBundle
  --strict-src-migration    Treat src-migration endpoint issues as hard blockers.
  --json                    Print machine-readable summary JSON at the end.
  --domains-file <path>     One domain per line (# comments supported).
  --domains <csv>           Comma-separated domains (merged with file/args).
  --timeout <seconds>       Per-request timeout.
                            Default: 20
  -h, --help                Show this help.

Examples:
  check-resolver-migration-readiness.sh
  check-resolver-migration-readiness.sh --domains-file ops/live-vps/local-tools/demo-domains.example.txt
  check-resolver-migration-readiness.sh jdwt.fun vddl.fun blgateway.fun
  check-resolver-migration-readiness.sh \
    --resolver-url https://hyperbeam.darkmesh.fun/api/public/site-by-host \
    --resolver-method POST
  check-resolver-migration-readiness.sh --dns-proof --strict-dns-proof
  check-resolver-migration-readiness.sh --strict-src-migration \
    --src-route-resolver-url https://hyperbeam.darkmesh.fun/api/public/resolve-route
  check-resolver-migration-readiness.sh --json
USAGE
}

WRITE_URL="https://write.darkmesh.fun"
RESOLVER_URL="https://hyperbeam.darkmesh.fun/api/public/site-by-host"
RESOLVER_METHOD="POST"
RESOLVER_HOST=""
TIMEOUT=20
DOMAINS_FILE=""
DOMAINS_CSV=""
DNS_PROOF=0
STRICT_DNS_PROOF=0
DNS_RESOLVER_URL="https://dns.google/resolve"
SRC_CONTRACT_URL=""
SRC_ROUTE_RESOLVER_URL=""
SITE_RUNTIME_BUNDLE_URL=""
STRICT_SRC_MIGRATION=0
AO_BASE_URL=""
AO_PATH_SITE_BY_HOST="/api/public/site-by-host"
AO_PATH_GET_TEMPLATE_ACTION_CONTRACT="/api/public/GetTemplateActionContract"
AO_PATH_GET_SITE_RUNTIME_BUNDLE="/api/public/GetSiteRuntimeBundle"
AO_PATH_RESOLVE_HOST_POLICY_BUNDLE="/api/public/ResolveHostPolicyBundle"
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write-url)
      WRITE_URL="${2:-}"
      shift 2
      ;;
    --resolver-url)
      RESOLVER_URL="${2:-}"
      shift 2
      ;;
    --resolver-method)
      RESOLVER_METHOD="${2:-}"
      shift 2
      ;;
    --resolver-host)
      RESOLVER_HOST="${2:-}"
      shift 2
      ;;
    --dns-proof)
      DNS_PROOF=1
      shift
      ;;
    --strict-dns-proof)
      STRICT_DNS_PROOF=1
      DNS_PROOF=1
      shift
      ;;
    --dns-resolver-url)
      DNS_RESOLVER_URL="${2:-}"
      shift 2
      ;;
    --src-contract-url)
      SRC_CONTRACT_URL="${2:-}"
      shift 2
      ;;
    --src-route-resolver-url)
      SRC_ROUTE_RESOLVER_URL="${2:-}"
      shift 2
      ;;
    --site-runtime-bundle-url)
      SITE_RUNTIME_BUNDLE_URL="${2:-}"
      shift 2
      ;;
    --ao-base-url)
      AO_BASE_URL="${2:-}"
      shift 2
      ;;
    --ao-path-site-by-host)
      AO_PATH_SITE_BY_HOST="${2:-}"
      shift 2
      ;;
    --ao-path-get-template-action-contract)
      AO_PATH_GET_TEMPLATE_ACTION_CONTRACT="${2:-}"
      shift 2
      ;;
    --ao-path-get-site-runtime-bundle)
      AO_PATH_GET_SITE_RUNTIME_BUNDLE="${2:-}"
      shift 2
      ;;
    --ao-path-resolve-host-policy-bundle)
      AO_PATH_RESOLVE_HOST_POLICY_BUNDLE="${2:-}"
      shift 2
      ;;
    --strict-src-migration)
      STRICT_SRC_MIGRATION=1
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --domains-file)
      DOMAINS_FILE="${2:-}"
      shift 2
      ;;
    --domains)
      DOMAINS_CSV="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT}" -lt 1 ]]; then
  echo "--timeout must be a positive integer" >&2
  exit 2
fi

RESOLVER_METHOD="$(echo "${RESOLVER_METHOD}" | tr '[:lower:]' '[:upper:]')"
if [[ "${RESOLVER_METHOD}" != "GET" && "${RESOLVER_METHOD}" != "POST" ]]; then
  echo "--resolver-method must be GET or POST" >&2
  exit 2
fi

WRITE_URL="${WRITE_URL%/}"
RESOLVER_URL="${RESOLVER_URL%/}"
DNS_RESOLVER_URL="${DNS_RESOLVER_URL%/}"
SRC_CONTRACT_URL="${SRC_CONTRACT_URL%/}"
SRC_ROUTE_RESOLVER_URL="${SRC_ROUTE_RESOLVER_URL%/}"
SITE_RUNTIME_BUNDLE_URL="${SITE_RUNTIME_BUNDLE_URL%/}"
AO_BASE_URL="${AO_BASE_URL%/}"

if [[ -z "${SRC_CONTRACT_URL}" ]]; then
  SRC_CONTRACT_URL="${RESOLVER_URL}"
fi
if [[ -z "${SRC_ROUTE_RESOLVER_URL}" ]]; then
  if [[ "${RESOLVER_URL}" == *"/api/public/site-by-host" ]]; then
    SRC_ROUTE_RESOLVER_URL="${RESOLVER_URL%/api/public/site-by-host}/api/public/resolve-route"
  fi
fi

if [[ -z "${AO_BASE_URL}" ]]; then
  if [[ "${RESOLVER_URL}" =~ ^(https?://[^/]+) ]]; then
    AO_BASE_URL="${BASH_REMATCH[1]}"
  else
    AO_BASE_URL="${RESOLVER_URL}"
  fi
fi

join_url() {
  local base="$1"
  local path="$2"
  if [[ "${path}" =~ ^https?:// ]]; then
    printf '%s' "${path}"
    return
  fi
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  printf '%s%s' "${base%/}" "${path}"
}

AO_ENDPOINT_TEMPLATE_ACTION_CONTRACT="$(join_url "${AO_BASE_URL}" "${AO_PATH_GET_TEMPLATE_ACTION_CONTRACT}")"
AO_ENDPOINT_SITE_RUNTIME_BUNDLE="$(join_url "${AO_BASE_URL}" "${AO_PATH_GET_SITE_RUNTIME_BUNDLE}")"
AO_ENDPOINT_RESOLVE_HOST_POLICY_BUNDLE="$(join_url "${AO_BASE_URL}" "${AO_PATH_RESOLVE_HOST_POLICY_BUNDLE}")"
AO_ENDPOINT_SITE_BY_HOST="$(join_url "${AO_BASE_URL}" "${AO_PATH_SITE_BY_HOST}")"

declare -a DOMAINS=()

add_domain() {
  local value="$1"
  value="$(echo "${value}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "${value}" ]] && return 0
  DOMAINS+=("${value}")
}

if [[ -n "${DOMAINS_FILE}" ]]; then
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo "Domains file not found: ${DOMAINS_FILE}" >&2
    exit 2
  fi
  while IFS= read -r line; do
    line="${line%%#*}"
    add_domain "${line}"
  done < "${DOMAINS_FILE}"
fi

if [[ -n "${DOMAINS_CSV}" ]]; then
  IFS=',' read -r -a _csv_domains <<< "${DOMAINS_CSV}"
  for d in "${_csv_domains[@]}"; do
    add_domain "${d}"
  done
fi

if [[ $# -gt 0 ]]; then
  for d in "$@"; do
    add_domain "${d}"
  done
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  DOMAINS=(jdwt.fun vddl.fun blgateway.fun)
fi

declare -A seen=()
declare -a uniq=()
for d in "${DOMAINS[@]}"; do
  if [[ -z "${seen[$d]+x}" ]]; then
    seen["$d"]=1
    uniq+=("$d")
  fi
done
DOMAINS=("${uniq[@]}")

if [[ -z "${RESOLVER_HOST}" && ${#DOMAINS[@]} -gt 0 ]]; then
  RESOLVER_HOST="${DOMAINS[0]}"
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
HARD_BLOCKERS=0

print_pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "[PASS] $*"; }
print_warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo "[WARN] $*"; }
print_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  HARD_BLOCKERS=$((HARD_BLOCKERS + 1))
  echo "[FAIL] $*"
}
print_dns_missing() {
  if [[ "${STRICT_DNS_PROOF}" -eq 1 ]]; then
    print_fail "$*"
  else
    print_warn "$*"
  fi
}
print_src_issue() {
  if [[ "${STRICT_SRC_MIGRATION}" -eq 1 ]]; then
    print_fail "$*"
  else
    print_warn "$*"
  fi
}

print_hint() {
  case "${1:-}" in
    scheduler_route_missing)
      echo "  [HINT] Scheduler route missing. Verify write endpoint targets control-plane host and includes /~scheduler@1.0/schedule."
      ;;
    wrong_endpoint)
      echo "  [HINT] Endpoint likely points to wrong service (non-AO response). Verify AO base URL and tunnel host mapping."
      ;;
    invalid_scheduler_path)
      echo "  [HINT] Scheduler path mismatch. Validate with hb-full-parity-gate.sh on write endpoint."
      ;;
    missing_route)
      echo "  [HINT] Route may not be published. Check AO public API route wiring for this action."
      ;;
    payload_shape)
      echo "  [HINT] Contract payload shape mismatch. Compare response with resolver contract v1 expected envelope."
      ;;
    *)
      ;;
  esac
}

json_has_contract_envelope() {
  local file="$1"
  jq -e 'type=="object" and has("status") and (has("payload") or has("error"))' "${file}" >/dev/null 2>&1
}

curl_status() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  shift 3
  curl -sS --max-time "${TIMEOUT}" --connect-timeout "${TIMEOUT}" -o "${body_file}" -w '%{http_code}' -X "${method}" "$url" "$@" || true
}

is_ok_root_code() {
  case "$1" in
    200|301|302|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Resolver migration readiness"
echo "write_url=${WRITE_URL}"
echo "resolver_url=${RESOLVER_URL}"
echo "resolver_method=${RESOLVER_METHOD}"
echo "resolver_host=${RESOLVER_HOST:-<unset>}"
echo "dns_proof=${DNS_PROOF}"
echo "strict_dns_proof=${STRICT_DNS_PROOF}"
echo "dns_resolver_url=${DNS_RESOLVER_URL}"
echo "src_contract_url=${SRC_CONTRACT_URL:-<unset>}"
echo "src_route_resolver_url=${SRC_ROUTE_RESOLVER_URL:-<unset>}"
echo "site_runtime_bundle_url=${SITE_RUNTIME_BUNDLE_URL:-<unset>}"
echo "strict_src_migration=${STRICT_SRC_MIGRATION}"
echo "ao_base_url=${AO_BASE_URL}"
echo "ao_endpoint_site_by_host=${AO_ENDPOINT_SITE_BY_HOST}"
echo "ao_endpoint_template_action_contract=${AO_ENDPOINT_TEMPLATE_ACTION_CONTRACT}"
echo "ao_endpoint_site_runtime_bundle=${AO_ENDPOINT_SITE_RUNTIME_BUNDLE}"
echo "ao_endpoint_resolve_host_policy_bundle=${AO_ENDPOINT_RESOLVE_HOST_POLICY_BUNDLE}"
echo "domains=${DOMAINS[*]}"
echo

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "== [1/7] Write endpoint parity basics =="
meta_body="${tmp_dir}/write-meta.txt"
meta_code="$(curl_status GET "${WRITE_URL}/~meta@1.0/info" "${meta_body}")"
if [[ "${meta_code}" == "200" ]]; then
  print_pass "write meta probe OK (${WRITE_URL}/~meta@1.0/info -> 200)"
elif [[ "${meta_code}" == "000" ]]; then
  print_fail "write meta probe unreachable (${WRITE_URL}/~meta@1.0/info)"
else
  print_fail "write meta probe unexpected status (${meta_code})"
fi

sched_body="${tmp_dir}/write-scheduler.txt"
sched_code="$(curl_status OPTIONS "${WRITE_URL}/~scheduler@1.0/schedule" "${sched_body}")"
case "${sched_code}" in
  200|204|400|401|403|405|415|422)
    print_pass "write scheduler route reachable (${sched_code})"
    ;;
  000)
    print_fail "write scheduler probe unreachable"
    ;;
  404)
    print_fail "write scheduler route missing (404)"
    print_hint "scheduler_route_missing"
    ;;
  5??)
    print_fail "write scheduler route upstream failure (${sched_code})"
    print_hint "invalid_scheduler_path"
    ;;
  *)
    print_warn "write scheduler probe returned uncommon status (${sched_code})"
    ;;
esac

echo
echo "== [2/7] Demo domain smoke =="
for domain in "${DOMAINS[@]}"; do
  echo "-- ${domain}"

  root_body="${tmp_dir}/${domain}-root.txt"
  root_code="$(curl_status GET "https://${domain}/" "${root_body}" -L)"
  if is_ok_root_code "${root_code}"; then
    print_pass "${domain} root reachable (${root_code})"
  elif [[ "${root_code}" == "000" ]]; then
    print_fail "${domain} root unreachable"
  else
    print_fail "${domain} root unexpected status (${root_code})"
  fi

  hb_meta_body="${tmp_dir}/${domain}-meta.txt"
  hb_meta_code="$(curl_status GET "https://${domain}/~meta@1.0/info" "${hb_meta_body}")"
  if [[ "${hb_meta_code}" == "200" ]]; then
    print_pass "${domain} HB meta reachable (200)"
  elif [[ "${hb_meta_code}" == "000" ]]; then
    print_warn "${domain} HB meta unreachable"
  else
    print_warn "${domain} HB meta status (${hb_meta_code})"
  fi
done

echo
echo "== [3/7] DNS proof (_darkmesh TXT) =="
if [[ "${DNS_PROOF}" -eq 1 ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    print_warn "jq not found; DNS proof checks skipped"
  else
    for domain in "${DOMAINS[@]}"; do
      proof_name="_darkmesh.${domain}"
      dns_body="${tmp_dir}/dns-${domain}.json"
      dns_code="$(curl_status GET "${DNS_RESOLVER_URL}?name=${proof_name}&type=TXT" "${dns_body}")"

      if [[ "${dns_code}" == "200" ]]; then
        answer_count="$(jq '[.Answer[]? | select(.type == 16)] | length' "${dns_body}" 2>/dev/null || echo 0)"
        if [[ "${answer_count}" =~ ^[0-9]+$ ]] && [[ "${answer_count}" -gt 0 ]]; then
          print_pass "${proof_name} TXT exists (${answer_count} record(s))"
        else
          print_dns_missing "${proof_name} TXT missing"
        fi
      elif [[ "${dns_code}" == "000" ]]; then
        print_warn "${proof_name} TXT probe unreachable (${DNS_RESOLVER_URL})"
      elif [[ "${dns_code}" == "429" ]]; then
        print_warn "${proof_name} TXT probe rate-limited (429)"
      elif [[ "${dns_code}" == "404" ]]; then
        print_warn "${proof_name} TXT probe endpoint missing (404)"
      else
        print_warn "${proof_name} TXT probe unexpected status (${dns_code})"
      fi
    done
  fi
else
  echo "[INFO] DNS proof checks disabled (enable with --dns-proof)"
fi

echo
echo "== [4/7] AO registry + resolver contract endpoint =="

registry_body="${tmp_dir}/ao-site-by-host.txt"
registry_code="$(curl_status POST "${AO_ENDPOINT_SITE_BY_HOST}" "${registry_body}" -H 'content-type: application/json' --data "{\"host\":\"${RESOLVER_HOST}\"}")"
case "${registry_code}" in
  200|404)
    print_pass "AO site-by-host endpoint reachable (${registry_code})"
    if [[ "${registry_code}" == "200" ]] && command -v jq >/dev/null 2>&1; then
      if json_has_contract_envelope "${registry_body}"; then
        if jq -e '.status=="OK" and (.payload.siteId? // "") != ""' "${registry_body}" >/dev/null 2>&1; then
          print_pass "AO site-by-host payload fields OK (status/payload.siteId)"
        else
          print_warn "AO site-by-host payload missing siteId for status=OK"
          print_hint "payload_shape"
        fi
      else
        print_fail "AO site-by-host missing expected contract envelope"
        print_hint "wrong_endpoint"
      fi
    fi
    ;;
  000)
    print_fail "AO site-by-host endpoint unreachable"
    print_hint "wrong_endpoint"
    ;;
  5??)
    print_fail "AO site-by-host upstream failure (${registry_code})"
    print_hint "missing_route"
    ;;
  *)
    print_warn "AO site-by-host endpoint uncommon status (${registry_code})"
    ;;
esac
resolver_check_variant() {
  local variant="$1"
  local payload="$2"
  local code body_file
  body_file="${tmp_dir}/resolver-${variant}.txt"

  if [[ "${RESOLVER_METHOD}" == "POST" ]]; then
    code="$(curl_status POST "${RESOLVER_URL}" "${body_file}" \
      -H 'content-type: application/json' \
      --data "${payload}")"
  else
    code="$(curl_status GET "${RESOLVER_URL}" "${body_file}")"
  fi

  case "${code}" in
    200)
      print_pass "resolver ${variant} probe reachable (200)"
      if command -v jq >/dev/null 2>&1; then
        if json_has_contract_envelope "${body_file}"; then
          print_pass "resolver ${variant} envelope fields present"
        else
          print_fail "resolver ${variant} returned 200 without contract envelope"
          print_hint "payload_shape"
        fi
      fi
      ;;
    404)
      print_pass "resolver ${variant} probe reachable (404 business result)"
      ;;
    400|401|403|405|415|422)
      print_warn "resolver ${variant} probe reachable but shape/auth differs (${code})"
      ;;
    000)
      print_fail "resolver ${variant} probe unreachable"
      print_hint "wrong_endpoint"
      ;;
    5??)
      print_fail "resolver ${variant} probe upstream failure (${code})"
      print_hint "missing_route"
      ;;
    *)
      print_warn "resolver ${variant} probe returned uncommon status (${code})"
      ;;
  esac
}

legacy_payload="{\"host\":\"${RESOLVER_HOST}\"}"
v1_payload="{\"contractVersion\":\"v1\",\"request\":{\"host\":\"${RESOLVER_HOST}\",\"method\":\"GET\",\"path\":\"/\"}}"
resolver_check_variant "legacy" "${legacy_payload}"
resolver_check_variant "v1" "${v1_payload}"

echo
echo "== [5/7] src migration readiness endpoints =="
check_src_post_probe() {
  local label="$1"
  local url="$2"
  local payload="$3"
  local body_file code

  if [[ -z "${url}" ]]; then
    print_warn "${label}: URL not configured"
    return
  fi

  body_file="${tmp_dir}/src-${label// /-}.txt"
  code="$(curl_status POST "${url}" "${body_file}" -H 'content-type: application/json' --data "${payload}")"

  case "${code}" in
    200|404)
      print_pass "${label}: reachable (${code})"
      if [[ "${code}" == "200" ]] && command -v jq >/dev/null 2>&1; then
        if json_has_contract_envelope "${body_file}"; then
          print_pass "${label}: contract envelope fields present"
        else
          print_src_issue "${label}: 200 without contract envelope"
          print_hint "payload_shape"
        fi
      fi
      ;;
    400|401|403|405|415|422)
      print_src_issue "${label}: reachable but payload/auth mismatch (${code})"
      ;;
    000)
      print_src_issue "${label}: unreachable"
      print_hint "wrong_endpoint"
      ;;
    5??)
      print_src_issue "${label}: upstream failure (${code})"
      print_hint "missing_route"
      ;;
    *)
      print_src_issue "${label}: uncommon status (${code})"
      ;;
  esac
}

check_src_bundle_probe() {
  local url="$1"
  local body_file code

  if [[ -z "${url}" ]]; then
    echo "[INFO] site runtime bundle probe skipped (not configured)"
    return
  fi

  body_file="${tmp_dir}/src-runtime-bundle.txt"
  code="$(curl_status GET "${url}" "${body_file}" -L)"

  case "${code}" in
    200|301|302|307|308)
      print_pass "site runtime bundle reachable (${code})"
      ;;
    000)
      print_src_issue "site runtime bundle unreachable"
      ;;
    5??)
      print_src_issue "site runtime bundle upstream failure (${code})"
      ;;
    *)
      print_src_issue "site runtime bundle unexpected status (${code})"
      ;;
  esac
}

src_contract_payload="{\"host\":\"${RESOLVER_HOST}\"}"
src_route_payload="{\"host\":\"${RESOLVER_HOST}\",\"path\":\"/\"}"
check_src_post_probe "src contract endpoint" "${SRC_CONTRACT_URL}" "${src_contract_payload}"
check_src_post_probe "src route resolver endpoint" "${SRC_ROUTE_RESOLVER_URL}" "${src_route_payload}"
check_src_bundle_probe "${SITE_RUNTIME_BUNDLE_URL}"

echo
echo "== [6/7] AO cutover endpoints =="
check_ao_cutover_probe() {
  local label="$1"
  local url="$2"
  local payload="$3"
  local body_file code
  body_file="${tmp_dir}/ao-cutover-${label// /-}.txt"
  code="$(curl_status POST "${url}" "${body_file}" -H 'content-type: application/json' --data "${payload}")"

  case "${code}" in
    200|204)
      print_pass "${label}: reachable (${code})"
      if [[ "${code}" == "200" ]] && command -v jq >/dev/null 2>&1; then
        if json_has_contract_envelope "${body_file}"; then
          print_pass "${label}: contract envelope fields present"
        else
          print_src_issue "${label}: 200 without contract envelope"
          print_hint "payload_shape"
        fi
      fi
      ;;
    400|401|403|405|415|422)
      print_src_issue "${label}: reachable but payload/auth mismatch (${code})"
      ;;
    404)
      print_src_issue "${label}: endpoint missing (404)"
      print_hint "missing_route"
      ;;
    000)
      print_src_issue "${label}: unreachable"
      print_hint "wrong_endpoint"
      ;;
    5??)
      print_src_issue "${label}: upstream failure (${code})"
      ;;
    *)
      print_src_issue "${label}: uncommon status (${code})"
      ;;
  esac
}

cutover_template_payload="{\"host\":\"${RESOLVER_HOST}\",\"action\":\"public.resolve-route\"}"
cutover_bundle_payload="{\"host\":\"${RESOLVER_HOST}\",\"siteId\":\"\"}"
cutover_policy_payload="{\"host\":\"${RESOLVER_HOST}\"}"
check_ao_cutover_probe "GetTemplateActionContract" "${AO_ENDPOINT_TEMPLATE_ACTION_CONTRACT}" "${cutover_template_payload}"
check_ao_cutover_probe "GetSiteRuntimeBundle" "${AO_ENDPOINT_SITE_RUNTIME_BUNDLE}" "${cutover_bundle_payload}"
check_ao_cutover_probe "ResolveHostPolicyBundle" "${AO_ENDPOINT_RESOLVE_HOST_POLICY_BUNDLE}" "${cutover_policy_payload}"

echo
echo "== [7/7] Scheduler path sanity hint =="
if [[ "${sched_code}" == "404" || "${sched_code}" =~ ^5 ]]; then
  print_warn "scheduler path may be invalid for current endpoint (${sched_code})"
  print_hint "invalid_scheduler_path"
else
  print_pass "scheduler path sanity looks acceptable (${sched_code})"
fi

echo
echo "Summary: PASS=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT} HARD_BLOCKERS=${HARD_BLOCKERS}"

RESULT="READY"
if [[ "${HARD_BLOCKERS}" -gt 0 ]]; then
  RESULT="FAIL"
  echo "Result: FAIL (hard blockers present)"
else
  echo "Result: READY (no hard blockers found)"
fi

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

if [[ "${JSON_OUTPUT}" -eq 1 ]]; then
  printf '{'
  printf '"result":"%s",' "$(json_escape "${RESULT}")"
  printf '"pass":%d,"warn":%d,"fail":%d,"hardBlockers":%d,' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${HARD_BLOCKERS}"
  printf '"strictDnsProof":%s,"strictSrcMigration":%s,' "${STRICT_DNS_PROOF}" "${STRICT_SRC_MIGRATION}"
  printf '"writeUrl":"%s",' "$(json_escape "${WRITE_URL}")"
  printf '"resolverUrl":"%s",' "$(json_escape "${RESOLVER_URL}")"
  printf '"aoBaseUrl":"%s",' "$(json_escape "${AO_BASE_URL}")"
  printf '"domains":['
  for i in "${!DOMAINS[@]}"; do
    [[ "${i}" -gt 0 ]] && printf ','
    printf '"%s"' "$(json_escape "${DOMAINS[$i]}")"
  done
  printf ']'
  printf '}\n'
fi

if [[ "${HARD_BLOCKERS}" -gt 0 ]]; then
  exit 1
fi
