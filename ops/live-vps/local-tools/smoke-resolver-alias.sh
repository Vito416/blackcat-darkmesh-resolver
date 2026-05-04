#!/usr/bin/env bash
set -euo pipefail

READ_URL="https://hyperbeam.darkmesh.fun"
WRITE_URL="https://write.darkmesh.fun"
PID=""
HOST_PROBE="jdwt.fun"
TIMEOUT=20

usage() {
  cat <<'USAGE'
Smoke-check darkmesh resolver alias wiring.

Usage:
  smoke-resolver-alias.sh [--read-url <url>] [--write-url <url>] [--pid <process-id>] [--host <domain>] [--timeout <s>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --read-url) READ_URL="${2:-}"; shift 2 ;;
    --write-url) WRITE_URL="${2:-}"; shift 2 ;;
    --pid) PID="${2:-}"; shift 2 ;;
    --host) HOST_PROBE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

READ_URL="${READ_URL%/}"
WRITE_URL="${WRITE_URL%/}"

curl_json() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local out_file
  out_file="$(mktemp)"
  local code
  if [[ -n "${data}" ]]; then
    code="$(curl -sS --max-time "${TIMEOUT}" -o "${out_file}" -w '%{http_code}' -X "${method}" -H 'content-type: application/json' --data "${data}" "${url}" || true)"
  else
    code="$(curl -sS --max-time "${TIMEOUT}" -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" || true)"
  fi
  printf '%s\n' "${code}"
  cat "${out_file}"
  rm -f "${out_file}"
}

print_preview() {
  local body="$1"
  printf '%s\n' "${body}" | head -c 500
  echo
}

resolver_has_decision() {
  local body="$1"
  jq -e '.decision != null or .process.processId != null or .site.siteId != null' >/dev/null 2>&1 <<<"${body}"
}

resolver_has_state() {
  local body="$1"
  jq -e '.policyMode != null or .counts != null or .autoDns != null' >/dev/null 2>&1 <<<"${body}"
}

resolver_is_envelope_only() {
  local body="$1"
  jq -e '."ao-result" == "body" and (.body == null)' >/dev/null 2>&1 <<<"${body}"
}

