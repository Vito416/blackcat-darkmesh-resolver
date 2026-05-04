#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
AO_REPO_DIR_DEFAULT="${WORKSPACE_ROOT}/blackcat-darkmesh-ao"

AO_REPO_DIR="${AO_REPO_DIR:-${AO_REPO_DIR_DEFAULT}}"
WALLET=""
HB_URL="https://write.darkmesh.fun"
SCHEDULER="_wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM"
SCHEDULER_LOCATION="https://write.darkmesh.fun"
EXECUTION_DEVICE="genesis-wasm@1.0"
MODULE_NAME="blackcat-ao-darkmesh-resolver-candidate"
PROCESS_NAME="darkmesh-resolver-candidate"
MODULE_TX=""
SPAWN_DATA="1984"
OUTPUT_DIR=""
BUILD_WASM=0
EXECUTE_LIVE=0
PROBE_SLOT_MAX=12
SMOKE_ACTION="GetResolverState"
STRICT_SMOKE=0
REQUIRE_SEMANTIC_SMOKE=0
WARMUP_TIMEOUT_SEC=180
WARMUP_INTERVAL_SEC=5
EXECUTION_PROBE=1
EXECUTION_PROBE_STRICT_SEMANTIC_OUTPUT=0
EXECUTION_PROBE_ACTIONS="GetResolverState,ResolveHostForNode,ResolveRouteForHost"
EXECUTION_PROBE_HOST="jdwt.fun"
EXECUTION_PROBE_PATH="/"
EXECUTION_PROBE_METHOD="GET"
GRAPHQL_URL="https://arweave.net/graphql"
GRAPHQL_SHIM_ALLOWLIST_FILE="${DARKMESH_GRAPHQL_SHIM_ALLOWLIST_FILE:-}"
GRAPHQL_SHIM_REMOTE_TARGET="${DARKMESH_GRAPHQL_SHIM_REMOTE_TARGET:-}"
GRAPHQL_SHIM_REMOTE_PATH="${DARKMESH_GRAPHQL_SHIM_REMOTE_PATH:-/etc/darkmesh/graphql-shim-allowlist.txt}"
GRAPHQL_SHIM_REMOTE_SSH_KEY="${DARKMESH_GRAPHQL_SHIM_REMOTE_SSH_KEY:-}"
GRAPHQL_SHIM_REMOTE_WITH_SUDO="${DARKMESH_GRAPHQL_SHIM_REMOTE_WITH_SUDO:-1}"

