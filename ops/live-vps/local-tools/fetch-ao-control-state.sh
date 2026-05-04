#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  fetch-ao-control-state.sh [options]

Read-only collector for AO-derived resolver control-state inputs.

It can:
  - fetch raw handler payloads from URLs, or
  - copy already-captured raw JSON files into a normalized output directory

Outputs:
  - admission-state.json            (if available)
  - due-hosts-state.json            (if available)
  - dns-refresh-state.json          (if available)
  - ao-control-state-fetch-report.json

Examples:
  bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
    --output-dir /tmp/darkmesh-ao-state

  bash ops/live-vps/local-tools/fetch-ao-control-state.sh \
    --admission-file /tmp/GetAdmissionState.json \
    --due-hosts-file /tmp/ListHostsDueForDnsRefresh.json \
    --dns-refresh-file /tmp/GetDnsRefreshState.json \
    --output-dir /tmp/darkmesh-ao-state

Options:
  --node-base-url <url>             Base resolver URL. Default:
                                    https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0
  --admission-url <url>             Override admission URL.
  --due-hosts-url <url>             Override due-hosts URL.
  --dns-refresh-url <url>           Override dns-refresh URL.
  --admission-method <verb>         Default: GET
  --due-hosts-method <verb>         Default: GET
  --dns-refresh-method <verb>       Default: GET
  --admission-body-json <json>      Optional raw request body.
  --due-hosts-body-json <json>      Optional raw request body.
  --dns-refresh-body-json <json>    Optional raw request body.
  --admission-file <path>           Use local raw JSON instead of fetching.
  --due-hosts-file <path>           Use local raw JSON instead of fetching.
  --dns-refresh-file <path>         Use local raw JSON instead of fetching.
  --require-admission               Exit non-zero if admission state unavailable.
  --require-due-hosts               Exit non-zero if due-hosts state unavailable.
  --require-dns-refresh             Exit non-zero if dns-refresh state unavailable.
  --output-dir <path>               Output directory. Default: mktemp
  --timeout <sec>                   Curl timeout. Default: 20
  -h|--help                         Show help.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

validate_json_file() {
  local label="$1"
  local path="$2"
  local filter="$3"
  if ! jq -e "$filter" "$path" >/dev/null 2>&1; then
    echo "invalid ${label} JSON: $path" >&2
    return 1
  fi
}

fetch_http() {
  local method="$1"
  local url="$2"
  local out="$3"
  local body_json="${4:-}"
  local code
  if [[ -n "$body_json" ]]; then
    code="$(curl -sS --max-time "$TIMEOUT" -H 'content-type: application/json' -X "$method" -o "$out" -w '%{http_code}' --data "$body_json" "$url" || true)"
  else
    code="$(curl -sS --max-time "$TIMEOUT" -X "$method" -o "$out" -w '%{http_code}' "$url" || true)"
  fi
  printf '%s' "$code"
}

collect_one() {
  local label="$1"
  local source_file="$2"
  local url="$3"
  local method="$4"
  local body_json="$5"
  local required="$6"
  local output_json="$7"
  local raw_capture="$8"
  local validator="$9"

  local available=false
  local source_kind="missing"
  local http_code=""
  local detail=""

  if [[ -n "$source_file" ]]; then
    cp "$source_file" "$raw_capture"
    if validate_json_file "$label" "$raw_capture" "$validator"; then
      cp "$raw_capture" "$output_json"
      available=true
      source_kind="file"
      detail="copied"
    else
      detail="invalid_json"
    fi
  elif [[ -n "$url" ]]; then
    http_code="$(fetch_http "$method" "$url" "$raw_capture" "$body_json")"
    if [[ "$http_code" == "200" ]]; then
      if validate_json_file "$label" "$raw_capture" "$validator"; then
        cp "$raw_capture" "$output_json"
        available=true
        source_kind="url"
        detail="fetched"
      else
        detail="invalid_payload"
      fi
    else
      detail="http_${http_code}"
    fi
  else
    detail="no_source"
  fi

  if [[ "$available" != true ]]; then
    rm -f "$output_json"
    if [[ "$required" == "1" ]]; then
      echo "required ${label} unavailable (${detail})" >&2
      exit 1
    fi
  fi

  jq -n \
    --arg label "$label" \
    --arg sourceKind "$source_kind" \
    --arg filePath "$output_json" \
    --arg rawCapture "$raw_capture" \
    --arg url "${url:-}" \
    --arg method "$method" \
    --arg httpCode "$http_code" \
    --arg detail "$detail" \
    --argjson available "$available" \
    '{
      label: $label,
      available: $available,
      sourceKind: (if $sourceKind == "missing" then null else $sourceKind end),
      filePath: (if $available then $filePath else null end),
      rawCapture: $rawCapture,
      request: {
        url: (if $url == "" then null else $url end),
        method: (if $url == "" then null else $method end),
        httpCode: (if $httpCode == "" then null else ($httpCode | tonumber) end)
      },
      detail: $detail
    }'
}

