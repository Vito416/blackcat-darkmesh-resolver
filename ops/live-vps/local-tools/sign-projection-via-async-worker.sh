#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  sign-projection-via-async-worker.sh \
    --worker-url https://async.example.workers.dev/resolver/projection/sign \
    --input /path/to/unsigned-envelope.v2.json \
    --output /path/to/signed-envelope.v2.json

Auth:
  export RESOLVER_SIGNER_AUTH_TOKEN=...
  or pass --auth-token <token>
USAGE
}

WORKER_URL=""
INPUT_PATH=""
OUTPUT_PATH=""
AUTH_TOKEN="${RESOLVER_SIGNER_AUTH_TOKEN:-}"
REQUEST_ID="resolver-sign-$(date -u +%Y%m%dT%H%M%SZ)"
FULL_RESPONSE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-url) WORKER_URL="$2"; shift 2 ;;
    --input) INPUT_PATH="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    --auth-token) AUTH_TOKEN="$2"; shift 2 ;;
    --request-id) REQUEST_ID="$2"; shift 2 ;;
    --full-response-output) FULL_RESPONSE_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$WORKER_URL" ]] || { echo "--worker-url required" >&2; exit 2; }
[[ -n "$INPUT_PATH" ]] || { echo "--input required" >&2; exit 2; }
[[ -n "$OUTPUT_PATH" ]] || { echo "--output required" >&2; exit 2; }
[[ -n "$AUTH_TOKEN" ]] || { echo "auth token required via RESOLVER_SIGNER_AUTH_TOKEN or --auth-token" >&2; exit 2; }
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

jq -e '.ok == true and .signed == true and (.envelope.version == "dm-hostmap-envelope.v2")' "$response_tmp" >/dev/null
jq '.envelope' "$response_tmp" >"$OUTPUT_PATH"

if [[ -n "$FULL_RESPONSE_PATH" ]]; then
  cp "$response_tmp" "$FULL_RESPONSE_PATH"
fi

echo "signed projection saved"
echo "  output=${OUTPUT_PATH}"
echo "  requestId=$(jq -r '.requestId // empty' "$response_tmp")"
echo "  snapshotId=$(jq -r '.snapshotId // empty' "$response_tmp")"
echo "  sequence=$(jq -r '.sequence // empty' "$response_tmp")"
echo "  keyId=$(jq -r '.keyId // empty' "$response_tmp")"
