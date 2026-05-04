#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dynamic-mode-scout.sh [options]

Non-destructive D2 scout for DarkMesh Resolver.

What it does:
  1. fetch active signed projection from control-plane
  2. fetch joined-node resolver state
  3. fetch joined-node DNS refresh state
  4. probe which D2 read/control surfaces are publicly exposed today
  5. optionally run projection-release.sh in --dry-run mode to stage a release candidate
  6. write a report JSON + captured responses

Options:
  --worker-projection-url <u>  Remote active signed projection URL.
  --worker-current-url <url>   Compatibility alias for --worker-projection-url.
  --node-state-url <url>       Joined node GetResolverState URL.
  --dns-state-url <url>        Joined node GetDnsRefreshState URL.
  --admission-url <url>        Optional GetAdmissionState URL probe.
  --due-url <url>              Optional ListHostsDueForDnsRefresh URL probe.
  --force-refresh-url <url>    Optional ForceDnsRefreshHost URL probe.
  --aoconnect-report <path>    Optional AO-native readback report from
                               fetch-ao-control-state-via-aoconnect.mjs.
  --worker-base-url <url>      Async-worker base URL for optional release dry-run.
  --domains <csv>              Domains for optional release dry-run.
  --domains-file <path>        Domains file for optional release dry-run.
  --output-dir <path>          Output directory. Default: mktemp
  --timeout <sec>              Curl timeout. Default: 20
  --release-dry-run            Run projection-release.sh --dry-run if inputs allow.
  -h|--help                    Show help.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/ops/live-vps/local-tools/projection-release.sh"

WORKER_PROJECTION_URL="${WORKER_PROJECTION_URL:-${WORKER_CURRENT_URL:-https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current}}"
NODE_STATE_URL="${NODE_STATE_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState}"
DNS_STATE_URL="${DNS_STATE_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetDnsRefreshState}"
ADMISSION_URL="${ADMISSION_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetAdmissionState}"
DUE_URL="${DUE_URL:-https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/ListHostsDueForDnsRefresh}"
FORCE_REFRESH_URL="${FORCE_REFRESH_URL:-https://write.darkmesh.fun/~darkmesh-resolver@1.0/ForceDnsRefreshHost}"
AOCONNECT_REPORT_PATH=""
WORKER_BASE_URL="${WORKER_BASE_URL:-}"
DOMAINS_CSV=""
DOMAINS_FILE=""
OUTPUT_DIR=""
TIMEOUT="${TIMEOUT:-20}"
RELEASE_DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-projection-url|--worker-current-url) WORKER_PROJECTION_URL="${2:-}"; shift 2 ;;
    --node-state-url) NODE_STATE_URL="${2:-}"; shift 2 ;;
    --dns-state-url) DNS_STATE_URL="${2:-}"; shift 2 ;;
    --admission-url) ADMISSION_URL="${2:-}"; shift 2 ;;
    --due-url) DUE_URL="${2:-}"; shift 2 ;;
    --force-refresh-url) FORCE_REFRESH_URL="${2:-}"; shift 2 ;;
    --aoconnect-report) AOCONNECT_REPORT_PATH="${2:-}"; shift 2 ;;
    --worker-base-url) WORKER_BASE_URL="${2:-}"; shift 2 ;;
    --domains) DOMAINS_CSV="${2:-}"; shift 2 ;;
    --domains-file) DOMAINS_FILE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --release-dry-run) RELEASE_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

require_cmd curl
require_cmd jq
require_cmd python3

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "$OUTPUT_DIR"
fi

if [[ -n "$AOCONNECT_REPORT_PATH" && ! -f "$AOCONNECT_REPORT_PATH" ]]; then
  echo "aoconnect report file not found: $AOCONNECT_REPORT_PATH" >&2
  exit 2
fi

if [[ -n "$AOCONNECT_REPORT_PATH" ]]; then
  jq -e '
    type == "object"
    and (.results? | type == "array")
    and (.readContractSummary? | type == "object")
  ' "$AOCONNECT_REPORT_PATH" >/dev/null || {
    echo "invalid aoconnect report: $AOCONNECT_REPORT_PATH" >&2
    exit 2
  }
fi

fetch_any() {
  local method="$1"
  local url="$2"
  local out="$3"
  local body="${4:-}"
  local code
  if [[ -n "$body" ]]; then
    code="$(curl -sS --max-time "$TIMEOUT" -H 'content-type: application/json' -X "$method" -o "$out" -w '%{http_code}' --data "$body" "$url" || true)"
  else
    code="$(curl -sS --max-time "$TIMEOUT" -X "$method" -o "$out" -w '%{http_code}' "$url" || true)"
  fi
  printf '%s' "$code"
}

