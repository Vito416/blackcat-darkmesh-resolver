#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  bootstrap-async-worker-signer.sh \
    --material-dir /path/to/generated-signing-material \
    --worker-dir /path/to/blackcat-darkmesh-gateway/workers/async-worker

What it does:
  - reads generated signing material from generate-projection-signing-material.py
  - writes a local wrangler.toml from wrangler.toml.example
  - prints the exact wrangler secret commands you still need to run manually

It does NOT:
  - deploy the worker
  - upload secrets automatically
  - touch any VPS
USAGE
}

MATERIAL_DIR=""
WORKER_DIR=""
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --material-dir) MATERIAL_DIR="$2"; shift 2 ;;
    --worker-dir) WORKER_DIR="$2"; shift 2 ;;
    --output) OUTPUT_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$MATERIAL_DIR" ]] || { echo "--material-dir required" >&2; exit 2; }
[[ -n "$WORKER_DIR" ]] || { echo "--worker-dir required" >&2; exit 2; }
[[ -d "$MATERIAL_DIR" ]] || { echo "material dir not found: $MATERIAL_DIR" >&2; exit 2; }
[[ -d "$WORKER_DIR" ]] || { echo "worker dir not found: $WORKER_DIR" >&2; exit 2; }

ENV_SNIPPET="$MATERIAL_DIR/async-worker-vars.env"
PRIVATE_KEY_FILE="$MATERIAL_DIR/projection-signing-key.pem"
TRUST_MANIFEST_FILE="$MATERIAL_DIR/projection-trust.json"
TEMPLATE_FILE="$WORKER_DIR/wrangler.toml.example"

[[ -f "$ENV_SNIPPET" ]] || { echo "missing async-worker-vars.env in $MATERIAL_DIR" >&2; exit 2; }
[[ -f "$PRIVATE_KEY_FILE" ]] || { echo "missing projection-signing-key.pem in $MATERIAL_DIR" >&2; exit 2; }
[[ -f "$TRUST_MANIFEST_FILE" ]] || { echo "missing projection-trust.json in $MATERIAL_DIR" >&2; exit 2; }
[[ -f "$TEMPLATE_FILE" ]] || { echo "missing wrangler.toml.example in $WORKER_DIR" >&2; exit 2; }

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$WORKER_DIR/wrangler.toml"
fi

SIGNED_BY="$(grep '^RESOLVER_SIGNER_SIGNED_BY=' "$ENV_SNIPPET" | head -n1 | cut -d= -f2-)"
KEY_ID="$(grep '^RESOLVER_SIGNER_KEY_ID=' "$ENV_SNIPPET" | head -n1 | cut -d= -f2-)"
[[ -n "$SIGNED_BY" ]] || { echo "failed to read RESOLVER_SIGNER_SIGNED_BY from $ENV_SNIPPET" >&2; exit 2; }
[[ -n "$KEY_ID" ]] || { echo "failed to read RESOLVER_SIGNER_KEY_ID from $ENV_SNIPPET" >&2; exit 2; }

cp "$TEMPLATE_FILE" "$OUTPUT_PATH"
python3 - "$OUTPUT_PATH" "$SIGNED_BY" "$KEY_ID" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
signed_by = sys.argv[2]
key_id = sys.argv[3]
text = path.read_text(encoding='utf-8')
text = text.replace('RESOLVER_SIGNER_SIGNED_BY = "darkmesh-resolver-mainnet"', f'RESOLVER_SIGNER_SIGNED_BY = "{signed_by}"')
text = text.replace('RESOLVER_SIGNER_KEY_ID = "darkmesh-projection-key-2026-q2"', f'RESOLVER_SIGNER_KEY_ID = "{key_id}"')
path.write_text(text, encoding='utf-8')
PY

cat <<SUMMARY
Prepared worker bootstrap files:
  wrangler_toml=${OUTPUT_PATH}
  trust_manifest=${TRUST_MANIFEST_FILE}

Run these manually inside ${WORKER_DIR}:

  wrangler secret put RESOLVER_SIGNER_AUTH_TOKEN
  wrangler secret put RESOLVER_SIGNER_PRIVATE_KEY < "${PRIVATE_KEY_FILE}"
  npm run deploy

After deploy, test signer with:

  export RESOLVER_SIGNER_AUTH_TOKEN='<same token>'
  bash /mnt/c/Users/jaine/Desktop/BLACKCAT_MESH_NEXUS/blackcat-darkmesh-resolver/ops/live-vps/local-tools/sign-projection-via-async-worker.sh \
    --worker-url https://<your-async-worker>/resolver/projection/sign \
    --input /tmp/resolver-projection.unsigned.v2.json \
    --output /tmp/resolver-projection.signed.v2.json
SUMMARY