usage() {
  cat <<'USAGE'
Prepare a fresh AO-native resolver PID candidate on a clean process chain.

By default this is safe and non-mutating: it writes a plan/report only.
Actual publish+spawn happens only when --execute-live 1 is provided.

Usage:
  fresh-resolver-candidate.sh [options]

Options:
  --wallet <path>               Wallet for publish/spawn/smoke steps.
  --hb-url <url>                Write/HyperBeam base URL.
                                Default: https://write.darkmesh.fun
  --scheduler <id>              Scheduler owner ID used for spawn.
                                Default: _wCF37G9t-xfJuYZqc6JXI9VrG4dzM5WUFgDfOn9LdM
  --scheduler-location <url>    Scheduler ingress location.
                                Default: https://write.darkmesh.fun
  --execution-device <name>     AO execution device.
                                Default: genesis-wasm@1.0
  --module-name <name>          Name tag for published module.
  --process-name <name>         Friendly name for spawned process.
  --module-tx <tx>              Reuse an existing published module.
  --spawn-data <data>           Initial spawn data payload.
                                Default: 1984
  --output-dir <path>           Directory for plan/report artifacts.
                                Default: mktemp dir
  --build-wasm <0|1>            Build dist/resolver/process.wasm first.
                                Default: 0
  --execute-live <0|1>          Actually publish + spawn + probe.
                                Default: 0
  --probe-slot-max <n>          Max slot sweep for candidate probe.
                                Default: 12
  --smoke-action <name>         Signed scheduler smoke action.
                                Default: GetResolverState
  --strict-smoke <0|1>          Ask smoke helper to require semantic Output shape.
                                Useful for diagnostics, but can false-negative on
                                healthy AO runtime-effect. Default: 0
  --require-semantic-smoke <0|1>
                                Fail candidate only on semantic output failure.
                                Legacy diagnostic mode; runtime-effect health is
                                reported separately. Default: 0
  --execution-probe <0|1>       Run resolver-specific execution probe after replay probe.
                                Default: 1
  --execution-probe-strict-semantic-output <0|1>
                                Make execution probe require non-empty semantic Output.
                                Diagnostic only. Default: 0
  --execution-probe-actions <csv>
                                Resolver actions for execution probe.
                                Default: GetResolverState,ResolveHostForNode,ResolveRouteForHost
  --execution-probe-host <host> Host used by resolver execution probe.
                                Default: jdwt.fun
  --execution-probe-path <path> Path used by resolver execution probe.
                                Default: /
  --execution-probe-method <verb>
                                Method used by resolver execution probe.
                                Default: GET
  --warmup-timeout-sec <n>      Wait up to N seconds for module/process readiness.
                                Default: 180
  --warmup-interval-sec <n>     Poll interval during warm-up.
                                Default: 5
  --graphql-url <url>           GraphQL endpoint that must expose the published
                                module tx before the candidate is considered
                                replay-ready.
                                Default: https://arweave.net/graphql
  --graphql-shim-allowlist-file <path>
                                Optional local allowlist file to update with
                                the published/reused module tx.
  --graphql-shim-remote-target <user@host>
                                Optional remote target for GraphQL shim
                                allowlist updates over ssh.
  --graphql-shim-remote-path <path>
                                Remote allowlist path.
                                Default: /etc/darkmesh/graphql-shim-allowlist.txt
  --graphql-shim-remote-ssh-key <path>
                                SSH key for the remote allowlist target.
  --graphql-shim-remote-with-sudo <0|1>
                                Use sudo for remote allowlist writes.
                                Default: 1
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

wait_for_http_200() {
  local url="$1"
  local timeout_sec="$2"
  local interval_sec="$3"
  local label="$4"
  local deadline now code
  deadline=$(( $(date +%s) + timeout_sec ))
  while true; do
    code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [[ "${code}" == "200" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      echo "${label} did not become ready at ${url} within ${timeout_sec}s (last http=${code})" >&2
      return 1
    fi
    sleep "${interval_sec}"
  done
}

wait_for_slot_current() {
  local url="$1"
  local timeout_sec="$2"
  local interval_sec="$3"
  local deadline now body
  deadline=$(( $(date +%s) + timeout_sec ))
  while true; do
    body="$(curl -sS --max-time 20 "${url}" || true)"
    body="${body//$'\r'/}"
    body="${body//$'\n'/}"
    if [[ "${body}" =~ ^[0-9]+$ ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      echo "process slot/current did not become numeric at ${url} within ${timeout_sec}s" >&2
      return 1
    fi
    sleep "${interval_sec}"
  done
}

graphql_tx_visible() {
  local graphql_url="$1"
  local txid="$2"
  python3 - "$graphql_url" "$txid" <<'PY'
import json
import sys
import urllib.request

graphql_url = sys.argv[1]
txid = sys.argv[2]
query = "query($ids:[ID!]!){ transactions(ids:$ids){ edges { node { id } } } }"
payload = json.dumps({
    "query": query,
    "variables": {"ids": [txid]},
}).encode("utf-8")
req = urllib.request.Request(
    graphql_url,
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=20) as res:
        body = json.loads(res.read().decode("utf-8"))
except Exception:
    print("error")
    raise SystemExit(2)

edges = body.get("data", {}).get("transactions", {}).get("edges", [])
if any(edge.get("node", {}).get("id") == txid for edge in edges if isinstance(edge, dict)):
    print("visible")
    raise SystemExit(0)
print("missing")
raise SystemExit(1)
PY
}

graphql_tx_visible_remote() {
  local remote_target="$1"
  local graphql_url="$2"
  local txid="$3"
  local ssh_cmd=(ssh)
  if [[ -n "${GRAPHQL_SHIM_REMOTE_SSH_KEY}" ]]; then
    ssh_cmd+=(-i "${GRAPHQL_SHIM_REMOTE_SSH_KEY}")
  fi
  "${ssh_cmd[@]}" "${remote_target}" python3 - "${graphql_url}" "${txid}" <<'PY'
import json
import sys
import urllib.request

graphql_url = sys.argv[1]
txid = sys.argv[2]
query = "query($ids:[ID!]!){ transactions(ids:$ids){ edges { node { id } } } }"
payload = json.dumps({
    "query": query,
    "variables": {"ids": [txid]},
}).encode("utf-8")
req = urllib.request.Request(
    graphql_url,
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=20) as res:
        body = json.loads(res.read().decode("utf-8"))
except Exception:
    print("error")
    raise SystemExit(2)

edges = body.get("data", {}).get("transactions", {}).get("edges", [])
if any(edge.get("node", {}).get("id") == txid for edge in edges if isinstance(edge, dict)):
    print("visible")
    raise SystemExit(0)
print("missing")
raise SystemExit(1)
PY
}

graphql_url_needs_remote_reachability() {
  local graphql_url="$1"
  python3 - "$graphql_url" <<'PY'
import sys
import urllib.parse

url = urllib.parse.urlparse(sys.argv[1])
host = (url.hostname or "").lower()
if host in {"127.0.0.1", "localhost", "::1"}:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_for_graphql_tx_visible() {
  local graphql_url="$1"
  local txid="$2"
  local timeout_sec="$3"
  local interval_sec="$4"
  local deadline now
  local use_remote=0
  if [[ -n "${GRAPHQL_SHIM_REMOTE_TARGET}" ]] && graphql_url_needs_remote_reachability "${graphql_url}"; then
    use_remote=1
  fi
  deadline=$(( $(date +%s) + timeout_sec ))
  while true; do
    if [[ "${use_remote}" == "1" ]]; then
      if graphql_tx_visible_remote "${GRAPHQL_SHIM_REMOTE_TARGET}" "${graphql_url}" "${txid}" >/dev/null 2>&1; then
        return 0
      fi
    elif graphql_tx_visible "${graphql_url}" "${txid}" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now >= deadline )); then
      echo "GraphQL transaction visibility did not become ready for ${txid} at ${graphql_url} within ${timeout_sec}s" >&2
      return 1
    fi
    sleep "${interval_sec}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wallet) WALLET="${2:-}"; shift 2 ;;
    --hb-url) HB_URL="${2:-}"; shift 2 ;;
    --scheduler) SCHEDULER="${2:-}"; shift 2 ;;
    --scheduler-location) SCHEDULER_LOCATION="${2:-}"; shift 2 ;;
    --execution-device) EXECUTION_DEVICE="${2:-}"; shift 2 ;;
    --module-name) MODULE_NAME="${2:-}"; shift 2 ;;
    --process-name) PROCESS_NAME="${2:-}"; shift 2 ;;
    --module-tx) MODULE_TX="${2:-}"; shift 2 ;;
    --spawn-data) SPAWN_DATA="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --build-wasm) BUILD_WASM="${2:-}"; shift 2 ;;
    --execute-live) EXECUTE_LIVE="${2:-}"; shift 2 ;;
    --probe-slot-max) PROBE_SLOT_MAX="${2:-}"; shift 2 ;;
    --smoke-action) SMOKE_ACTION="${2:-}"; shift 2 ;;
    --strict-smoke) STRICT_SMOKE="${2:-}"; shift 2 ;;
    --require-semantic-smoke) REQUIRE_SEMANTIC_SMOKE="${2:-}"; shift 2 ;;
    --execution-probe) EXECUTION_PROBE="${2:-}"; shift 2 ;;
    --execution-probe-strict-semantic-output) EXECUTION_PROBE_STRICT_SEMANTIC_OUTPUT="${2:-}"; shift 2 ;;
    --execution-probe-actions) EXECUTION_PROBE_ACTIONS="${2:-}"; shift 2 ;;
    --execution-probe-host) EXECUTION_PROBE_HOST="${2:-}"; shift 2 ;;
    --execution-probe-path) EXECUTION_PROBE_PATH="${2:-}"; shift 2 ;;
    --execution-probe-method) EXECUTION_PROBE_METHOD="${2:-}"; shift 2 ;;
    --warmup-timeout-sec) WARMUP_TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --warmup-interval-sec) WARMUP_INTERVAL_SEC="${2:-}"; shift 2 ;;
    --graphql-url) GRAPHQL_URL="${2:-}"; shift 2 ;;
    --graphql-shim-allowlist-file) GRAPHQL_SHIM_ALLOWLIST_FILE="${2:-}"; shift 2 ;;
    --graphql-shim-remote-target) GRAPHQL_SHIM_REMOTE_TARGET="${2:-}"; shift 2 ;;
    --graphql-shim-remote-path) GRAPHQL_SHIM_REMOTE_PATH="${2:-}"; shift 2 ;;
    --graphql-shim-remote-ssh-key) GRAPHQL_SHIM_REMOTE_SSH_KEY="${2:-}"; shift 2 ;;
    --graphql-shim-remote-with-sudo) GRAPHQL_SHIM_REMOTE_WITH_SUDO="${2:-}"; shift 2 ;;
    --ao-repo-dir) AO_REPO_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for flag in BUILD_WASM EXECUTE_LIVE STRICT_SMOKE REQUIRE_SEMANTIC_SMOKE EXECUTION_PROBE EXECUTION_PROBE_STRICT_SEMANTIC_OUTPUT; do
  value="${!flag}"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    echo "${flag} must be 0 or 1" >&2
    exit 2
  fi
