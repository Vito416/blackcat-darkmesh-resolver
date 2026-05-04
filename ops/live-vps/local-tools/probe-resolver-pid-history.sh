#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
AO_REPO_DIR_DEFAULT="${WORKSPACE_ROOT}/blackcat-darkmesh-ao"

PID=""
BASE_URL="https://write.darkmesh.fun"
TIMEOUT=20
SLOT_MAX=12
READINESS_TIMEOUT=180
READINESS_INTERVAL=5
OUTPUT_DIR=""
SMOKE_WALLET=""
SMOKE_ACTION="GetResolverState"
STRICT_SMOKE=0
REQUIRE_SEMANTIC_SMOKE=0
AO_REPO_DIR="${AO_REPO_DIR:-${AO_REPO_DIR_DEFAULT}}"

usage() {
  cat <<'USAGE'
Probe resolver process replay health without touching live alias cutover.

Usage:
  probe-resolver-pid-history.sh --pid <process-id> [options]

Options:
  --pid <id>                    Resolver process PID to probe. Required.
  --base-url <url>              HyperBeam/write base URL.
                                Default: https://write.darkmesh.fun
  --slot-max <n>                Maximum slot to replay during the sweep.
                                Default: 12
  --timeout <s>                 Per-request timeout for curl probes.
                                Default: 20
  --readiness-timeout <s>       Wait up to N seconds for compute replay to
                                become readable after scheduler smoke.
                                Default: 180
  --readiness-interval <s>      Poll interval during replay readiness wait.
                                Default: 5
  --output-dir <path>           Directory for JSON reports.
                                Default: mktemp dir
  --wallet <path>               Optional wallet for signed scheduler smoke.
  --smoke-action <name>         Action used by the signed smoke.
                                Default: GetResolverState
  --strict-smoke <0|1>          Ask smoke helper to require semantic Output shape.
                                Useful for diagnostics, but can false-negative on
                                healthy AO runtime-effect. Default: 0
  --require-semantic-smoke <0|1>
                                Fail candidate only on semantic output failure.
                                Legacy diagnostic mode; runtime-effect health is
                                reported separately. Default: 0
  --ao-repo-dir <path>          Path to adjacent blackcat-darkmesh-ao repo.
                                Default: ../blackcat-darkmesh-ao
  -h, --help                    Show help.
USAGE
}

clean_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "${value}"
}

read_slot_current() {
  local slot_file slot_code slot_body
  slot_file="$(mktemp)"
  slot_code="$(curl -sS --max-time "${TIMEOUT}" -o "${slot_file}" -w '%{http_code}' "${BASE_URL}/${PID}~process@1.0/slot/current?accept-bundle=true" || true)"
  slot_body="$(tr -d '\r\n' < "${slot_file}")"
  rm -f "${slot_file}"
  if [[ "${slot_code}" == "200" && "${slot_body}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${slot_body}"
  fi
}

wait_for_compute_slot() {
  local slot="$1"
  local deadline now code
  local body_file
  deadline=$(( $(date +%s) + READINESS_TIMEOUT ))
  while true; do
    body_file="$(mktemp)"
    code="$(curl -sS --max-time "${TIMEOUT}" -o "${body_file}" -w '%{http_code}' "${BASE_URL}/${PID}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json" || true)"
    rm -f "${body_file}"
    if [[ "${code}" == "200" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      return 1
    fi
    sleep "${READINESS_INTERVAL}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid) PID="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --slot-max) SLOT_MAX="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --readiness-timeout) READINESS_TIMEOUT="${2:-}"; shift 2 ;;
    --readiness-interval) READINESS_INTERVAL="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --wallet) SMOKE_WALLET="${2:-}"; shift 2 ;;
    --smoke-action) SMOKE_ACTION="${2:-}"; shift 2 ;;
    --strict-smoke) STRICT_SMOKE="${2:-}"; shift 2 ;;
    --require-semantic-smoke) REQUIRE_SEMANTIC_SMOKE="${2:-}"; shift 2 ;;
    --ao-repo-dir) AO_REPO_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${PID}" ]]; then
  echo "--pid is required" >&2
  exit 2
fi
if ! [[ "${SLOT_MAX}" =~ ^[0-9]+$ ]] || [[ "${SLOT_MAX}" -lt 1 ]]; then
  echo "--slot-max must be a positive integer" >&2
  exit 2
fi
if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT}" -lt 1 ]]; then
  echo "--timeout must be a positive integer" >&2
  exit 2
