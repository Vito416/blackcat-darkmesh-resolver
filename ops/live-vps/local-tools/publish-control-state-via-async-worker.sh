#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  publish-control-state-via-async-worker.sh \
    --report /path/to/dynamic-mode-scout-report.json

Optional AO-derived inputs:
  --admission-state /path/to/admission-state.json
  --due-hosts-state /path/to/due-hosts-state.json
  --dns-refresh-state /path/to/dns-refresh-state.json
  --dry-run

Auth:
  export RESOLVER_CONTROL_AUTH_TOKEN=...
  or pass --auth-token <token>

Live publish:
  --worker-url https://async.example.workers.dev/resolver/control/state/publish
USAGE
}

WORKER_URL=""
REPORT_PATH=""
ADMISSION_STATE_PATH=""
DUE_HOSTS_STATE_PATH=""
DNS_REFRESH_STATE_PATH=""
AUTH_TOKEN="${RESOLVER_CONTROL_AUTH_TOKEN:-}"
REQUEST_ID="resolver-control-state-$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_PATH=""
DRY_RUN=0

validate_json_file() {
  local label="$1"
  local path="$2"
  local filter="$3"
  if ! jq -e "$filter" "$path" >/dev/null; then
    echo "invalid ${label} JSON: $path" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-url) WORKER_URL="$2"; shift 2 ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --admission-state) ADMISSION_STATE_PATH="$2"; shift 2 ;;
    --due-hosts-state) DUE_HOSTS_STATE_PATH="$2"; shift 2 ;;
    --dns-refresh-state) DNS_REFRESH_STATE_PATH="$2"; shift 2 ;;
    --auth-token) AUTH_TOKEN="$2"; shift 2 ;;
    --request-id) REQUEST_ID="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$REPORT_PATH" ]] || { echo "--report required" >&2; exit 2; }
[[ -f "$REPORT_PATH" ]] || { echo "report file not found: $REPORT_PATH" >&2; exit 2; }
[[ -z "$ADMISSION_STATE_PATH" || -f "$ADMISSION_STATE_PATH" ]] || { echo "admission state file not found: $ADMISSION_STATE_PATH" >&2; exit 2; }
[[ -z "$DUE_HOSTS_STATE_PATH" || -f "$DUE_HOSTS_STATE_PATH" ]] || { echo "due hosts state file not found: $DUE_HOSTS_STATE_PATH" >&2; exit 2; }
[[ -z "$DNS_REFRESH_STATE_PATH" || -f "$DNS_REFRESH_STATE_PATH" ]] || { echo "dns refresh state file not found: $DNS_REFRESH_STATE_PATH" >&2; exit 2; }
if (( ! DRY_RUN )); then
  [[ -n "$WORKER_URL" ]] || { echo "--worker-url required" >&2; exit 2; }
  [[ -n "$AUTH_TOKEN" ]] || { echo "auth token required via RESOLVER_CONTROL_AUTH_TOKEN or --auth-token" >&2; exit 2; }
fi

validate_json_file "report" "$REPORT_PATH" '
  type == "object"
  and (.generatedAt? | type == "string")
  and (.readiness? | type == "object")
  and (.probes? | type == "object")
'
if [[ -n "$ADMISSION_STATE_PATH" ]]; then
  validate_json_file "admission state" "$ADMISSION_STATE_PATH" '
    type == "object"
    and (.schemaVersion? | type == "string")
    and (.admission? | type == "object")
  '