done
if ! [[ "${PROBE_SLOT_MAX}" =~ ^[0-9]+$ ]] || [[ "${PROBE_SLOT_MAX}" -lt 1 ]]; then
  echo "--probe-slot-max must be a positive integer" >&2
  exit 2
fi
if [[ "${GRAPHQL_SHIM_REMOTE_WITH_SUDO}" != "0" && "${GRAPHQL_SHIM_REMOTE_WITH_SUDO}" != "1" ]]; then
  echo "--graphql-shim-remote-with-sudo must be 0 or 1" >&2
  exit 2
fi
for value_name in WARMUP_TIMEOUT_SEC WARMUP_INTERVAL_SEC; do
  value="${!value_name}"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]]; then
    echo "${value_name} must be a positive integer" >&2
    exit 2
  fi
done
if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "${OUTPUT_DIR}"
fi

HB_URL="$(clean_url "${HB_URL}")"
SCHEDULER_LOCATION="$(clean_url "${SCHEDULER_LOCATION}")"
GRAPHQL_URL="$(clean_url "${GRAPHQL_URL}")"

publish_script="${AO_REPO_DIR}/scripts/deploy/publish_wasm_module.mjs"
spawn_script="${AO_REPO_DIR}/scripts/deploy/spawn_process_wasm_tn.mjs"
probe_script="${REPO_ROOT}/ops/live-vps/local-tools/probe-resolver-pid-history.sh"
execution_probe_script="${REPO_ROOT}/ops/live-vps/local-tools/probe-resolver-execution.mjs"
graphql_shim_allowlist_script="${REPO_ROOT}/ops/live-vps/local-tools/update-graphql-shim-allowlist.sh"
wasm_path="${REPO_ROOT}/dist/resolver/process.wasm"
module_report="${OUTPUT_DIR}/module.json"
spawn_report="${OUTPUT_DIR}/spawn.json"
probe_dir="${OUTPUT_DIR}/probe"
execution_probe_dir="${OUTPUT_DIR}/execution-probe"
graphql_shim_allowlist_report="${OUTPUT_DIR}/graphql-shim-allowlist-update.json"
plan_report="${OUTPUT_DIR}/candidate-plan.json"
summary_report="${OUTPUT_DIR}/candidate-report.json"