require_cmd curl
require_cmd jq

NODE_BASE_URL="${NODE_BASE_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0}"
ADMISSION_URL=""
DUE_HOSTS_URL=""
DNS_REFRESH_URL=""
ADMISSION_METHOD="GET"
DUE_HOSTS_METHOD="GET"
DNS_REFRESH_METHOD="GET"
ADMISSION_BODY_JSON=""
DUE_HOSTS_BODY_JSON=""
DNS_REFRESH_BODY_JSON=""
ADMISSION_FILE=""
DUE_HOSTS_FILE=""
DNS_REFRESH_FILE=""
REQUIRE_ADMISSION=0
REQUIRE_DUE_HOSTS=0
REQUIRE_DNS_REFRESH=0
OUTPUT_DIR=""
TIMEOUT="${TIMEOUT:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-base-url) NODE_BASE_URL="${2:-}"; shift 2 ;;
    --admission-url) ADMISSION_URL="${2:-}"; shift 2 ;;
    --due-hosts-url) DUE_HOSTS_URL="${2:-}"; shift 2 ;;
    --dns-refresh-url) DNS_REFRESH_URL="${2:-}"; shift 2 ;;
    --admission-method) ADMISSION_METHOD="${2:-}"; shift 2 ;;
    --due-hosts-method) DUE_HOSTS_METHOD="${2:-}"; shift 2 ;;
    --dns-refresh-method) DNS_REFRESH_METHOD="${2:-}"; shift 2 ;;
    --admission-body-json) ADMISSION_BODY_JSON="${2:-}"; shift 2 ;;
    --due-hosts-body-json) DUE_HOSTS_BODY_JSON="${2:-}"; shift 2 ;;
    --dns-refresh-body-json) DNS_REFRESH_BODY_JSON="${2:-}"; shift 2 ;;
    --admission-file) ADMISSION_FILE="${2:-}"; shift 2 ;;
    --due-hosts-file) DUE_HOSTS_FILE="${2:-}"; shift 2 ;;
    --dns-refresh-file) DNS_REFRESH_FILE="${2:-}"; shift 2 ;;
    --require-admission) REQUIRE_ADMISSION=1; shift ;;
    --require-due-hosts) REQUIRE_DUE_HOSTS=1; shift ;;
    --require-dns-refresh) REQUIRE_DNS_REFRESH=1; shift ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$ADMISSION_FILE" || -f "$ADMISSION_FILE" ]] || { echo "admission file not found: $ADMISSION_FILE" >&2; exit 2; }
[[ -z "$DUE_HOSTS_FILE" || -f "$DUE_HOSTS_FILE" ]] || { echo "due-hosts file not found: $DUE_HOSTS_FILE" >&2; exit 2; }
[[ -z "$DNS_REFRESH_FILE" || -f "$DNS_REFRESH_FILE" ]] || { echo "dns-refresh file not found: $DNS_REFRESH_FILE" >&2; exit 2; }

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "$OUTPUT_DIR"
fi

