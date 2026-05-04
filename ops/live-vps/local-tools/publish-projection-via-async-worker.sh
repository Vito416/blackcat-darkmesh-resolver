#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  publish-projection-via-async-worker.sh \
    --worker-url https://async.example.workers.dev/resolver/projection/publish \
    --input /path/to/signed-envelope.v2.json

Auth:
  export RESOLVER_PUBLISH_AUTH_TOKEN=...
  or pass --auth-token <token>
USAGE
}

WORKER_URL=""
INPUT_PATH=""
AUTH_TOKEN="${RESOLVER_PUBLISH_AUTH_TOKEN:-}"
REQUEST_ID="resolver-publish-$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-url) WORKER_URL="$2"; shift 2 ;;
    --input) INPUT_PATH="$2"; shift 2 ;;
    --auth-token) AUTH_TOKEN="$2"; shift 2 ;;
    --request-id) REQUEST_ID="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$WORKER_URL" ]] || { echo "--worker-url required" >&2; exit 2; }
[[ -n "$INPUT_PATH" ]] || { echo "--input required" >&2; exit 2; }
[[ -n "$AUTH_TOKEN" ]] || { echo "auth token required via RESOLVER_PUBLISH_AUTH_TOKEN or --auth-token" >&2; exit 2; }
[[ -f "$INPUT_PATH" ]] || { echo "input file not found: $INPUT_PATH" >&2; exit 2; }

payload_tmp="$(mktemp)"
response_tmp="$(mktemp)"
trap 'rm -f "$payload_tmp" "$response_tmp"' EXIT

jq -n \
  --arg requestId "$REQUEST_ID" \
  --slurpfile envelope "$INPUT_PATH" \
  '{requestId:$requestId,envelope:$envelope[0]}' >"$payload_tmp"

curl -fsS \
  -H "authorization: Bearer ${AUTH_TOKEN}" \
  -H 'content-type: application/json' \
  -X POST "$WORKER_URL" \
  --data-binary @"$payload_tmp" >"$response_tmp"

jq -e '.ok == true and .published == true' "$response_tmp" >/dev/null

if [[ -n "$OUTPUT_PATH" ]]; then
  cp "$response_tmp" "$OUTPUT_PATH"
fi

echo "published projection"
echo "  requestId=$(jq -r '.requestId // empty' "$response_tmp")"
echo "  snapshotId=$(jq -r '.snapshotId // empty' "$response_tmp")"
echo "  sequence=$(jq -r '.sequence // empty' "$response_tmp")"
echo "  keyId=$(jq -r '.keyId // empty' "$response_tmp")"