safe_probe_json() {
  local method="$1"
  local url="$2"
  local out="$3"
  local body="${4:-}"
  local code
  code="$(fetch_any "$method" "$url" "$out" "$body")"
  jq -n \
    --arg url "$url" \
    --arg method "$method" \
    --arg code "$code" \
    --arg bodyFile "$out" \
    '{url:$url,method:$method,httpCode:($code|tonumber),bodyFile:$bodyFile}'
}

echo "[1/6] Fetch control-plane active projection"
worker_current_file="$OUTPUT_DIR/worker-current.json"
worker_code="$(fetch_any GET "$WORKER_PROJECTION_URL" "$worker_current_file")"
[[ "$worker_code" == "200" ]] || {
  echo "failed to fetch worker current: HTTP $worker_code" >&2
  exit 1
}

echo "[2/6] Fetch joined-node resolver state"
node_state_file="$OUTPUT_DIR/node-state.json"
node_state_code="$(fetch_any GET "$NODE_STATE_URL" "$node_state_file")"
[[ "$node_state_code" == "200" ]] || {
  echo "failed to fetch node state: HTTP $node_state_code" >&2
  exit 1
}

echo "[3/6] Fetch joined-node DNS refresh state"
dns_state_file="$OUTPUT_DIR/dns-state.json"
dns_state_code="$(fetch_any GET "$DNS_STATE_URL" "$dns_state_file")"
[[ "$dns_state_code" == "200" ]] || {
  echo "failed to fetch dns refresh state: HTTP $dns_state_code" >&2
  exit 1
}

echo "[4/6] Probe optional D2 surfaces"
admission_probe_file="$OUTPUT_DIR/admission-probe.json"
due_probe_file="$OUTPUT_DIR/due-probe.json"
force_probe_file="$OUTPUT_DIR/force-refresh-probe.json"

admission_probe_json="$(safe_probe_json GET "$ADMISSION_URL" "$admission_probe_file")"
due_probe_json="$(safe_probe_json GET "$DUE_URL" "$due_probe_file")"
force_probe_json="$(safe_probe_json POST "$FORCE_REFRESH_URL" "$force_probe_file" '{"Host":"jdwt.fun"}')"

release_metadata_file=""
if (( RELEASE_DRY_RUN == 1 )); then
  echo "[5/6] Run projection release dry-run"
  [[ -n "$WORKER_BASE_URL" ]] || {
    echo "--release-dry-run requires --worker-base-url" >&2
    exit 2
  }
  [[ -n "$DOMAINS_CSV" || -n "$DOMAINS_FILE" ]] || {
    echo "--release-dry-run requires --domains or --domains-file" >&2
    exit 2
  }
  [[ -n "${RESOLVER_SIGNER_AUTH_TOKEN:-}" ]] || {
    echo "--release-dry-run requires RESOLVER_SIGNER_AUTH_TOKEN" >&2
    exit 2
  }
  release_output_dir="$OUTPUT_DIR/release-dry-run"
  mkdir -p "$release_output_dir"
  release_args=(
    --worker-base-url "$WORKER_BASE_URL"
    --output-dir "$release_output_dir"
    --dry-run
  )
  [[ -n "$DOMAINS_CSV" ]] && release_args+=(--domains "$DOMAINS_CSV")
  [[ -n "$DOMAINS_FILE" ]] && release_args+=(--domains-file "$DOMAINS_FILE")
  bash "$RELEASE_SCRIPT" "${release_args[@]}"
  release_metadata_file="$release_output_dir/release-metadata.json"
else
  echo "[5/6] Release dry-run skipped"
fi

echo "[6/6] Write D2 scout report"
report_file="$OUTPUT_DIR/dynamic-mode-scout-report.json"

worker_sequence="$(jq -r '.sequence // empty' "$worker_current_file")"
worker_key_id="$(jq -r '.keyId // empty' "$worker_current_file")"
worker_payload_hash="$(jq -r '.payloadHash // empty' "$worker_current_file")"
node_sequence="$(jq -r '.projection.sequence // empty' "$node_state_file")"
node_key_id="$(jq -r '.projection.keyId // empty' "$node_state_file")"
node_payload_hash="$(jq -r '.projection.payloadHash // empty' "$node_state_file")"

