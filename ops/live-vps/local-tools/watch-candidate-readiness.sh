#!/usr/bin/env bash
set -euo pipefail

MODULE_TX=""
PID=""
BASE_URL="https://write.darkmesh.fun"
GRAPHQL_URLS="https://arweave.net/graphql,https://arweave-search.goldsky.com/graphql"
STATUS_URL_BASE="https://arweave.net"
INTERVAL_SEC=15
MAX_POLLS=0

usage() {
  cat <<'USAGE'
Watch candidate module readiness across Arweave status, GraphQL visibility,
and optional compute health for a spawned PID.

Usage:
  watch-candidate-readiness.sh --module-tx <tx> [options]

Options:
  --module-tx <tx>             Module transaction ID to monitor. Required.
  --pid <pid>                  Candidate process ID to monitor.
  --base-url <url>             Compute base URL for slot/current and compute=1.
                               Default: https://write.darkmesh.fun
  --graphql-urls <csv>         Comma-separated GraphQL endpoints.
                               Default: https://arweave.net/graphql,https://arweave-search.goldsky.com/graphql
  --status-url-base <url>      Base gateway used for /tx/<id>/status.
                               Default: https://arweave.net
  --interval-sec <n>           Poll interval in seconds.
                               Default: 15
  --max-polls <n>              Stop after N polls. 0 means forever.
                               Default: 0
  -h, --help                   Show help.
USAGE
}

clean_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "${value}"
}

graphql_check() {
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
    with urllib.request.urlopen(req, timeout=25) as res:
        body = json.loads(res.read().decode("utf-8"))
    edges = body.get("data", {}).get("transactions", {}).get("edges", [])
    visible = any(edge.get("node", {}).get("id") == txid for edge in edges if isinstance(edge, dict))
    print(json.dumps({
        "ok": True,
        "visible": visible,
        "edges": len(edges),
        "id": edges[0]["node"]["id"] if edges and isinstance(edges[0], dict) and isinstance(edges[0].get("node"), dict) else None
    }))
except Exception as exc:
    print(json.dumps({
        "ok": False,
        "error": repr(exc)
    }))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module-tx) MODULE_TX="${2:-}"; shift 2 ;;
    --pid) PID="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --graphql-urls) GRAPHQL_URLS="${2:-}"; shift 2 ;;
    --status-url-base) STATUS_URL_BASE="${2:-}"; shift 2 ;;
    --interval-sec) INTERVAL_SEC="${2:-}"; shift 2 ;;
    --max-polls) MAX_POLLS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${MODULE_TX}" ]]; then
  echo "--module-tx is required" >&2
  usage
  exit 2
fi
if ! [[ "${INTERVAL_SEC}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL_SEC}" -lt 1 ]]; then
  echo "--interval-sec must be a positive integer" >&2
  exit 2
fi
if ! [[ "${MAX_POLLS}" =~ ^[0-9]+$ ]]; then
  echo "--max-polls must be a non-negative integer" >&2
  exit 2
fi

BASE_URL="$(clean_url "${BASE_URL}")"
STATUS_URL_BASE="$(clean_url "${STATUS_URL_BASE}")"

IFS=',' read -r -a graphql_urls <<< "${GRAPHQL_URLS}"
poll=0

while true; do
  poll=$((poll + 1))
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  status_json="$(python3 - "${STATUS_URL_BASE}" "${MODULE_TX}" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1]
txid = sys.argv[2]
url = f"{base}/tx/{txid}/status"
try:
    with urllib.request.urlopen(url, timeout=20) as res:
        body = json.loads(res.read().decode("utf-8"))
    print(json.dumps({"ok": True, "status": body}))
except Exception as exc:
    print(json.dumps({"ok": False, "error": repr(exc)}))
PY
)"

  graphql_rows=()
  for graphql_url in "${graphql_urls[@]}"; do
    payload="$(graphql_check "${graphql_url}" "${MODULE_TX}")"
    graphql_rows+=("$(jq -cn --arg url "${graphql_url}" --argjson payload "${payload}" '$payload + {url:$url}')")
  done
  graphql_json="$(printf '%s\n' "${graphql_rows[@]}" | jq -s '.')"

  pid_json="null"
  if [[ -n "${PID}" ]]; then
    pid_json="$(python3 - "${BASE_URL}" "${PID}" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1]
pid = sys.argv[2]
result = {}
for key, url in {
    "slotCurrent": f"{base}/{pid}/slot/current",
    "compute1": f"{base}/{pid}/compute=1",
}.items():
    try:
      req = urllib.request.Request(url, method="GET")
      with urllib.request.urlopen(req, timeout=25) as res:
        body = res.read()
        result[key] = {
          "ok": True,
          "status": getattr(res, "status", 200),
          "bodyHead": body[:240].decode("utf-8", "replace")
        }
    except Exception as exc:
      status = getattr(exc, "code", None)
      body = ""
      if hasattr(exc, "read"):
        try:
          body = exc.read()[:240].decode("utf-8", "replace")
        except Exception:
          body = ""
      result[key] = {
        "ok": False,
        "status": status,
        "error": repr(exc),
        "bodyHead": body
      }
print(json.dumps(result))
PY
)"
  fi

  jq -n \
    --arg timestamp "${timestamp}" \
    --arg moduleTx "${MODULE_TX}" \
    --arg pid "${PID}" \
    --argjson poll "${poll}" \
    --argjson status "${status_json}" \
    --argjson graphql "${graphql_json}" \
    --argjson pidState "${pid_json}" \
    '{
      timestamp: $timestamp,
      poll: $poll,
      moduleTx: $moduleTx,
      pid: (if $pid == "" then null else $pid end),
      arweaveStatus: $status,
      graphql: $graphql,
      pidState: $pidState
    }'

  if [[ "${MAX_POLLS}" -gt 0 && "${poll}" -ge "${MAX_POLLS}" ]]; then
    break
  fi
  sleep "${INTERVAL_SEC}"
done
