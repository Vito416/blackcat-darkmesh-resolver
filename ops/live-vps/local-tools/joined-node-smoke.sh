#!/usr/bin/env bash
set -euo pipefail

WORKER_PROJECTION_URL="${WORKER_PROJECTION_URL:-${WORKER_CURRENT_URL:-https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current}}"
CONTROL_STATE_URL="${CONTROL_STATE_URL:-}"
CONTROL_AUTH_TOKEN="${RESOLVER_CONTROL_AUTH_TOKEN:-}"
NODE_STATE_URL="${NODE_STATE_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState}"
NODE_READ_BASE_URL="${NODE_READ_BASE_URL:-https://hyperbeam.darkmesh.fun}"
TIMEOUT="${TIMEOUT:-20}"
declare -a HOSTS=("jdwt.fun" "vddl.fun" "blgateway.fun")
declare -a PUBLIC_URLS=()
EXPECT_SEQUENCE="${EXPECT_SEQUENCE:-}"
EXPECT_KEY_ID="${EXPECT_KEY_ID:-}"
WRITE_GUARD_URL="${WRITE_GUARD_URL:-}"

usage() {
  cat <<'USAGE'
Usage:
  joined-node-smoke.sh [options]

Verifies that a joined serving node:
  - sees the same active signed projection sequence as the control-plane
  - is active and verificationReason=ok
  - returns ALLOW_ROUTE_HOST_BOUND for expected hosts
  - optionally still serves public URLs / write guard as expected

Options:
  --worker-projection-url <u>  Active signed snapshot URL.
  --worker-current-url <url>   Compatibility alias for --worker-projection-url.
  --control-state-url <url>    Optional authenticated control-state current URL.
                               No default in minimal-exposed-surface mode.
  --control-auth-token <tok>   Optional bearer token for control-state fetch.
  --node-state-url <url>       Joined node GetResolverState URL.
  --node-read-base-url <url>   Joined node resolver read base URL.
  --host <domain>              Host to probe through resolve API. Repeatable.
  --public-url <url>           Public URL expected to return 200. Repeatable.
  --write-guard-url <url>      URL expected to return 405 on GET.
  --expect-sequence <n>        Override expected sequence instead of worker current.
  --expect-key-id <id>         Override expected key id instead of worker current.
  --timeout <sec>              Curl timeout. Default: 20
  -h|--help                    Show help.
USAGE
}

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-projection-url|--worker-current-url) WORKER_PROJECTION_URL="${2:-}"; shift 2 ;;
    --control-state-url) CONTROL_STATE_URL="${2:-}"; shift 2 ;;
    --control-auth-token) CONTROL_AUTH_TOKEN="${2:-}"; shift 2 ;;
    --node-state-url) NODE_STATE_URL="${2:-}"; shift 2 ;;
    --node-read-base-url) NODE_READ_BASE_URL="${2:-}"; shift 2 ;;
    --host) HOSTS+=("${2:-}"); shift 2 ;;
    --public-url) PUBLIC_URLS+=("${2:-}"); shift 2 ;;
    --write-guard-url) WRITE_GUARD_URL="${2:-}"; shift 2 ;;
    --expect-sequence) EXPECT_SEQUENCE="${2:-}"; shift 2 ;;
    --expect-key-id) EXPECT_KEY_ID="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

HOSTS=($(printf '%s\n' "${HOSTS[@]}" | awk 'NF && !seen[$0]++'))

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd jq

fetch_json() {
  local url="$1"
  local out="$2"
  local code
  code="$(curl -sS --max-time "$TIMEOUT" -o "$out" -w '%{http_code}' "$url" || true)"
  if [[ "$code" != "200" ]]; then
    echo "HTTP ${code} for ${url}" >&2
    head -c 400 "$out" >&2 || true
    echo >&2
    return 1
  fi
}

fetch_json_auth_optional() {
  local url="$1"
  local out="$2"
  local token="$3"
  local code
  code="$(curl -sS --max-time "$TIMEOUT" -H "authorization: Bearer ${token}" -o "$out" -w '%{http_code}' "$url" || true)"
  if [[ "$code" != "200" ]]; then
    echo "HTTP ${code} for ${url}" >&2
    head -c 400 "$out" >&2 || true
    echo >&2
    return 1
  fi
}

check_public_status() {
  local url="$1"
  local expected="$2"
  local body="$tmp_dir/public.body"
  local code
  code="$(curl -sS -L --max-time "$TIMEOUT" -o "$body" -w '%{http_code}' "$url" || true)"
  printf '[public] %s -> HTTP %s\n' "$url" "$code"
  if [[ "$code" != "$expected" ]]; then
    echo "unexpected status for $url: expected $expected, got $code" >&2
    head -c 300 "$body" >&2 || true
    echo >&2
    exit 1
  fi
}