fi
for value_name in READINESS_TIMEOUT READINESS_INTERVAL; do
  value="${!value_name}"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]]; then
    echo "--${value_name,,} must be a positive integer" >&2
    exit 2
  fi
done
if [[ "${STRICT_SMOKE}" != "0" && "${STRICT_SMOKE}" != "1" ]]; then
  echo "--strict-smoke must be 0 or 1" >&2
  exit 2
fi
if [[ "${REQUIRE_SEMANTIC_SMOKE}" != "0" && "${REQUIRE_SEMANTIC_SMOKE}" != "1" ]]; then
  echo "--require-semantic-smoke must be 0 or 1" >&2
  exit 2
fi

BASE_URL="$(clean_url "${BASE_URL}")"
if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "${OUTPUT_DIR}"
fi

initial_slot_current="$(read_slot_current || true)"

smoke_report_file="${OUTPUT_DIR}/scheduler-smoke.json"
smoke_status="skipped"
smoke_exit_code=""
smoke_ok="false"

if [[ -n "${SMOKE_WALLET}" ]]; then
  smoke_script="${AO_REPO_DIR}/scripts/deploy/smoke_push_scheduler.mjs"
  if [[ ! -f "${smoke_script}" ]]; then
    echo "missing smoke script: ${smoke_script}" >&2
    exit 2
  fi
  smoke_cmd=(node "${smoke_script}" --pid "${PID}" --url "${BASE_URL}" --wallet "${SMOKE_WALLET}" --action "${SMOKE_ACTION}")
  if [[ "${STRICT_SMOKE}" == "1" ]]; then
    smoke_cmd+=(--strict-response true)
  fi
  set +e
  "${smoke_cmd[@]}" > "${smoke_report_file}" 2>&1
  smoke_rc=$?
  set -e
  if [[ "${smoke_rc}" == "0" ]]; then
    smoke_status="ok"
    smoke_exit_code="0"
    smoke_ok="true"
  else
    smoke_status="failed"
    smoke_exit_code="${smoke_rc}"
    smoke_ok="false"
  fi
else
  jq -cn '{ok:false,skipped:true,reason:"wallet_not_provided"}' > "${smoke_report_file}"
fi

slot_current="$(read_slot_current || true)"
if [[ -z "${slot_current}" ]]; then
  slot_current="${initial_slot_current}"
fi

replayReady="false"
replayReadySlot=""
if [[ -n "${slot_current}" && "${slot_current}" =~ ^[0-9]+$ && "${slot_current}" -gt 0 ]]; then
  replayReadySlot="${slot_current}"
  if wait_for_compute_slot "${slot_current}"; then
    replayReady="true"
  fi
fi

sweep_limit=0
if [[ -n "${slot_current}" ]]; then
  if (( slot_current < SLOT_MAX )); then
    sweep_limit="${slot_current}"
  else
    sweep_limit="${SLOT_MAX}"
  fi
fi

slots_jsonl="$(mktemp)"
first_failure_slot=""

for (( slot = 1; slot <= sweep_limit; slot += 1 )); do
  url="${BASE_URL}/${PID}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json"
  body_file="$(mktemp)"
  code="$(curl -sS --max-time "${TIMEOUT}" -o "${body_file}" -w '%{http_code}' "${url}" || true)"
  body="$(cat "${body_file}")"
  rm -f "${body_file}"
  preview="$(printf '%s' "${body}" | tr '\n' ' ')"
  preview="${preview:0:220}"
  at_slot=""
  status_field=""
  error_summary=""
  if [[ -n "${body}" ]]; then
    at_slot="$(jq -r '.["at-slot"] // .atSlot // empty' <<<"${body}" 2>/dev/null || true)"
    status_field="$(jq -r '.status // .results.raw.Output.status // .raw.Output.status // empty' <<<"${body}" 2>/dev/null || true)"
    error_summary="$(jq -r '.results.raw.Error // .raw.Error // .Error // empty | tostring' <<<"${body}" 2>/dev/null || true)"
  fi
  ok=0
  if [[ "${code}" == "200" ]]; then
    ok=1
  fi
  if [[ -z "${first_failure_slot}" && "${ok}" != "1" ]]; then
    first_failure_slot="${slot}"
  fi
  jq -cn \
    --argjson slot "${slot}" \
    --arg url "${url}" \
    --arg code "${code}" \
    --arg preview "${preview}" \
    --arg atSlot "${at_slot}" \
    --arg statusField "${status_field}" \
    --arg errorSummary "${error_summary}" \
    --argjson ok "${ok}" \
    '{slot:$slot,url:$url,httpCode:$code,ok:($ok == 1),atSlot:($atSlot // ""),statusField:($statusField // ""),errorSummary:($errorSummary // ""),bodyPreview:$preview}' \
    >> "${slots_jsonl}"