mkdir -p "${probe_dir}"
mkdir -p "${execution_probe_dir}"

for required in "${probe_script}" "${execution_probe_script}"; do
  if [[ ! -f "${required}" ]]; then
    echo "missing required file: ${required}" >&2
    exit 2
  fi
done
if [[ -n "${GRAPHQL_SHIM_ALLOWLIST_FILE}" || -n "${GRAPHQL_SHIM_REMOTE_TARGET}" ]]; then
  if [[ ! -f "${graphql_shim_allowlist_script}" ]]; then
    echo "missing graphql shim allowlist helper: ${graphql_shim_allowlist_script}" >&2
    exit 2
  fi
fi
if [[ "${BUILD_WASM}" == "1" ]]; then
  (cd "${REPO_ROOT}" && bash scripts/deploy/build_resolver_wasm_docker.sh)
fi
if [[ -z "${MODULE_TX}" && ! -f "${wasm_path}" ]]; then
  echo "missing resolver wasm: ${wasm_path}" >&2
  echo "Build it first or pass --module-tx <published-module>." >&2
  exit 2
fi

jq -n \
  --arg repoRoot "${REPO_ROOT}" \
  --arg aoRepoDir "${AO_REPO_DIR}" \
  --arg hbUrl "${HB_URL}" \
  --arg scheduler "${SCHEDULER}" \
  --arg schedulerLocation "${SCHEDULER_LOCATION}" \
  --arg executionDevice "${EXECUTION_DEVICE}" \
  --arg moduleName "${MODULE_NAME}" \
  --arg processName "${PROCESS_NAME}" \
  --arg moduleTx "${MODULE_TX}" \
  --arg wasmPath "${wasm_path}" \
  --arg spawnData "${SPAWN_DATA}" \
  --arg wallet "${WALLET}" \
  --argjson buildWasm "${BUILD_WASM}" \
  --argjson executeLive "${EXECUTE_LIVE}" \
  --argjson probeSlotMax "${PROBE_SLOT_MAX}" \
  --arg smokeAction "${SMOKE_ACTION}" \
  --argjson strictSmoke "${STRICT_SMOKE}" \
  --argjson requireSemanticSmoke "${REQUIRE_SEMANTIC_SMOKE}" \
  --argjson executionProbe "${EXECUTION_PROBE}" \
  --argjson executionProbeStrictSemanticOutput "${EXECUTION_PROBE_STRICT_SEMANTIC_OUTPUT}" \
  --arg executionProbeActions "${EXECUTION_PROBE_ACTIONS}" \
  --arg executionProbeHost "${EXECUTION_PROBE_HOST}" \
  --arg executionProbePath "${EXECUTION_PROBE_PATH}" \
  --arg executionProbeMethod "${EXECUTION_PROBE_METHOD}" \
  --argjson warmupTimeoutSec "${WARMUP_TIMEOUT_SEC}" \
  --argjson warmupIntervalSec "${WARMUP_INTERVAL_SEC}" \
  --arg graphqlUrl "${GRAPHQL_URL}" \
  --arg graphqlShimAllowlistFile "${GRAPHQL_SHIM_ALLOWLIST_FILE}" \
  --arg graphqlShimRemoteTarget "${GRAPHQL_SHIM_REMOTE_TARGET}" \
  --arg graphqlShimRemotePath "${GRAPHQL_SHIM_REMOTE_PATH}" \
  --arg graphqlShimRemoteSshKey "${GRAPHQL_SHIM_REMOTE_SSH_KEY}" \
  --argjson graphqlShimRemoteWithSudo "${GRAPHQL_SHIM_REMOTE_WITH_SUDO}" \
  '{
    mode: (if $executeLive == 1 then "live" else "plan_only" end),
    repoRoot: $repoRoot,
    aoRepoDir: $aoRepoDir,
    hbUrl: $hbUrl,
    scheduler: $scheduler,
    schedulerLocation: $schedulerLocation,
    executionDevice: $executionDevice,
    moduleName: $moduleName,
    processName: $processName,
    moduleTx: (if $moduleTx == "" then null else $moduleTx end),
    wasmPath: $wasmPath,
    spawnData: $spawnData,
    walletProvided: ($wallet != ""),
    buildWasm: ($buildWasm == 1),
    probeSlotMax: $probeSlotMax,
    smokeAction: $smokeAction,
    strictSmoke: ($strictSmoke == 1),
    requireSemanticSmoke: ($requireSemanticSmoke == 1),
    executionProbe: ($executionProbe == 1),
    executionProbeStrictSemanticOutput: ($executionProbeStrictSemanticOutput == 1),
    executionProbeActions: ($executionProbeActions | split(",") | map(select(length > 0))),
    executionProbeHost: $executionProbeHost,
    executionProbePath: $executionProbePath,
    executionProbeMethod: $executionProbeMethod,
    warmupTimeoutSec: $warmupTimeoutSec,
    warmupIntervalSec: $warmupIntervalSec,
    graphqlUrl: $graphqlUrl,
    graphqlShimAllowlist: {
      localFile: (if $graphqlShimAllowlistFile == "" then null else $graphqlShimAllowlistFile end),
      remoteTarget: (if $graphqlShimRemoteTarget == "" then null else $graphqlShimRemoteTarget end),
      remotePath: (if $graphqlShimRemotePath == "" then null else $graphqlShimRemotePath end),
      remoteSshKey: (if $graphqlShimRemoteSshKey == "" then null else $graphqlShimRemoteSshKey end),
      remoteWithSudo: ($graphqlShimRemoteWithSudo == 1)
    }
  }' > "${plan_report}"