fi
if [[ -n "$DUE_HOSTS_STATE_PATH" ]]; then
  validate_json_file "due hosts state" "$DUE_HOSTS_STATE_PATH" '
    type == "object"
    and (.schemaVersion? | type == "string")
    and (.counts? | type == "object")
    and ((.dueHosts // []) | type == "array")
  '
fi
if [[ -n "$DNS_REFRESH_STATE_PATH" ]]; then
  validate_json_file "dns refresh state" "$DNS_REFRESH_STATE_PATH" '
    type == "object"
    and (.schemaVersion? | type == "string")
    and (.counts? | type == "object")
    and (.autoDns? | type == "object")
  '
fi

payload_tmp="$(mktemp)"
response_tmp="$(mktemp)"
admission_tmp="$(mktemp)"
due_tmp="$(mktemp)"
dns_refresh_tmp="$(mktemp)"
trap 'rm -f "$payload_tmp" "$response_tmp" "$admission_tmp" "$due_tmp" "$dns_refresh_tmp"' EXIT

if [[ -n "$ADMISSION_STATE_PATH" ]]; then
  cp "$ADMISSION_STATE_PATH" "$admission_tmp"
fi
if [[ -n "$DUE_HOSTS_STATE_PATH" ]]; then
  cp "$DUE_HOSTS_STATE_PATH" "$due_tmp"
fi
if [[ -n "$DNS_REFRESH_STATE_PATH" ]]; then
  cp "$DNS_REFRESH_STATE_PATH" "$dns_refresh_tmp"
fi

jq -n \
  --arg requestId "$REQUEST_ID" \
  --slurpfile report "$REPORT_PATH" \
  --rawfile admissionRaw "$admission_tmp" \
  --rawfile dueRaw "$due_tmp" \
  --rawfile dnsRefreshRaw "$dns_refresh_tmp" \
  '
  def aoAction($name):
    ((($report[0].aoNativeReadback.actions // []) | map(select(.action == $name)) | .[0]) // null);
  def aoContractSummary($name):
    (aoAction($name)) as $row
    | if $row == null then null else {
        state: ($row.readContract.state // null),
        healthy: ($row.readContract.healthy // false),
        payloadAvailable: ($row.readContract.payloadAvailable // false),
        carrier: ($row.readContract.carrier // null),
        sourceAction: ($row.readContract.sourceAction // null),
        detail: ($row.readContract.detail // ($row.detail // null)),
        method: ($row.method // null)
      } end;
  ($admissionRaw | if . == "" then null else fromjson end) as $admission
  | ($dueRaw | if . == "" then null else fromjson end) as $due
  | ($dnsRefreshRaw | if . == "" then null else fromjson end) as $dnsRefresh
  | {
    requestId: $requestId,
    state: {
      schemaVersion: "resolver-control-state.v1",
      generatedAt: ($report[0].generatedAt // (now | todateiso8601)),
      source: {
        kind: "dynamic-mode-scout",
        workerCurrentUrl: ($report[0].workerCurrentUrl // null),
        nodeStateUrl: ($report[0].nodeStateUrl // null),
        dnsStateUrl: ($report[0].dnsStateUrl // null)
      },
      projectionSummary: {
        sequence: ($report[0].workerCurrent.sequence // null),
        keyId: ($report[0].workerCurrent.keyId // null),
        payloadHash: ($report[0].workerCurrent.payloadHash // null),
        projectionInSync: ($report[0].readiness.projectionInSync // false),
        nodeActiveOk: ($report[0].readiness.nodeActiveOk // false),
        dnsStateAvailable: ($report[0].readiness.dnsStateAvailable // false)
      },
      aoNativeReadbackSummary: (
        if ($report[0].aoNativeReadback.summary // null) == null then
          null
        else {
          processId: ($report[0].aoNativeReadback.processId // null),
          generatedAt: ($report[0].aoNativeReadback.generatedAt // null),
          healthyActions: ($report[0].aoNativeReadback.summary.healthyActions // 0),
          payloadActions: ($report[0].aoNativeReadback.summary.payloadActions // 0),
          runtimeEffectOnlyActions: ($report[0].aoNativeReadback.summary.runtimeEffectOnlyActions // 0),
          unhealthyActions: ($report[0].aoNativeReadback.summary.unhealthyActions // 0),
          states: ($report[0].aoNativeReadback.summary.states // {})
        }
        end
      ),
      dnsRefreshSummary: {
        available: (
          if $dnsRefresh != null
          then (($dnsRefresh.schemaVersion // null) != null)
          else (($report[0].dnsState.schemaVersion // null) != null)
          end
        ),
        trackedHosts: (
          if $dnsRefresh != null
          then ($dnsRefresh.counts.trackedHosts // null)
          else ($report[0].dnsState.counts.trackedHosts // null)
          end
        ),
        dueNow: (
          if $dnsRefresh != null
          then ($dnsRefresh.counts.dueNow // null)
          else null
          end
        ),
        withPendingRequest: (
          if $dnsRefresh != null
          then ($dnsRefresh.counts.withPendingRequest // null)
          else ($report[0].dnsState.counts.withPendingRequest // null)
          end
        ),
        autoDnsEnabled: (
          if $dnsRefresh != null
          then ($dnsRefresh.autoDns.enabled // null)
          else ($report[0].dnsState.autoDns.enabled // null)
          end
        ),
        projectionMode: ($report[0].dnsState.projection.mode // null),
        projectionReason: ($report[0].dnsState.projection.reason // null),
        source: (if $dnsRefresh != null then "ao-derived" else "scout-probe" end),
        aoReadContract: aoContractSummary("GetDnsRefreshState")
      },
      admissionSummary: {
        available: (
          if $admission != null
          then (($admission.schemaVersion // null) != null and ($admission.admission // null) != null)
          else (($report[0].probes.admission.httpCode // 0) == 200)
          end
        ),
        httpCode: (
          if $admission != null
          then 200
          else ($report[0].probes.admission.httpCode // null)
          end
        ),
        allowlistEnabled: (
          if $admission != null
          then ($admission.admission.allowlistEnabled // null)
          else null
          end
        ),
        allowCount: (
          if $admission != null
          then ($admission.admission.allowCount // null)
          else null
          end
        ),
        denyCount: (
          if $admission != null
          then ($admission.admission.denyCount // null)
          else null
          end
        ),
        updatedAt: (
          if $admission != null
          then ($admission.admission.updatedAt // null)
          else null
          end
        ),
        source: (if $admission != null then "ao-derived" else "scout-probe" end),
        aoReadContract: aoContractSummary("GetAdmissionState"),
        note: (
          if $admission != null
          then null
          elif ($report[0].probes.admission.httpCode // 0) == 404
          then "not_exposed_yet"
          else null
          end
        )
      },
      dueHostsSummary: {
        available: (
          if $due != null
          then (($due.schemaVersion // null) != null)
          else (($report[0].probes.dueHosts.httpCode // 0) == 200)
          end
        ),
        httpCode: (
          if $due != null
          then 200
          else ($report[0].probes.dueHosts.httpCode // null)
          end
        ),
        trackedHosts: (
          if $due != null
          then ($due.counts.trackedHosts // null)
          else null
          end
        ),
        returned: (
          if $due != null
          then ($due.counts.returned // null)
          else null
          end
        ),
        limit: (
          if $due != null
          then ($due.limit // null)
          else null
          end
        ),
        sampleHosts: (
          if $due != null
          then (($due.dueHosts // []) | map(.host) | .[:10])
          else null
          end
        ),
        source: (if $due != null then "ao-derived" else "scout-probe" end),
        aoReadContract: aoContractSummary("ListHostsDueForDnsRefresh"),
        note: (
          if $due != null
          then null
          elif ($report[0].probes.dueHosts.httpCode // 0) == 404
          then "not_exposed_yet"
          else null
          end
        )
      },
      forceRefreshSurface: {
        available: (($report[0].probes.forceRefresh.httpCode // 0) == 200),
        httpCode: ($report[0].probes.forceRefresh.httpCode // null),
        note: (if ($report[0].probes.forceRefresh.httpCode // 0) == 404 then "not_exposed_yet" else null end)
      }
    }
  }' >"$payload_tmp"

if (( DRY_RUN )); then
  if [[ -n "$OUTPUT_PATH" ]]; then
    cp "$payload_tmp" "$OUTPUT_PATH"
  else
    cat "$payload_tmp"
  fi
  echo "prepared control state payload"
  echo "  requestId=$(jq -r '.requestId // empty' "$payload_tmp")"
  echo "  generatedAt=$(jq -r '.state.generatedAt // empty' "$payload_tmp")"
  echo "  admissionSource=$(jq -r '.state.admissionSummary.source // empty' "$payload_tmp")"
  echo "  admissionAoReadState=$(jq -r '.state.admissionSummary.aoReadContract.state // empty' "$payload_tmp")"
  echo "  dueHostsSource=$(jq -r '.state.dueHostsSummary.source // empty' "$payload_tmp")"
  echo "  dueHostsAoReadState=$(jq -r '.state.dueHostsSummary.aoReadContract.state // empty' "$payload_tmp")"
  echo "  dnsRefreshSource=$(jq -r '.state.dnsRefreshSummary.source // empty' "$payload_tmp")"
  echo "  dnsRefreshAoReadState=$(jq -r '.state.dnsRefreshSummary.aoReadContract.state // empty' "$payload_tmp")"
  exit 0
fi

curl -fsS \
  -H "authorization: Bearer ${AUTH_TOKEN}" \
  -H 'content-type: application/json' \
  -X POST "$WORKER_URL" \
  --data-binary @"$payload_tmp" >"$response_tmp"

jq -e '.ok == true and .published == true' "$response_tmp" >/dev/null

if [[ -n "$OUTPUT_PATH" ]]; then
  cp "$response_tmp" "$OUTPUT_PATH"
fi

echo "published control state"
echo "  requestId=$(jq -r '.requestId // empty' "$response_tmp")"
echo "  generatedAt=$(jq -r '.generatedAt // empty' "$response_tmp")"
echo "  schemaVersion=$(jq -r '.schemaVersion // empty' "$response_tmp")"
