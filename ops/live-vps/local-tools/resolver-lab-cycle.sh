#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"

CANDIDATE_SCRIPT="${REPO_ROOT}/ops/live-vps/local-tools/fresh-resolver-candidate.sh"
AOCONNECT_SCRIPT="${REPO_ROOT}/ops/live-vps/local-tools/fetch-ao-control-state-via-aoconnect.mjs"

WALLET=""
HB_URL="https://write.darkmesh.fun"
GRAPHQL_URL="http://127.0.0.1:18777/graphql"
GRAPHQL_SHIM_REMOTE_TARGET="${DARKMESH_GRAPHQL_SHIM_REMOTE_TARGET:-adminops@100.104.75.121}"
GRAPHQL_SHIM_REMOTE_SSH_KEY="${DARKMESH_GRAPHQL_SHIM_REMOTE_SSH_KEY:-$HOME/.ssh/darkmesh_new_vps_adminops}"
GRAPHQL_SHIM_REMOTE_PATH="${DARKMESH_GRAPHQL_SHIM_REMOTE_PATH:-/etc/darkmesh/graphql-shim-allowlist.txt}"
GRAPHQL_SHIM_REMOTE_WITH_SUDO="${DARKMESH_GRAPHQL_SHIM_REMOTE_WITH_SUDO:-1}"
SCHEDULER="${DARKMESH_AO_SCHEDULER:-_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM}"
OUTPUT_DIR=""
BUILD_WASM=1
EXECUTE_LIVE=1
RUN_AOCONNECT=1
ALLOW_REPLAY_UNSAFE_EXPERIMENTS=0
CAPTURE_AO_RESULT_PASSTHROUGH=0
PRESERVE_HANDLER_RESULT=0
TRACE_RUNTIME_PATH=0
TRACE_RESOLVER_ROUTE=0
INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP=0
DISABLE_RESOLVER_TOPLEVEL_WRAPPERS=0
AO_REPO_DIR="${WORKSPACE_ROOT}/blackcat-darkmesh-ao"
TIMEOUT_MS=20000
BUILD_ENV_OVERRIDES=()
FORWARD_ARGS=()

usage() {
  cat <<'USAGE'
Run the full shim-aware resolver lab cycle in one command:
  1. build/publish/spawn a fresh candidate (or reuse a module tx)
  2. auto-update the optional GraphQL shim allowlist
  3. gate on replay + execution health
  4. run AO readback over the resulting PID

Usage:
  resolver-lab-cycle.sh [options] [-- <extra fresh-resolver-candidate args>]

Core options:
  --wallet <path>                     Arweave wallet JWK. Required for live runs.
  --output-dir <path>                 Output directory. Default: mktemp dir
  --hb-url <url>                      Default: https://write.darkmesh.fun
  --graphql-url <url>                 Default: http://127.0.0.1:18777/graphql
  --graphql-shim-remote-target <u@h>  Default: adminops@100.104.75.121
  --graphql-shim-remote-ssh-key <p>   Default: ~/.ssh/darkmesh_new_vps_adminops
  --graphql-shim-remote-path <path>   Default: /etc/darkmesh/graphql-shim-allowlist.txt
  --graphql-shim-remote-with-sudo <0|1>
                                       Default: 1
  --scheduler <id>                    Default: _wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM
  --ao-repo-dir <path>                Default: ../blackcat-darkmesh-ao
  --build-wasm <0|1>                  Default: 1
  --execute-live <0|1>                Default: 1
  --run-aoconnect <0|1>               Default: 1
  --allow-replay-unsafe-experiments <0|1>
                                      Default: 0
  --timeout-ms <ms>                   aoconnect timeout. Default: 20000

Lab toggles for the composed resolver runtime wrapper:
  --capture-ao-result-passthrough <0|1>
  --preserve-handler-result <0|1>
  --trace-runtime-path <0|1>
  --trace-resolver-route <0|1>
  --inline-resolver-print-bridge-after-setup <0|1>
  --disable-resolver-toplevel-wrappers <0|1>
  --build-env <KEY=VALUE>             Repeatable extra env override for build wrapper.

Pass-through:
  Any args after `--` are forwarded directly to fresh-resolver-candidate.sh.

Outputs:
  <output-dir>/candidate/candidate-report.json
  <output-dir>/aoconnect/ao-control-state-aoconnect-report.json
  <output-dir>/resolver-lab-cycle-report.json
USAGE
}