if [[ "${EXECUTE_LIVE}" != "1" ]]; then
  cat "${plan_report}"
  exit 0
fi

if [[ -z "${WALLET}" ]]; then
  echo "--wallet is required when --execute-live 1" >&2
  exit 2
fi
if [[ ! -f "${WALLET}" ]]; then
  echo "wallet not found: ${WALLET}" >&2
  exit 2
fi
if [[ -z "${MODULE_TX}" ]]; then
  if [[ ! -f "${publish_script}" ]]; then
    echo "missing publish script: ${publish_script}" >&2
    exit 2
  fi
  node "${publish_script}" \
    --wasm "${wasm_path}" \
    --wallet "${WALLET}" \
    --name "${MODULE_NAME}" \
    --out "${module_report}"
  MODULE_TX="$(jq -r '.tx // empty' "${module_report}")"
  if [[ -z "${MODULE_TX}" ]]; then
    echo "publish did not return a module tx" >&2
    exit 1
  fi
else
  jq -n --arg tx "${MODULE_TX}" --arg name "${MODULE_NAME}" '{tx:$tx,name:$name,reused:true}' > "${module_report}"
fi

if [[ -n "${GRAPHQL_SHIM_ALLOWLIST_FILE}" || -n "${GRAPHQL_SHIM_REMOTE_TARGET}" ]]; then
  allowlist_cmd=(bash "${graphql_shim_allowlist_script}" --module-json "${module_report}" --output-json "${graphql_shim_allowlist_report}")
  if [[ -n "${GRAPHQL_SHIM_ALLOWLIST_FILE}" ]]; then
    allowlist_cmd+=(--allowlist-file "${GRAPHQL_SHIM_ALLOWLIST_FILE}")
  fi
  if [[ -n "${GRAPHQL_SHIM_REMOTE_TARGET}" ]]; then
    allowlist_cmd+=(--remote-target "${GRAPHQL_SHIM_REMOTE_TARGET}" --remote-path "${GRAPHQL_SHIM_REMOTE_PATH}" --remote-with-sudo "${GRAPHQL_SHIM_REMOTE_WITH_SUDO}")
    if [[ -n "${GRAPHQL_SHIM_REMOTE_SSH_KEY}" ]]; then
      allowlist_cmd+=(--remote-ssh-key "${GRAPHQL_SHIM_REMOTE_SSH_KEY}")
    fi
  fi
  "${allowlist_cmd[@]}" > /dev/null
