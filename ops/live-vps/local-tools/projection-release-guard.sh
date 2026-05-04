#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  projection-release-guard.sh [options]

Minimal control-plane freshness guard for signed resolver projections.

What it does:
  1. fetches current published projection from async-worker
  2. checks remaining validity window (`expiresAt - now`)
  3. if still healthy, exits without publishing
  4. if missing / expiring soon / forced, runs projection-release.sh

Examples:
  projection-release-guard.sh \
    --domains jdwt.fun,vddl.fun,blgateway.fun \
    --worker-base-url https://blackcat-async-worker.example.workers.dev \
    --control-state-url https://blackcat-async-worker.example.workers.dev/resolver/control/state/current \
    --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState \
    --min-valid-sec 1800 \
    --release-ttl-sec 86400

Auth:
  export RESOLVER_SIGNER_AUTH_TOKEN=...
  export RESOLVER_PUBLISH_AUTH_TOKEN=...
  export RESOLVER_CONTROL_AUTH_TOKEN=...

Options:
  --domains <csv>               Comma-separated domains.
  --domains-file <path>         One domain per line.
  --worker-base-url <url>       Async worker base URL.
  --control-state-url <url>     Optional authenticated control-state current URL.
                                No default in minimal-exposed-surface mode.
  --control-auth-token <token>  Optional bearer token for control-state fetch.
  --min-valid-sec <n>           Minimum remaining validity required to skip release.
                                Default: 1800
  --release-ttl-sec <n>         TTL for newly published projection. Default: 86400
  --refresh-cadence-sec <n>     cacheHints.refreshCadenceSec for release. Default: 300
  --lkg-max-age-sec <n>         cacheHints.lkgMaxAgeSec for release. Default: 3600
  --verify-node-state-url <u>   Forwarded to projection-release.sh, can repeat.
  --output-dir <path>           Output dir. Default: mktemp
  --force                       Publish even if current projection is still healthy.
  --dry-run                     Evaluate guard, but do not publish.
  -h, --help                    Show help.
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

WORKER_BASE_URL="${DARKMESH_ASYNC_WORKER_BASE_URL:-}"
CONTROL_STATE_URL="${DARKMESH_RESOLVER_CONTROL_STATE_URL:-}"
CONTROL_AUTH_TOKEN="${RESOLVER_CONTROL_AUTH_TOKEN:-}"
DOMAINS_CSV=""
DOMAINS_FILE=""
OUTPUT_DIR=""
MIN_VALID_SEC=1800
RELEASE_TTL_SEC=86400
REFRESH_CADENCE_SEC=300
LKG_MAX_AGE_SEC=3600
FORCE=0
DRY_RUN=0
declare -a VERIFY_NODE_STATE_URLS=()
declare -a POSITIONAL_DOMAINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domains) DOMAINS_CSV="${2:-}"; shift 2 ;;
    --domains-file) DOMAINS_FILE="${2:-}"; shift 2 ;;
    --worker-base-url) WORKER_BASE_URL="${2:-}"; shift 2 ;;
    --control-state-url) CONTROL_STATE_URL="${2:-}"; shift 2 ;;
    --control-auth-token) CONTROL_AUTH_TOKEN="${2:-}"; shift 2 ;;
    --min-valid-sec) MIN_VALID_SEC="${2:-}"; shift 2 ;;
    --release-ttl-sec) RELEASE_TTL_SEC="${2:-}"; shift 2 ;;
    --refresh-cadence-sec) REFRESH_CADENCE_SEC="${2:-}"; shift 2 ;;
    --lkg-max-age-sec) LKG_MAX_AGE_SEC="${2:-}"; shift 2 ;;
    --verify-node-state-url) VERIFY_NODE_STATE_URLS+=("${2:-}"); shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL_DOMAINS+=("$1"); shift; done ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL_DOMAINS+=("$1"); shift ;;
  esac
done

require_cmd curl
require_cmd jq
require_cmd python3
bash -n "$RELEASE_SCRIPT" >/dev/null

[[ -n "$WORKER_BASE_URL" ]] || {
  echo "--worker-base-url or DARKMESH_ASYNC_WORKER_BASE_URL is required" >&2
  exit 2
}

if [[ -z "$DOMAINS_CSV" && -z "$DOMAINS_FILE" && "${#POSITIONAL_DOMAINS[@]}" -eq 0 ]]; then
  echo "provide domains via --domains, --domains-file, or positional args" >&2
  exit 2
fi

for pair in \
  "MIN_VALID_SEC:$MIN_VALID_SEC" \
  "RELEASE_TTL_SEC:$RELEASE_TTL_SEC" \
  "REFRESH_CADENCE_SEC:$REFRESH_CADENCE_SEC" \
  "LKG_MAX_AGE_SEC:$LKG_MAX_AGE_SEC"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "${name} must be a positive integer" >&2
    exit 2
  fi