projection_in_sync=false
if [[ -n "$worker_sequence" && -n "$node_sequence" && "$worker_sequence" == "$node_sequence" && "$worker_key_id" == "$node_key_id" && "$worker_payload_hash" == "$node_payload_hash" ]]; then
  projection_in_sync=true
fi

node_active_ok=false
if jq -e '.projection.mode == "active" and .projection.verificationReason == "ok"' "$node_state_file" >/dev/null; then
  node_active_ok=true
fi

dns_state_available=false
if jq -e '.schemaVersion != null and .autoDns != null' "$dns_state_file" >/dev/null; then
  dns_state_available=true
fi

ao_report_input="${AOCONNECT_REPORT_PATH:-}"
if [[ -z "$ao_report_input" ]]; then
  ao_report_input="$OUTPUT_DIR/ao-native-readback.placeholder.json"
  printf 'null\n' > "$ao_report_input"
fi

jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg outputDir "$OUTPUT_DIR" \
  --arg workerProjectionUrl "$WORKER_PROJECTION_URL" \
  --arg workerCurrentUrl "$WORKER_PROJECTION_URL" \
  --arg nodeStateUrl "$NODE_STATE_URL" \
  --arg dnsStateUrl "$DNS_STATE_URL" \
  --argjson projectionInSync "$projection_in_sync" \
  --argjson nodeActiveOk "$node_active_ok" \
  --argjson dnsStateAvailable "$dns_state_available" \
  --slurpfile workerCurrent "$worker_current_file" \
  --slurpfile nodeState "$node_state_file" \
  --slurpfile dnsState "$dns_state_file" \
  --slurpfile aoNativeReadback "$ao_report_input" \
  --argjson admissionProbe "$admission_probe_json" \
  --argjson dueProbe "$due_probe_json" \
  --argjson forceProbe "$force_probe_json" \
  --arg releaseMetadataFile "$release_metadata_file" \
  '{
    generatedAt:$generatedAt,
    outputDir:$outputDir,
    workerProjectionUrl:$workerProjectionUrl,
    workerCurrentUrl:$workerCurrentUrl,
    nodeStateUrl:$nodeStateUrl,
    dnsStateUrl:$dnsStateUrl,
    readiness:{
      projectionInSync:$projectionInSync,
      nodeActiveOk:$nodeActiveOk,
      dnsStateAvailable:$dnsStateAvailable,
      aoReadHealthy: (($aoNativeReadback[0].readContractSummary.healthyActions // 0) > 0 and ($aoNativeReadback[0].readContractSummary.unhealthyActions // 0) == 0),
      aoReadPayloadAvailable: (($aoNativeReadback[0].readContractSummary.payloadActions // 0) > 0)
    },
    workerCurrent:$workerCurrent[0],
    nodeState:$nodeState[0],
    dnsState:$dnsState[0],
    aoNativeReadback: (
      if ($aoNativeReadback[0] // null) == null then
        null
      else
        {
          processId: ($aoNativeReadback[0].processId // null),
          generatedAt: ($aoNativeReadback[0].generatedAt // null),
          replyTo: ($aoNativeReadback[0].replyTo // null),
          summary: ($aoNativeReadback[0].readContractSummary // null),
          actions: (($aoNativeReadback[0].results // []) | map({
            action,
            method,
            available,
            detail,
            readContract: (.readContract // null),
            runtimeEffect: (.runtimeEffect // null)
          }))
        }
      end
    ),
    probes:{
      admission:$admissionProbe,
      dueHosts:$dueProbe,
      forceRefresh:$forceProbe
    },
    releaseDryRun:{
      executed: ($releaseMetadataFile != ""),
      metadataFile: (if $releaseMetadataFile == "" then null else $releaseMetadataFile end)
    }
  }' >"$report_file"

echo "dynamic mode scout complete"
echo "  outputDir=$OUTPUT_DIR"
echo "  report=$report_file"
echo "  projectionInSync=$projection_in_sync"
echo "  nodeActiveOk=$node_active_ok"
echo "  dnsStateAvailable=$dns_state_available"
if [[ -n "$AOCONNECT_REPORT_PATH" ]]; then
  echo "  aoReadHealthy=$(jq -r '.readiness.aoReadHealthy' "$report_file")"
  echo "  aoReadPayloadAvailable=$(jq -r '.readiness.aoReadPayloadAvailable' "$report_file")"
fi
echo "  admissionHttp=$(jq -r '.httpCode' <<<"$admission_probe_json")"
echo "  dueHostsHttp=$(jq -r '.httpCode' <<<"$due_probe_json")"
echo "  forceRefreshHttp=$(jq -r '.httpCode' <<<"$force_probe_json")"