if [[ -z "$ADMISSION_URL" && -z "$ADMISSION_FILE" ]]; then
  ADMISSION_URL="${NODE_BASE_URL%/}/GetAdmissionState"
fi
if [[ -z "$DUE_HOSTS_URL" && -z "$DUE_HOSTS_FILE" ]]; then
  DUE_HOSTS_URL="${NODE_BASE_URL%/}/ListHostsDueForDnsRefresh"
fi
if [[ -z "$DNS_REFRESH_URL" && -z "$DNS_REFRESH_FILE" ]]; then
  DNS_REFRESH_URL="${NODE_BASE_URL%/}/GetDnsRefreshState"
fi

admission_json="$OUTPUT_DIR/admission-state.json"
due_hosts_json="$OUTPUT_DIR/due-hosts-state.json"
dns_refresh_json="$OUTPUT_DIR/dns-refresh-state.json"
admission_raw="$OUTPUT_DIR/admission-state.raw"
due_hosts_raw="$OUTPUT_DIR/due-hosts-state.raw"
dns_refresh_raw="$OUTPUT_DIR/dns-refresh-state.raw"
report_json="$OUTPUT_DIR/ao-control-state-fetch-report.json"

echo "[1/4] Collect admission state"
admission_result="$(
  collect_one \
    "admission-state" \
    "$ADMISSION_FILE" \
    "$ADMISSION_URL" \
    "$ADMISSION_METHOD" \
    "$ADMISSION_BODY_JSON" \
    "$REQUIRE_ADMISSION" \
    "$admission_json" \
    "$admission_raw" \
    'type == "object" and (.schemaVersion? | type == "string") and (.admission? | type == "object")'
)"

echo "[2/4] Collect due-hosts state"
due_hosts_result="$(
  collect_one \
    "due-hosts-state" \
    "$DUE_HOSTS_FILE" \
    "$DUE_HOSTS_URL" \
    "$DUE_HOSTS_METHOD" \
    "$DUE_HOSTS_BODY_JSON" \
    "$REQUIRE_DUE_HOSTS" \
    "$due_hosts_json" \
    "$due_hosts_raw" \
    'type == "object" and (.schemaVersion? | type == "string") and (.counts? | type == "object") and ((.dueHosts // []) | type == "array")'
)"

echo "[3/4] Collect dns-refresh state"
dns_refresh_result="$(
  collect_one \
    "dns-refresh-state" \
    "$DNS_REFRESH_FILE" \
    "$DNS_REFRESH_URL" \
    "$DNS_REFRESH_METHOD" \
    "$DNS_REFRESH_BODY_JSON" \
    "$REQUIRE_DNS_REFRESH" \
    "$dns_refresh_json" \
    "$dns_refresh_raw" \
    'type == "object" and (.schemaVersion? | type == "string") and (.counts? | type == "object") and (.autoDns? | type == "object")'
)"

echo "[4/4] Write fetch report"
jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg outputDir "$OUTPUT_DIR" \
  --arg nodeBaseUrl "$NODE_BASE_URL" \
  --argjson admission "$admission_result" \
  --argjson dueHosts "$due_hosts_result" \
  --argjson dnsRefresh "$dns_refresh_result" \
  '{
    generatedAt: $generatedAt,
    outputDir: $outputDir,
    nodeBaseUrl: $nodeBaseUrl,
    results: {
      admission: $admission,
      dueHosts: $dueHosts,
      dnsRefresh: $dnsRefresh
    }
  }' >"$report_json"

echo "ao control-state fetch complete"
echo "  outputDir=$OUTPUT_DIR"
echo "  report=$report_json"
echo "  admissionAvailable=$(jq -r '.results.admission.available' "$report_json")"
echo "  dueHostsAvailable=$(jq -r '.results.dueHosts.available' "$report_json")"
echo "  dnsRefreshAvailable=$(jq -r '.results.dnsRefresh.available' "$report_json")"