done

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "$OUTPUT_DIR"
fi

CURRENT_URL="${WORKER_BASE_URL%/}/resolver/projection/current"
CURRENT_PATH="$OUTPUT_DIR/current-projection.json"
CONTROL_STATE_PATH="$OUTPUT_DIR/control-state-current.json"
DECISION_PATH="$OUTPUT_DIR/guard-decision.json"

current_code="$(curl -sS -o "$CURRENT_PATH" -w '%{http_code}' "$CURRENT_URL" || true)"
now_epoch="$(date -u +%s)"

should_release=false
reason=""
current_sequence=""
current_expires_at=""
current_expires_epoch=""
remaining_sec=0
control_state_http_code=""
control_state_fetched=false
ao_read_healthy=false
ao_read_payload_available=false
ao_read_runtime_effect_only_actions=0
ao_read_unhealthy_actions=0
ao_read_process_id=""
control_state_detail="skipped"

if [[ "$current_code" != "200" ]]; then
  should_release=true
  reason="current_projection_missing"
else
  current_sequence="$(jq -r '.sequence // empty' "$CURRENT_PATH")"
  current_expires_at="$(jq -r '.expiresAt // empty' "$CURRENT_PATH")"
  if [[ -z "$current_expires_at" ]]; then
    should_release=true
    reason="current_projection_missing_expires_at"
  else
    current_expires_epoch="$(python3 - "$current_expires_at" <<'PY'
import datetime, sys
raw = sys.argv[1]
try:
    dt = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    print(int(dt.timestamp()))
except Exception:
    print("")
PY
)"
    if [[ -z "$current_expires_epoch" ]]; then
      should_release=true
      reason="current_projection_invalid_expires_at"
    else
      remaining_sec=$(( current_expires_epoch - now_epoch ))
      if (( remaining_sec <= MIN_VALID_SEC )); then
        should_release=true
        reason="remaining_validity_below_threshold"
      else
        reason="current_projection_still_healthy"
      fi
    fi
  fi
fi

if [[ -n "$CONTROL_AUTH_TOKEN" && -n "$CONTROL_STATE_URL" ]]; then
  control_state_http_code="$(curl -sS -o "$CONTROL_STATE_PATH" -w '%{http_code}' -H "authorization: Bearer ${CONTROL_AUTH_TOKEN}" "$CONTROL_STATE_URL" || true)"
  if [[ "$control_state_http_code" == "200" ]]; then
    control_state_fetched=true
    if jq -e '.state.aoNativeReadbackSummary != null' "$CONTROL_STATE_PATH" >/dev/null 2>&1; then
      ao_read_process_id="$(jq -r '.state.aoNativeReadbackSummary.processId // empty' "$CONTROL_STATE_PATH")"
      ao_read_runtime_effect_only_actions="$(jq -r '.state.aoNativeReadbackSummary.runtimeEffectOnlyActions // 0' "$CONTROL_STATE_PATH")"
      ao_read_unhealthy_actions="$(jq -r '.state.aoNativeReadbackSummary.unhealthyActions // 0' "$CONTROL_STATE_PATH")"
      if jq -e '(.state.aoNativeReadbackSummary.healthyActions // 0) > 0 and (.state.aoNativeReadbackSummary.unhealthyActions // 0) == 0' "$CONTROL_STATE_PATH" >/dev/null 2>&1; then
        ao_read_healthy=true
      fi
      if jq -e '(.state.aoNativeReadbackSummary.payloadActions // 0) > 0' "$CONTROL_STATE_PATH" >/dev/null 2>&1; then
        ao_read_payload_available=true
      fi
      control_state_detail="ok"
    else
      control_state_detail="missing_ao_native_readback_summary"
    fi
  else
    control_state_detail="http_${control_state_http_code}"
  fi
elif [[ -n "$CONTROL_AUTH_TOKEN" ]]; then
  control_state_detail="skipped_no_control_state_url"
fi

if (( FORCE == 1 )); then
  should_release=true
  reason="forced"
fi

jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg workerBaseUrl "$WORKER_BASE_URL" \
  --arg currentUrl "$CURRENT_URL" \
  --arg currentHttpCode "$current_code" \
  --arg currentSequence "${current_sequence:-}" \
  --arg currentExpiresAt "${current_expires_at:-}" \
  --arg controlStateUrl "$CONTROL_STATE_URL" \
  --arg controlStateHttpCode "${control_state_http_code:-}" \
  --arg controlStateDetail "$control_state_detail" \
  --arg aoReadProcessId "${ao_read_process_id:-}" \
  --arg reason "$reason" \
  --arg outputDir "$OUTPUT_DIR" \
  --argjson shouldRelease "$should_release" \
  --argjson minValidSec "$MIN_VALID_SEC" \
  --argjson releaseTtlSec "$RELEASE_TTL_SEC" \
  --argjson refreshCadenceSec "$REFRESH_CADENCE_SEC" \
  --argjson lkgMaxAgeSec "$LKG_MAX_AGE_SEC" \
  --argjson force "$FORCE" \
  --argjson dryRun "$DRY_RUN" \
  --argjson remainingSec "$remaining_sec" \
  --argjson controlStateFetched "$control_state_fetched" \
  --argjson aoReadHealthy "$ao_read_healthy" \
  --argjson aoReadPayloadAvailable "$ao_read_payload_available" \
  --argjson aoReadRuntimeEffectOnlyActions "$ao_read_runtime_effect_only_actions" \
  --argjson aoReadUnhealthyActions "$ao_read_unhealthy_actions" \
  '{
    generatedAt:$generatedAt,
    workerBaseUrl:$workerBaseUrl,
    currentUrl:$currentUrl,
    currentHttpCode:($currentHttpCode|tonumber),
    currentSequence:(if $currentSequence == "" then null else ($currentSequence|tonumber) end),
    currentExpiresAt:(if $currentExpiresAt == "" then null else $currentExpiresAt end),
    remainingSec:$remainingSec,
    reason:$reason,
    shouldRelease:$shouldRelease,
    minValidSec:$minValidSec,
    releaseTtlSec:$releaseTtlSec,
    refreshCadenceSec:$refreshCadenceSec,
    lkgMaxAgeSec:$lkgMaxAgeSec,
    controlState: {
      url: $controlStateUrl,
      fetched: $controlStateFetched,
      httpCode: (if $controlStateHttpCode == "" then null else ($controlStateHttpCode|tonumber) end),
      detail: $controlStateDetail,
      aoReadHealthy: $aoReadHealthy,
      aoReadPayloadAvailable: $aoReadPayloadAvailable,
      aoReadRuntimeEffectOnlyActions: $aoReadRuntimeEffectOnlyActions,
      aoReadUnhealthyActions: $aoReadUnhealthyActions,
      aoReadProcessId: (if $aoReadProcessId == "" then null else $aoReadProcessId end)
    },
    force:($force == 1),
    dryRun:($dryRun == 1),
    outputDir:$outputDir
  }' >"$DECISION_PATH"

if [[ "$should_release" != "true" ]]; then
  echo "projection release guard: current snapshot is still healthy"
  echo "  sequence=${current_sequence:-unknown}"
  echo "  expiresAt=${current_expires_at:-unknown}"
  echo "  remainingSec=${remaining_sec}"
  if [[ -n "$CONTROL_AUTH_TOKEN" ]]; then
    echo "  aoReadHealthy=${ao_read_healthy}"
    echo "  aoReadPayloadAvailable=${ao_read_payload_available}"
    echo "  aoReadRuntimeEffectOnlyActions=${ao_read_runtime_effect_only_actions}"
  fi
  echo "  decision=$DECISION_PATH"
  exit 0
fi

echo "projection release guard: release required"
echo "  reason=$reason"
echo "  currentSequence=${current_sequence:-unknown}"
echo "  currentExpiresAt=${current_expires_at:-unknown}"
echo "  remainingSec=${remaining_sec}"
if [[ -n "$CONTROL_AUTH_TOKEN" ]]; then
  echo "  aoReadHealthy=${ao_read_healthy}"
  echo "  aoReadPayloadAvailable=${ao_read_payload_available}"
  echo "  aoReadRuntimeEffectOnlyActions=${ao_read_runtime_effect_only_actions}"
fi
echo "  decision=$DECISION_PATH"

if (( DRY_RUN == 1 )); then
  echo "dry-run requested; not publishing"
  exit 0
fi

release_args=(
  --worker-base-url "$WORKER_BASE_URL"
  --output-dir "$OUTPUT_DIR/release"
  --ttl-sec "$RELEASE_TTL_SEC"
  --refresh-cadence-sec "$REFRESH_CADENCE_SEC"
  --lkg-max-age-sec "$LKG_MAX_AGE_SEC"
)
[[ -n "$DOMAINS_CSV" ]] && release_args+=(--domains "$DOMAINS_CSV")
[[ -n "$DOMAINS_FILE" ]] && release_args+=(--domains-file "$DOMAINS_FILE")
for url in "${VERIFY_NODE_STATE_URLS[@]}"; do
  release_args+=(--verify-node-state-url "$url")
done
if (( ${#POSITIONAL_DOMAINS[@]} > 0 )); then
  release_args+=(-- "${POSITIONAL_DOMAINS[@]}")
fi

bash "$RELEASE_SCRIPT" "${release_args[@]}"