clean_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "${value}"
}

require_bool() {
  local name="$1"
  local value="$2"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    echo "${name} must be 0 or 1" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wallet) WALLET="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --hb-url) HB_URL="${2:-}"; shift 2 ;;
    --graphql-url) GRAPHQL_URL="${2:-}"; shift 2 ;;
    --graphql-shim-remote-target) GRAPHQL_SHIM_REMOTE_TARGET="${2:-}"; shift 2 ;;
    --graphql-shim-remote-ssh-key) GRAPHQL_SHIM_REMOTE_SSH_KEY="${2:-}"; shift 2 ;;
    --graphql-shim-remote-path) GRAPHQL_SHIM_REMOTE_PATH="${2:-}"; shift 2 ;;
    --graphql-shim-remote-with-sudo) GRAPHQL_SHIM_REMOTE_WITH_SUDO="${2:-}"; shift 2 ;;
    --scheduler) SCHEDULER="${2:-}"; shift 2 ;;
    --ao-repo-dir) AO_REPO_DIR="${2:-}"; shift 2 ;;
    --build-wasm) BUILD_WASM="${2:-}"; shift 2 ;;
    --execute-live) EXECUTE_LIVE="${2:-}"; shift 2 ;;
    --run-aoconnect) RUN_AOCONNECT="${2:-}"; shift 2 ;;
    --allow-replay-unsafe-experiments) ALLOW_REPLAY_UNSAFE_EXPERIMENTS="${2:-}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:-}"; shift 2 ;;
    --capture-ao-result-passthrough) CAPTURE_AO_RESULT_PASSTHROUGH="${2:-}"; shift 2 ;;
    --preserve-handler-result) PRESERVE_HANDLER_RESULT="${2:-}"; shift 2 ;;
    --trace-runtime-path) TRACE_RUNTIME_PATH="${2:-}"; shift 2 ;;
    --trace-resolver-route) TRACE_RESOLVER_ROUTE="${2:-}"; shift 2 ;;
    --inline-resolver-print-bridge-after-setup) INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP="${2:-}"; shift 2 ;;
    --disable-resolver-toplevel-wrappers) DISABLE_RESOLVER_TOPLEVEL_WRAPPERS="${2:-}"; shift 2 ;;
    --build-env) BUILD_ENV_OVERRIDES+=("${2:-}"); shift 2 ;;
    --) shift; FORWARD_ARGS+=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for flag in \
  BUILD_WASM EXECUTE_LIVE RUN_AOCONNECT ALLOW_REPLAY_UNSAFE_EXPERIMENTS GRAPHQL_SHIM_REMOTE_WITH_SUDO \
  CAPTURE_AO_RESULT_PASSTHROUGH PRESERVE_HANDLER_RESULT TRACE_RUNTIME_PATH \
  TRACE_RESOLVER_ROUTE INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP \
  DISABLE_RESOLVER_TOPLEVEL_WRAPPERS
do
  require_bool "${flag}" "${!flag}"
done

if [[ "${ALLOW_REPLAY_UNSAFE_EXPERIMENTS}" != "1" ]]; then
  if [[ "${CAPTURE_AO_RESULT_PASSTHROUGH}" == "1" || "${PRESERVE_HANDLER_RESULT}" == "1" ]]; then
    echo "capture/preserve result experiments are replay-unsafe; rerun only with --allow-replay-unsafe-experiments 1" >&2
    exit 2
  fi
  for entry in "${BUILD_ENV_OVERRIDES[@]}"; do
    case "${entry}" in
      PROCESS_HANDLE_*=1|PROCESS_HANDLE_*=true|PROCESS_HANDLE_*=TRUE|PROCESS_HANDLE_*=yes|PROCESS_HANDLE_*=YES|PROCESS_HANDLE_*=on|PROCESS_HANDLE_*=ON|DIRECT_PROCESS_HANDLE_WRAPPER=1|DIRECT_PROCESS_HANDLE_WRAPPER=true|DIRECT_PROCESS_HANDLE_WRAPPER=TRUE|DIRECT_PROCESS_HANDLE_WRAPPER=yes|DIRECT_PROCESS_HANDLE_WRAPPER=YES|DIRECT_PROCESS_HANDLE_WRAPPER=on|DIRECT_PROCESS_HANDLE_WRAPPER=ON)
        echo "build env override '${entry}' is replay-unsafe; rerun only with --allow-replay-unsafe-experiments 1" >&2
        exit 2
        ;;
    esac
  done