fi

if [[ ! -f "${spawn_script}" ]]; then
  echo "missing spawn script: ${spawn_script}" >&2
  exit 2
fi

wait_for_graphql_tx_visible "${GRAPHQL_URL}" "${MODULE_TX}" "${WARMUP_TIMEOUT_SEC}" "${WARMUP_INTERVAL_SEC}"

node "${spawn_script}" \
  --module "${MODULE_TX}" \
  --wallet "${WALLET}" \
  --name "${PROCESS_NAME}" \
  --url "${HB_URL}" \
  --scheduler "${SCHEDULER}" \
  --scheduler-location "${SCHEDULER_LOCATION}" \
  --execution-device "${EXECUTION_DEVICE}" \
  --content-type application/wasm \
  --data "${SPAWN_DATA}" \
  --out "${spawn_report}"

PID="$(jq -r '.pid // .pidFromHeader // empty' "${spawn_report}")"
if [[ -z "${PID}" ]]; then
  echo "spawn did not return a PID" >&2
  exit 1
fi

module_ready_url="${HB_URL}/${MODULE_TX}~module@1.0?accept-bundle=true"
slot_ready_url="${HB_URL}/${PID}~process@1.0/slot/current?accept-bundle=true"
wait_for_http_200 "${module_ready_url}" "${WARMUP_TIMEOUT_SEC}" "${WARMUP_INTERVAL_SEC}" "module route"
wait_for_slot_current "${slot_ready_url}" "${WARMUP_TIMEOUT_SEC}" "${WARMUP_INTERVAL_SEC}"