echo "[1/4] Fetch control-plane active snapshot"
worker_current_json="$tmp_dir/worker-current.json"
fetch_json "$WORKER_PROJECTION_URL" "$worker_current_json"
worker_sequence="$(jq -r '.sequence // empty' "$worker_current_json")"
worker_key_id="$(jq -r '.keyId // empty' "$worker_current_json")"
worker_payload_hash="$(jq -r '.payloadHash // empty' "$worker_current_json")"

if [[ -n "$EXPECT_SEQUENCE" ]]; then
  worker_sequence="$EXPECT_SEQUENCE"
fi
if [[ -n "$EXPECT_KEY_ID" ]]; then
  worker_key_id="$EXPECT_KEY_ID"
fi

echo "  sequence=${worker_sequence}"
echo "  keyId=${worker_key_id}"
echo "  payloadHash=${worker_payload_hash}"

if [[ -n "$CONTROL_STATE_URL" && -n "$CONTROL_AUTH_TOKEN" ]]; then
  echo "[1.5/4] Fetch control-plane AO health summary"
  control_state_json="$tmp_dir/control-state.json"
  fetch_json_auth_optional "$CONTROL_STATE_URL" "$control_state_json" "$CONTROL_AUTH_TOKEN"
  jq -e '(.state.aoNativeReadbackSummary.healthyActions // 0) > 0 and (.state.aoNativeReadbackSummary.unhealthyActions // 0) == 0' "$control_state_json" >/dev/null
  ao_read_payload_available="$(jq -r '.state.aoNativeReadbackSummary.payloadActions // 0' "$control_state_json")"
  ao_read_runtime_effect_only="$(jq -r '.state.aoNativeReadbackSummary.runtimeEffectOnlyActions // 0' "$control_state_json")"
  ao_read_process_id="$(jq -r '.state.aoNativeReadbackSummary.processId // empty' "$control_state_json")"
  echo "  aoReadProcessId=${ao_read_process_id:-unknown}"
  echo "  aoReadPayloadActions=${ao_read_payload_available}"
  echo "  aoReadRuntimeEffectOnlyActions=${ao_read_runtime_effect_only}"
elif [[ -n "$CONTROL_AUTH_TOKEN" ]]; then
  echo "[1.5/4] Skip control-plane AO health summary (no --control-state-url provided)"
fi

echo "[2/4] Fetch joined node resolver state"
node_state_json="$tmp_dir/node-state.json"
fetch_json "$NODE_STATE_URL" "$node_state_json"

jq -e '.projection.mode == "active"' "$node_state_json" >/dev/null
jq -e '.projection.verificationReason == "ok"' "$node_state_json" >/dev/null
node_sequence="$(jq -r '.projection.sequence // empty' "$node_state_json")"
node_key_id="$(jq -r '.projection.keyId // empty' "$node_state_json")"
node_payload_hash="$(jq -r '.projection.payloadHash // empty' "$node_state_json")"

echo "  nodeSequence=${node_sequence}"
echo "  nodeKeyId=${node_key_id}"
echo "  nodePayloadHash=${node_payload_hash}"

if [[ "$node_sequence" != "$worker_sequence" ]]; then
  echo "sequence mismatch: worker=$worker_sequence node=$node_sequence" >&2
  exit 1
fi
if [[ "$node_key_id" != "$worker_key_id" ]]; then
  echo "keyId mismatch: worker=$worker_key_id node=$node_key_id" >&2
  exit 1
fi
if [[ -n "$worker_payload_hash" && -n "$node_payload_hash" && "$node_payload_hash" != "$worker_payload_hash" ]]; then
  echo "payloadHash mismatch: worker=$worker_payload_hash node=$node_payload_hash" >&2
  exit 1
fi

echo "[3/4] Probe resolver decisions on joined node"
for host in "${HOSTS[@]}"; do
  url="${NODE_READ_BASE_URL%/}/~darkmesh-resolver@1.0/resolve?host=${host}&path=/&method=GET"
  out="$tmp_dir/resolve-${host}.json"
  fetch_json "$url" "$out"
  jq -e '.decision == "allow"' "$out" >/dev/null
  jq -e '.reasonCode == "ALLOW_ROUTE_HOST_BOUND"' "$out" >/dev/null
  resolved_host="$(jq -r '.host // empty' "$out")"
  canonical_host="$(jq -r '.site.canonicalHost // empty' "$out")"
  printf '  %s -> allow (resolvedHost=%s canonicalHost=%s)\n' "$host" "${resolved_host:-?}" "${canonical_host:-?}"
done

echo "[4/4] Optional public checks"
if (( ${#PUBLIC_URLS[@]} == 0 )) && [[ -z "$WRITE_GUARD_URL" ]]; then
  echo "  skipped (no public URLs requested)"
else
  for url in "${PUBLIC_URLS[@]}"; do
    check_public_status "$url" "200"
  done
  if [[ -n "$WRITE_GUARD_URL" ]]; then
    check_public_status "$WRITE_GUARD_URL" "405"
  fi
fi

echo
echo "joined node smoke: OK"