fi

if ! [[ "${TIMEOUT_MS}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT_MS}" -lt 1000 ]]; then
  echo "--timeout-ms must be an integer >= 1000" >&2
  exit 2
fi

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "${OUTPUT_DIR}"
fi

HB_URL="$(clean_url "${HB_URL}")"
GRAPHQL_URL="$(clean_url "${GRAPHQL_URL}")"

if [[ ! -f "${CANDIDATE_SCRIPT}" ]]; then
  echo "missing candidate script: ${CANDIDATE_SCRIPT}" >&2
  exit 2
fi
if [[ ! -f "${AOCONNECT_SCRIPT}" ]]; then
  echo "missing aoconnect script: ${AOCONNECT_SCRIPT}" >&2
  exit 2
fi

candidate_dir="${OUTPUT_DIR}/candidate"
aoconnect_dir="${OUTPUT_DIR}/aoconnect"
combined_report="${OUTPUT_DIR}/resolver-lab-cycle-report.json"
mkdir -p "${candidate_dir}" "${aoconnect_dir}"

candidate_cmd=(
  bash "${CANDIDATE_SCRIPT}"
  --wallet "${WALLET}"
  --hb-url "${HB_URL}"
  --scheduler "${SCHEDULER}"
  --graphql-url "${GRAPHQL_URL}"
  --graphql-shim-remote-target "${GRAPHQL_SHIM_REMOTE_TARGET}"
  --graphql-shim-remote-ssh-key "${GRAPHQL_SHIM_REMOTE_SSH_KEY}"
  --graphql-shim-remote-path "${GRAPHQL_SHIM_REMOTE_PATH}"
  --graphql-shim-remote-with-sudo "${GRAPHQL_SHIM_REMOTE_WITH_SUDO}"
  --ao-repo-dir "${AO_REPO_DIR}"
  --build-wasm "${BUILD_WASM}"
  --execute-live "${EXECUTE_LIVE}"
  --output-dir "${candidate_dir}"
)
if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
  candidate_cmd+=("${FORWARD_ARGS[@]}")
fi

candidate_env=(
  "CAPTURE_AO_RESULT_PASSTHROUGH=${CAPTURE_AO_RESULT_PASSTHROUGH}"
  "PRESERVE_HANDLER_RESULT=${PRESERVE_HANDLER_RESULT}"
  "TRACE_RUNTIME_PATH=${TRACE_RUNTIME_PATH}"
  "TRACE_RESOLVER_ROUTE=${TRACE_RESOLVER_ROUTE}"
  "INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP=${INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP}"
  "DISABLE_RESOLVER_TOPLEVEL_WRAPPERS=${DISABLE_RESOLVER_TOPLEVEL_WRAPPERS}"
)
for entry in "${BUILD_ENV_OVERRIDES[@]}"; do
  candidate_env+=("${entry}")
done

candidate_status=0
set +e
env "${candidate_env[@]}" "${candidate_cmd[@]}" > "${candidate_dir}/candidate.stdout.json"
candidate_status=$?
set -e

candidate_report="${candidate_dir}/candidate-report.json"
if [[ ! -f "${candidate_report}" && -f "${candidate_dir}/candidate.stdout.json" ]]; then
  cp "${candidate_dir}/candidate.stdout.json" "${candidate_report}"
fi

candidate_report_input="${candidate_report}"
if [[ ! -f "${candidate_report_input}" ]] || ! jq -e . "${candidate_report_input}" >/dev/null 2>&1; then
  candidate_report_input="${OUTPUT_DIR}/candidate-report.placeholder.json"
  printf 'null\n' > "${candidate_report_input}"
fi