probe_cmd=(bash "${probe_script}" --pid "${PID}" --base-url "${HB_URL}" --slot-max "${PROBE_SLOT_MAX}" --output-dir "${probe_dir}" --wallet "${WALLET}" --smoke-action "${SMOKE_ACTION}" --strict-smoke "${STRICT_SMOKE}" --require-semantic-smoke "${REQUIRE_SEMANTIC_SMOKE}" --ao-repo-dir "${AO_REPO_DIR}")
replay_probe_status=0
set +e
"${probe_cmd[@]}" > /dev/null
replay_probe_status=$?
set -e

execution_probe_status=0
if [[ "${EXECUTION_PROBE}" == "1" ]]; then
  execution_probe_cmd=(
    node "${execution_probe_script}"
    --pid "${PID}"
    --wallet "${WALLET}"
    --base-url "${HB_URL}"
    --actions "${EXECUTION_PROBE_ACTIONS}"
    --host "${EXECUTION_PROBE_HOST}"
    --path "${EXECUTION_PROBE_PATH}"
    --method "${EXECUTION_PROBE_METHOD}"
    --strict-semantic-output "${EXECUTION_PROBE_STRICT_SEMANTIC_OUTPUT}"
    --output-dir "${execution_probe_dir}"
  )
  set +e
  "${execution_probe_cmd[@]}" > /dev/null
  execution_probe_status=$?
  set -e
fi

jq -n \
  --slurpfile plan "${plan_report}" \
  --slurpfile module "${module_report}" \
  --slurpfile spawn "${spawn_report}" \
  --slurpfile probe "${probe_dir}/probe-report.json" \
  --slurpfile executionProbe "${execution_probe_dir}/resolver-execution-probe-report.json" \
  --slurpfile graphqlShimAllowlist "${graphql_shim_allowlist_report}" \
  --argjson replayProbeStatus "${replay_probe_status}" \
  --argjson executionProbeStatus "${execution_probe_status}" \
  '{
    plan: ($plan[0] // {}),
    module: ($module[0] // {}),
    spawn: ($spawn[0] // {}),
    probe: ($probe[0] // {}),
    executionProbe: ($executionProbe[0] // {}),
    graphqlShimAllowlistUpdate: ($graphqlShimAllowlist[0] // null),
    gates: {
      replayProbePassed: ($replayProbeStatus == 0),
      executionProbePassed: ($executionProbeStatus == 0),
      overallPassed: (($replayProbeStatus == 0) and ($executionProbeStatus == 0))
    }
  }' > "${summary_report}"

cat "${summary_report}"

if [[ "${replay_probe_status}" != "0" || "${execution_probe_status}" != "0" ]]; then
  exit 1
fi