done

slots_array_file="${OUTPUT_DIR}/slot-sweep.json"
jq -s '.' "${slots_jsonl}" > "${slots_array_file}"
rm -f "${slots_jsonl}"

report_file="${OUTPUT_DIR}/probe-report.json"
jq -n \
  --arg pid "${PID}" \
  --arg baseUrl "${BASE_URL}" \
  --arg initialSlotCurrent "${initial_slot_current}" \
  --arg slotCurrent "${slot_current}" \
  --argjson sweepLimit "${sweep_limit}" \
  --arg firstFailureSlot "${first_failure_slot}" \
  --arg replayReady "${replayReady}" \
  --arg replayReadySlot "${replayReadySlot}" \
  --arg smokeStatus "${smoke_status}" \
  --arg smokeExitCode "${smoke_exit_code}" \
  --argjson requireSemanticSmoke "${REQUIRE_SEMANTIC_SMOKE}" \
  --argjson strictSmoke "${STRICT_SMOKE}" \
  --argjson smokeOk "${smoke_ok}" \
  --slurpfile slots "${slots_array_file}" \
  --slurpfile smokeReport "${smoke_report_file}" \
  '
  def has_meaningful(v):
    if v == null then false
    elif (v | type) == "string" then (v | gsub("^[[:space:]]+|[[:space:]]+$"; "") | length) > 0
    elif (v | type) == "array" then (v | length) > 0
    elif (v | type) == "object" then (v | length) > 0
    else true end;
  def smoke_runtime_summary(report):
    (report.compute // {}) as $compute
    | ($compute.parsedSummary // {}) as $parsed
    | {
        transportOk: (($compute.status // 0) == 200),
        atSlot: ($parsed.atSlot // null),
        hasResults: ($parsed.hasResults == true),
        hasError: ($parsed.hasError == true),
        outputShape: ($compute.outputSummary.outputShape // null),
        semanticOk: ($compute.outputSummary.semanticOk == true),
        runtimeEffectOk: (
          (($compute.status // 0) == 200)
          and ($parsed.hasError != true)
          and ((($parsed.hasResults == true) or ($parsed.atSlot != null)))
        ),
        runtimeEffectReason: (
          if (($compute.status // 0) != 200) then "compute_not_ok"
          elif ($parsed.hasError == true) then "runtime_error"
          elif (($parsed.hasResults == true) or ($parsed.atSlot != null)) then "runtime_effect_observed"
          else "empty_runtime_payload"
          end
        )
      };
  {
    pid: $pid,
    baseUrl: $baseUrl,
    initialSlotCurrent: (if $initialSlotCurrent == "" then null else ($initialSlotCurrent | tonumber) end),
    slotCurrent: (if $slotCurrent == "" then null else ($slotCurrent | tonumber) end),
    replayReady: ($replayReady == "true"),
    replayReadySlot: (if $replayReadySlot == "" then null else ($replayReadySlot | tonumber) end),
    sweepLimit: $sweepLimit,
    firstFailureSlot: (if $firstFailureSlot == "" then null else ($firstFailureSlot | tonumber) end),
    replayHealthy: ($firstFailureSlot == "" and $sweepLimit > 0),
    semanticSmoke: {
      status: $smokeStatus,
      exitCode: (if $smokeExitCode == "" then null else ($smokeExitCode | tonumber) end),
      strict: ($strictSmoke == 1),
      required: ($requireSemanticSmoke == 1),
      ok: $smokeOk,
      report: ($smokeReport[0] // {}),
      runtimeSummary: smoke_runtime_summary($smokeReport[0] // {})
    },
    slots: ($slots[0] // [])
  }
  ' > "${report_file}"

cat "${report_file}"

overall_ok=0
if [[ -n "${slot_current}" && -z "${first_failure_slot}" && "${sweep_limit}" -gt 0 ]]; then
  overall_ok=1
fi
if [[ "${REQUIRE_SEMANTIC_SMOKE}" == "1" && "${smoke_ok}" != "true" ]]; then
  overall_ok=0
fi

if [[ "${overall_ok}" != "1" ]]; then
  exit 1
fi