pid=""
if [[ -f "${candidate_report_input}" ]]; then
  pid="$(jq -r '.spawn.pid // .spawn.pidFromHeader // empty' "${candidate_report_input}")"
fi

aoconnect_status=0
if [[ "${RUN_AOCONNECT}" == "1" && -n "${pid}" && "${candidate_status}" == "0" ]]; then
  set +e
  node "${AOCONNECT_SCRIPT}" \
    --process "${pid}" \
    --hb-url "${HB_URL}" \
    --scheduler "${SCHEDULER}" \
    --wallet-jwk-file "${WALLET}" \
    --output-dir "${aoconnect_dir}" \
    --timeout-ms "${TIMEOUT_MS}" > "${aoconnect_dir}/aoconnect.stdout.log"
  aoconnect_status=$?
  set -e
fi

aoconnect_report="${aoconnect_dir}/ao-control-state-aoconnect-report.json"
aoconnect_report_input="${aoconnect_report}"
if [[ ! -f "${aoconnect_report_input}" ]] || ! jq -e . "${aoconnect_report_input}" >/dev/null 2>&1; then
  aoconnect_report_input="${OUTPUT_DIR}/aoconnect-report.placeholder.json"
  printf 'null\n' > "${aoconnect_report_input}"
fi

jq -n \
  --arg hbUrl "${HB_URL}" \
  --arg graphqlUrl "${GRAPHQL_URL}" \
  --arg scheduler "${SCHEDULER}" \
  --arg outputDir "${OUTPUT_DIR}" \
  --arg pid "${pid}" \
  --argjson candidateStatus "${candidate_status}" \
  --argjson aoconnectStatus "${aoconnect_status}" \
  --argjson buildWasm "${BUILD_WASM}" \
  --argjson executeLive "${EXECUTE_LIVE}" \
  --argjson runAoconnect "${RUN_AOCONNECT}" \
  --argjson allowReplayUnsafeExperiments "${ALLOW_REPLAY_UNSAFE_EXPERIMENTS}" \
  --argjson captureAoResultPassthrough "${CAPTURE_AO_RESULT_PASSTHROUGH}" \
  --argjson preserveHandlerResult "${PRESERVE_HANDLER_RESULT}" \
  --argjson traceRuntimePath "${TRACE_RUNTIME_PATH}" \
  --argjson traceResolverRoute "${TRACE_RESOLVER_ROUTE}" \
  --argjson inlineResolverPrintBridgeAfterSetup "${INLINE_RESOLVER_PRINT_BRIDGE_AFTER_SETUP}" \
  --argjson disableResolverToplevelWrappers "${DISABLE_RESOLVER_TOPLEVEL_WRAPPERS}" \
  --slurpfile candidate "${candidate_report_input}" \
  --slurpfile aoconnect "${aoconnect_report_input}" \
  '{
    summary: {
      hbUrl: $hbUrl,
      graphqlUrl: $graphqlUrl,
      scheduler: $scheduler,
      outputDir: $outputDir,
      pid: (if $pid == "" then null else $pid end),
      buildWasm: ($buildWasm == 1),
      executeLive: ($executeLive == 1),
      runAoconnect: ($runAoconnect == 1),
      candidatePassed: ($candidateStatus == 0),
      aoconnectPassed: ($aoconnectStatus == 0)
    },
    labBuildFlags: {
      allowReplayUnsafeExperiments: ($allowReplayUnsafeExperiments == 1),
      captureAoResultPassthrough: ($captureAoResultPassthrough == 1),
      preserveHandlerResult: ($preserveHandlerResult == 1),
      traceRuntimePath: ($traceRuntimePath == 1),
      traceResolverRoute: ($traceResolverRoute == 1),
      inlineResolverPrintBridgeAfterSetup: ($inlineResolverPrintBridgeAfterSetup == 1),
      disableResolverToplevelWrappers: ($disableResolverToplevelWrappers == 1)
    },
    candidate: ($candidate[0] // null),
    aoconnect: ($aoconnect[0] // null)
  }' > "${combined_report}"

cat "${combined_report}"

if [[ "${candidate_status}" != "0" || ( "${RUN_AOCONNECT}" == "1" && "${aoconnect_status}" != "0" ) ]]; then
  exit 1
fi