check_alias_resolve() {
  local base="$1"
  local label="$2"
  local url="${base}/~darkmesh-resolver@1.0/resolve?host=${HOST_PROBE}&path=/"
  echo "== ${label}: ${url}"
  mapfile -t res < <(curl_json GET "${url}")
  local code="${res[0]}"
  local body
  body="$(printf '%s\n' "${res[@]:1}")"
  echo "HTTP ${code}"
  print_preview "${body}"
  if [[ "${code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  if [[ "${code}" != "200" ]]; then
    return 1
  fi
  if resolver_is_envelope_only "${body}"; then
    echo "WARN: envelope-only response (ao-result=body, body missing) => resolver action not executed."
    return 1
  fi
  resolver_has_decision "${body}"
}

check_alias_state() {
  local base="$1"
  local label="$2"
  local url="${base}/~darkmesh-resolver@1.0/GetResolverState"
  echo "== ${label}: ${url}"
  mapfile -t res < <(curl_json GET "${url}")
  local code="${res[0]}"
  local body
  body="$(printf '%s\n' "${res[@]:1}")"
  echo "HTTP ${code}"
  print_preview "${body}"
  if [[ "${code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  if [[ "${code}" != "200" ]]; then
    return 1
  fi
  if resolver_is_envelope_only "${body}"; then
    echo "WARN: envelope-only response (ao-result=body, body missing) => resolver action not executed."
    return 1
  fi
  resolver_has_state "${body}"
}

check_alias_action_post() {
  local base="$1"
  local label="$2"
  local action_path="$3"
  local payload="$4"
  local url="${base}/~darkmesh-resolver@1.0/${action_path}"
  echo "== ${label}: ${url}"
  mapfile -t res < <(curl_json POST "${url}" "${payload}")
  local code="${res[0]}"
  local body
  body="$(printf '%s\n' "${res[@]:1}")"
  echo "HTTP ${code}"
  print_preview "${body}"
  if [[ "${code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  if [[ "${code}" != "200" ]]; then
    return 1
  fi
  if resolver_is_envelope_only "${body}"; then
    echo "WARN: envelope-only response (ao-result=body, body missing) => resolver action not executed."
    return 1
  fi
  resolver_has_decision "${body}"
}

check_process_compute_direct() {
  local base="$1"
  local pid="$2"
  local label="$3"
  local slot_url="${base}/${pid}~process@1.0/slot/current?accept-bundle=true"
  local slot_body slot_code slot
  echo "== ${label} slot/current: ${slot_url}"
  mapfile -t slot_res < <(curl_json GET "${slot_url}")
  slot_code="${slot_res[0]}"
  slot_body="$(printf '%s\n' "${slot_res[@]:1}" | tr -d '\r\n')"
  echo "HTTP ${slot_code} slot=${slot_body}"
  if [[ "${slot_code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  if [[ "${slot_code}" != "200" || ! "${slot_body}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  slot="${slot_body}"
  local compute_url="${base}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json"
  echo "== ${label} compute: ${compute_url}"
  mapfile -t comp_res < <(curl_json GET "${compute_url}")
  local comp_code="${comp_res[0]}"
  local comp_body
  comp_body="$(printf '%s\n' "${comp_res[@]:1}")"
  echo "HTTP ${comp_code}"
  print_preview "${comp_body}"
  if [[ "${comp_code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  [[ "${comp_code}" == "200" ]]
}

check_scheduler_assignment_link() {
  local base="$1"
  local pid="$2"
  local label="$3"
  local sched_url="${base}/~scheduler@1.0/schedule?target=${pid}&from=1&to=1"
  echo "== ${label} scheduler-link: ${sched_url}"
  local sched_body_file
  sched_body_file="$(mktemp)"
  local sched_code
  sched_code="$(curl -sS --max-time "${TIMEOUT}" -H 'accept: application/json' -o "${sched_body_file}" -w '%{http_code}' "${sched_url}" || true)"
  local sched_body
  sched_body="$(cat "${sched_body_file}")"
  rm -f "${sched_body_file}"
  echo "HTTP ${sched_code}"
  print_preview "${sched_body}"
  if [[ "${sched_code}" == "429" ]]; then
    echo "WARN: rate-limited; rerun smoke after retry-after window."
    return 1
  fi
  if [[ "${sched_code}" != "200" ]]; then
    return 1
  fi

  local assignments_link
  assignments_link="$(jq -r '."assignments+link" // empty' <<<"${sched_body}" 2>/dev/null || true)"
  if [[ -z "${assignments_link}" ]]; then
    echo "WARN: scheduler response missing assignments+link"
    return 1
  fi

  local link_url="${base}/${assignments_link}"
  echo "== ${label} assignment-link fetch: ${link_url}"
  local link_body_file
  link_body_file="$(mktemp)"
  local link_code
  link_code="$(curl -sS --max-time "${TIMEOUT}" -H 'accept: application/json' -o "${link_body_file}" -w '%{http_code}' "${link_url}" || true)"
  local link_body
  link_body="$(cat "${link_body_file}")"
  rm -f "${link_body_file}"
  echo "HTTP ${link_code}"
  print_preview "${link_body}"
  if [[ "${link_code}" != "200" ]]; then
    return 1
  fi
  # HTML here usually means a route hijack/fallback page, not scheduler payload.
  if grep -qi "<!DOCTYPE html" <<<"${link_body}"; then
    echo "WARN: assignment-link returned HTML instead of scheduler object payload."
    return 1
  fi

  # Runtime fetch paths may not always send an explicit JSON Accept header.
  # Verify default fetch shape too, to catch hidden hyperbuddy/html fallbacks.
  local link_plain_file
  link_plain_file="$(mktemp)"
  local link_plain_code
  link_plain_code="$(curl -sS --max-time "${TIMEOUT}" -o "${link_plain_file}" -w '%{http_code}' "${link_url}" || true)"
  local link_plain_body
  link_plain_body="$(cat "${link_plain_file}")"
  rm -f "${link_plain_file}"
  echo "== ${label} assignment-link fetch (default Accept): HTTP ${link_plain_code}"
  print_preview "${link_plain_body}"
  if [[ "${link_plain_code}" != "200" ]]; then
    return 1
  fi
  if grep -qi "<!DOCTYPE html" <<<"${link_plain_body}"; then
    echo "WARN: default assignment-link fetch returns HTML; runtime scheduler reads can fail."
    return 1
  fi
  return 0
}

ok=0
fail=0

if check_alias_resolve "${READ_URL}" "read alias resolve"; then ((ok+=1)); else ((fail+=1)); fi
if check_alias_resolve "${WRITE_URL}" "write alias resolve"; then ((ok+=1)); else ((fail+=1)); fi
if check_alias_state "${WRITE_URL}" "write alias state"; then ((ok+=1)); else ((fail+=1)); fi
if check_alias_action_post "${WRITE_URL}" "write alias ResolveHostForNode" "ResolveHostForNode" "{\"Host\":\"${HOST_PROBE}\",\"Request-Id\":\"smoke-resolver-host\"}"; then ((ok+=1)); else ((fail+=1)); fi
if check_alias_action_post "${WRITE_URL}" "write alias ResolveRouteForHost" "ResolveRouteForHost" "{\"Host\":\"${HOST_PROBE}\",\"Path\":\"/\",\"Method\":\"GET\",\"Request-Id\":\"smoke-resolver-route\"}"; then ((ok+=1)); else ((fail+=1)); fi

if [[ -n "${PID}" ]]; then
  if check_process_compute_direct "${WRITE_URL}" "${PID}" "write process direct"; then
    ((ok+=1))
  else
    ((fail+=1))
  fi
  if check_scheduler_assignment_link "${WRITE_URL}" "${PID}" "write process direct"; then
    ((ok+=1))
  else
    ((fail+=1))
  fi
fi

echo "== summary: ok=${ok} fail=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
