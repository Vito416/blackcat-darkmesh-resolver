#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  projection-release.sh [options] [domain...]

Shared control-plane release wrapper for DarkMesh Resolver projection updates.

What it does:
  1. build unsigned dm-hostmap-envelope.v2
  2. sign it via async-worker
  3. verify it locally against trust manifest
  4. publish it via async-worker
  5. verify worker current snapshot
  6. optionally poll joined serving nodes for activation

Examples:
  projection-release.sh \
    --domains jdwt.fun,vddl.fun,blgateway.fun \
    --worker-base-url https://blackcat-async-worker.example.workers.dev

  projection-release.sh \
    --domains-file ./domains.txt \
    --worker-base-url https://blackcat-async-worker.example.workers.dev \
    --verify-node-state-url https://hyperbeam.darkmesh.fun/~darkmesh-resolver@1.0/GetResolverState

Auth:
  export RESOLVER_SIGNER_AUTH_TOKEN=...
  export RESOLVER_PUBLISH_AUTH_TOKEN=...

Useful options:
  --domains <csv>              Comma-separated domains.
  --domains-file <path>        One domain per line.
  --worker-base-url <url>      Async worker base URL.
  --projection-path <path>     Projection fetch path for verification.
                               Default: /resolver/projection/current
                               Keep the default for routine live use unless
                               you intentionally introduce a compatibility alias.
  --sequence <n|auto>          Projection sequence. Default: auto
  --ttl-sec <n>                Projection TTL / expiresAt horizon. Passed to builder.
  --refresh-cadence-sec <n>    cacheHints.refreshCadenceSec. Passed to builder.
  --lkg-max-age-sec <n>        cacheHints.lkgMaxAgeSec. Passed to builder.
  --output-dir <path>          Artifact output directory.
  --trust-manifest <path>      Local trust manifest for verify step.
  --verify-node-state-url <u>  Poll a joined node resolver state URL.
                               Can be repeated.
  --node-wait-sec <n>          Max wait for joined node activation. Default: 60
  --poll-interval-sec <n>      Poll interval for node verification. Default: 5
  --include-www                Include www aliases in built projection.
                               Default: on
  --no-include-www             Disable www alias generation.
  --allow-routing-diff         Allow removals/target changes vs current snapshot.
  --strict                     Builder strict mode.
  --dry-run                    Build + sign + local verify only; skip publish.
  -h, --help                   Show this help.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

json_get() {
  local file="$1"
  local expr="$2"
  jq -r "$expr" "$file"
}

wait_for_node_sequence() {
  local url="$1"
  local target_sequence="$2"
  local timeout_sec="$3"
  local poll_sec="$4"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local tmp
  tmp="$(mktemp)"

  while (( $(date +%s) <= deadline )); do
    if curl -fsS "$url" >"$tmp"; then
      local seq
      seq="$(jq -r '.projection.sequence // .projection.lastSequence // empty' "$tmp" 2>/dev/null || true)"
      local reason
      reason="$(jq -r '.projection.verificationReason // .projection.lastVerificationReason // empty' "$tmp" 2>/dev/null || true)"
      if [[ -n "$seq" && "$seq" =~ ^[0-9]+$ && "$seq" -ge "$target_sequence" ]]; then
        rm -f "$tmp"
        echo "node activated: $url (sequence=$seq verificationReason=${reason:-unknown})"
        return 0
      fi
    fi
    sleep "$poll_sec"
  done

  rm -f "$tmp"
  echo "node activation timeout: $url (wanted sequence >= $target_sequence)" >&2
  return 1
}

summarize_projection_diff() {
  local current_file="$1"
  local next_file="$2"
  local out_dir="$3"
  python3 - "$current_file" "$next_file" "$out_dir" <<'PY'
import json
import sys
from pathlib import Path

current_path = Path(sys.argv[1])
next_path = Path(sys.argv[2])
out_dir = Path(sys.argv[3])
out_dir.mkdir(parents=True, exist_ok=True)

def load_entries(path: Path):
    data = json.loads(path.read_text())
    return data.get("payload", {}).get("entries", [])

def normalize(entry):
    target_id = entry.get("targetTx") or entry.get("targetPid") or entry.get("targetId") or ""
    return {
        "host": entry.get("host", ""),
        "pathPrefix": entry.get("pathPrefix", "/"),
        "targetType": entry.get("targetType", ""),
        "targetId": target_id,
        "canonicalHost": entry.get("canonicalHost", ""),
        "siteId": entry.get("siteId", ""),
        "cfgTx": entry.get("cfgTx", ""),
    }

def key(entry):
    return f'{entry["host"]}\t{entry["pathPrefix"]}'

current_entries = [normalize(e) for e in load_entries(current_path)]
next_entries = [normalize(e) for e in load_entries(next_path)]
current_map = {key(e): e for e in current_entries}
next_map = {key(e): e for e in next_entries}

added_keys = sorted(set(next_map) - set(current_map))
removed_keys = sorted(set(current_map) - set(next_map))
shared_keys = sorted(set(current_map) & set(next_map))
changed_keys = [k for k in shared_keys if current_map[k] != next_map[k]]

added = [next_map[k] for k in added_keys]
removed = [current_map[k] for k in removed_keys]
changed = [{"key": k, "before": current_map[k], "after": next_map[k]} for k in changed_keys]

(out_dir / "projection-diff-added.json").write_text(json.dumps(added, indent=2) + "\n")
(out_dir / "projection-diff-removed.json").write_text(json.dumps(removed, indent=2) + "\n")
(out_dir / "projection-diff-changed.json").write_text(json.dumps(changed, indent=2) + "\n")
(out_dir / "projection-diff-summary.json").write_text(
    json.dumps(
        {
            "currentEntryCount": len(current_entries),
            "nextEntryCount": len(next_entries),
            "addedCount": len(added),
            "removedCount": len(removed),
            "changedCount": len(changed),
        },
        indent=2,
    )
    + "\n"
)
PY
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_SCRIPT="$REPO_ROOT/ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh"
SIGN_HELPER="$REPO_ROOT/ops/live-vps/local-tools/sign-projection-via-async-worker.sh"
PUBLISH_HELPER="$REPO_ROOT/ops/live-vps/local-tools/publish-projection-via-async-worker.sh"
PROJECTION_TOOL="$REPO_ROOT/scripts/projection-envelope-tool.py"

DOMAINS_CSV=""
DOMAINS_FILE=""
WORKER_BASE_URL="${DARKMESH_ASYNC_WORKER_BASE_URL:-}"
PROJECTION_PATH="${DARKMESH_PROJECTION_DISTRIBUTION_PATH:-/resolver/projection/current}"
SEQUENCE_MODE="auto"
TTL_SEC=""
REFRESH_CADENCE_SEC=""
LKG_MAX_AGE_SEC=""
OUTPUT_DIR=""
TRUST_MANIFEST="${DARKMESH_PROJECTION_TRUST_MANIFEST:-$HOME/.config/darkmesh/projection-signer-2026-q2/projection-trust.json}"
INCLUDE_WWW=1
STRICT=0
DRY_RUN=0
NODE_WAIT_SEC=60
POLL_INTERVAL_SEC=5
ALLOW_ROUTING_DIFF=0
DNS_URL=""
AR_BASE=""
SOURCE_DESCRIPTION="control-plane-release"
ISSUED_BY_NODE="control-plane"
ISSUED_BY_RESOLVER="darkmesh-resolver-mainnet"
SIGNED_BY="darkmesh-resolver-mainnet"
KEY_ID="darkmesh-projection-key-2026-q2"
SIGNER_AUTH_TOKEN="${RESOLVER_SIGNER_AUTH_TOKEN:-}"
PUBLISH_AUTH_TOKEN="${RESOLVER_PUBLISH_AUTH_TOKEN:-}"
declare -a VERIFY_NODE_STATE_URLS=()
declare -a POSITIONAL_DOMAINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domains) DOMAINS_CSV="${2:-}"; shift 2 ;;
    --domains-file) DOMAINS_FILE="${2:-}"; shift 2 ;;
    --worker-base-url) WORKER_BASE_URL="${2:-}"; shift 2 ;;
    --projection-path) PROJECTION_PATH="${2:-}"; shift 2 ;;
    --sequence) SEQUENCE_MODE="${2:-}"; shift 2 ;;
    --ttl-sec) TTL_SEC="${2:-}"; shift 2 ;;
    --refresh-cadence-sec) REFRESH_CADENCE_SEC="${2:-}"; shift 2 ;;
    --lkg-max-age-sec) LKG_MAX_AGE_SEC="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --trust-manifest) TRUST_MANIFEST="${2:-}"; shift 2 ;;
    --verify-node-state-url) VERIFY_NODE_STATE_URLS+=("${2:-}"); shift 2 ;;
    --node-wait-sec) NODE_WAIT_SEC="${2:-}"; shift 2 ;;
    --poll-interval-sec) POLL_INTERVAL_SEC="${2:-}"; shift 2 ;;
    --dns-url) DNS_URL="${2:-}"; shift 2 ;;
    --ar-base) AR_BASE="${2:-}"; shift 2 ;;
    --source-description) SOURCE_DESCRIPTION="${2:-}"; shift 2 ;;
    --issued-by-node) ISSUED_BY_NODE="${2:-}"; shift 2 ;;
    --issued-by-resolver) ISSUED_BY_RESOLVER="${2:-}"; shift 2 ;;
    --signed-by) SIGNED_BY="${2:-}"; shift 2 ;;
    --key-id) KEY_ID="${2:-}"; shift 2 ;;
    --signer-auth-token) SIGNER_AUTH_TOKEN="${2:-}"; shift 2 ;;
    --publish-auth-token) PUBLISH_AUTH_TOKEN="${2:-}"; shift 2 ;;
    --include-www) INCLUDE_WWW=1; shift ;;
    --no-include-www) INCLUDE_WWW=0; shift ;;
    --allow-routing-diff) ALLOW_ROUTING_DIFF=1; shift ;;
    --strict) STRICT=1; shift ;;
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
bash -n "$BUILD_SCRIPT" >/dev/null
bash -n "$SIGN_HELPER" >/dev/null
bash -n "$PUBLISH_HELPER" >/dev/null

[[ -n "$WORKER_BASE_URL" ]] || {
  echo "--worker-base-url or DARKMESH_ASYNC_WORKER_BASE_URL is required" >&2
  exit 2
}
[[ "$PROJECTION_PATH" == /* ]] || {
  echo "--projection-path must start with /" >&2
  exit 2
}

if [[ -z "$DOMAINS_CSV" && -z "$DOMAINS_FILE" && "${#POSITIONAL_DOMAINS[@]}" -eq 0 ]]; then
  echo "provide domains via --domains, --domains-file, or positional args" >&2
  exit 2
fi

if ! [[ "$NODE_WAIT_SEC" =~ ^[0-9]+$ ]] || ! [[ "$POLL_INTERVAL_SEC" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_SEC < 1 )); then
  echo "--node-wait-sec and --poll-interval-sec must be positive integers" >&2
  exit 2
fi

[[ -n "$SIGNER_AUTH_TOKEN" ]] || {
  echo "missing signer auth token (RESOLVER_SIGNER_AUTH_TOKEN or --signer-auth-token)" >&2
  exit 2
}

if (( DRY_RUN == 0 )); then
  [[ -n "$PUBLISH_AUTH_TOKEN" ]] || {
    echo "missing publish auth token (RESOLVER_PUBLISH_AUTH_TOKEN or --publish-auth-token)" >&2
    exit 2
  }
fi

[[ -f "$TRUST_MANIFEST" ]] || {
  echo "trust manifest not found: $TRUST_MANIFEST" >&2
  exit 2
}

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "$OUTPUT_DIR"
fi

CURRENT_URL="${WORKER_BASE_URL%/}${PROJECTION_PATH}"
SIGN_URL="${WORKER_BASE_URL%/}/resolver/projection/sign"
PUBLISH_URL="${WORKER_BASE_URL%/}/resolver/projection/publish"
UNSIGNED_PATH="$OUTPUT_DIR/resolver-projection.unsigned.v2.json"
SIGNED_PATH="$OUTPUT_DIR/resolver-projection.signed.v2.json"
SIGN_RESPONSE_PATH="$OUTPUT_DIR/sign-response.json"
PUBLISH_RESPONSE_PATH="$OUTPUT_DIR/publish-response.json"
CURRENT_BEFORE_PATH="$OUTPUT_DIR/current-before.json"
CURRENT_AFTER_PATH="$OUTPUT_DIR/current-after.json"
METADATA_PATH="$OUTPUT_DIR/release-metadata.json"
DIFF_DIR="$OUTPUT_DIR/diff"

CURRENT_SEQUENCE=0
CURRENT_SNAPSHOT_ID=""
CURRENT_KEY_ID=""
if curl -fsS "$CURRENT_URL" >"$CURRENT_BEFORE_PATH" 2>/dev/null; then
  CURRENT_SEQUENCE="$(jq -r '.sequence // 0' "$CURRENT_BEFORE_PATH")"
  CURRENT_SNAPSHOT_ID="$(jq -r '.snapshotId // empty' "$CURRENT_BEFORE_PATH")"
  CURRENT_KEY_ID="$(jq -r '.keyId // empty' "$CURRENT_BEFORE_PATH")"
fi

case "$SEQUENCE_MODE" in
  auto)
    NEXT_SEQUENCE=$(( CURRENT_SEQUENCE + 1 ))
    ;;
  *)
    if ! [[ "$SEQUENCE_MODE" =~ ^[0-9]+$ ]]; then
      echo "--sequence must be integer or auto" >&2
      exit 2
    fi
    NEXT_SEQUENCE="$SEQUENCE_MODE"
    ;;
esac

BUILD_ARGS=(
  --output "$UNSIGNED_PATH"
  --envelope-version v2
  --sequence "$NEXT_SEQUENCE"
  --signed-by "$SIGNED_BY"
  --key-id "$KEY_ID"
  --issued-by-node "$ISSUED_BY_NODE"
  --issued-by-resolver "$ISSUED_BY_RESOLVER"
  --source-description "$SOURCE_DESCRIPTION"
  --projection-tool-bin "$PROJECTION_TOOL"
)

[[ -n "$DOMAINS_CSV" ]] && BUILD_ARGS+=(--domains "$DOMAINS_CSV")
[[ -n "$DOMAINS_FILE" ]] && BUILD_ARGS+=(--domains-file "$DOMAINS_FILE")
[[ -n "$DNS_URL" ]] && BUILD_ARGS+=(--dns-url "$DNS_URL")
[[ -n "$AR_BASE" ]] && BUILD_ARGS+=(--ar-base "$AR_BASE")
[[ -n "$TTL_SEC" ]] && BUILD_ARGS+=(--expires-in-sec "$TTL_SEC")
[[ -n "$REFRESH_CADENCE_SEC" ]] && BUILD_ARGS+=(--refresh-cadence-sec "$REFRESH_CADENCE_SEC")
[[ -n "$LKG_MAX_AGE_SEC" ]] && BUILD_ARGS+=(--lkg-max-age-sec "$LKG_MAX_AGE_SEC")
(( INCLUDE_WWW == 1 )) && BUILD_ARGS+=(--include-www)
(( STRICT == 1 )) && BUILD_ARGS+=(--strict)
if (( ${#POSITIONAL_DOMAINS[@]} > 0 )); then
  BUILD_ARGS+=(-- "${POSITIONAL_DOMAINS[@]}")
fi

echo "building unsigned projection..."
bash "$BUILD_SCRIPT" "${BUILD_ARGS[@]}"

echo "signing projection via async-worker..."
bash "$SIGN_HELPER" \
  --worker-url "$SIGN_URL" \
  --input "$UNSIGNED_PATH" \
  --output "$SIGNED_PATH" \
  --auth-token "$SIGNER_AUTH_TOKEN" \
  --full-response-output "$SIGN_RESPONSE_PATH"

echo "verifying signed projection locally..."
python3 "$PROJECTION_TOOL" verify "$SIGNED_PATH" "$TRUST_MANIFEST" >"$OUTPUT_DIR/local-verify.json"
jq -e '.ok == true' "$OUTPUT_DIR/local-verify.json" >/dev/null

PUBLISHED_SEQUENCE="$(json_get "$SIGNED_PATH" '.sequence // 0')"
PUBLISHED_SNAPSHOT_ID="$(json_get "$SIGNED_PATH" '.snapshotId // empty')"
PUBLISHED_KEY_ID="$(json_get "$SIGNED_PATH" '.keyId // empty')"
PUBLISHED_PAYLOAD_HASH="$(json_get "$SIGNED_PATH" '.payloadHash // empty')"

if [[ -s "$CURRENT_BEFORE_PATH" ]]; then
  summarize_projection_diff "$CURRENT_BEFORE_PATH" "$SIGNED_PATH" "$DIFF_DIR"
  ADDED_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.addedCount // 0')"
  REMOVED_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.removedCount // 0')"
  CHANGED_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.changedCount // 0')"
  CURRENT_ENTRY_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.currentEntryCount // 0')"
  NEXT_ENTRY_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.nextEntryCount // 0')"
  echo "projection diff summary"
  echo "  currentEntries=$CURRENT_ENTRY_COUNT"
  echo "  nextEntries=$NEXT_ENTRY_COUNT"
  echo "  added=$ADDED_COUNT"
  echo "  removed=$REMOVED_COUNT"
  echo "  changed=$CHANGED_COUNT"
  if (( REMOVED_COUNT > 0 || CHANGED_COUNT > 0 )) && (( ALLOW_ROUTING_DIFF == 0 )); then
    echo "routing diff guard triggered; review $DIFF_DIR and rerun with --allow-routing-diff if intended" >&2
    exit 1
  fi
fi

if (( DRY_RUN == 1 )); then
  jq -n \
    --arg mode "dry_run" \
    --arg workerBaseUrl "$WORKER_BASE_URL" \
    --arg outputDir "$OUTPUT_DIR" \
    --arg trustManifest "$TRUST_MANIFEST" \
    --arg ttlSec "${TTL_SEC:-}" \
    --arg refreshCadenceSec "${REFRESH_CADENCE_SEC:-}" \
    --arg lkgMaxAgeSec "${LKG_MAX_AGE_SEC:-}" \
    --arg snapshotId "$PUBLISHED_SNAPSHOT_ID" \
    --arg keyId "$PUBLISHED_KEY_ID" \
    --arg payloadHash "$PUBLISHED_PAYLOAD_HASH" \
    --arg diffDir "$DIFF_DIR" \
    --argjson sequence "$PUBLISHED_SEQUENCE" \
    '{
      mode:$mode,
      workerBaseUrl:$workerBaseUrl,
      outputDir:$outputDir,
      trustManifest:$trustManifest,
      diffDir:$diffDir,
      snapshotId:$snapshotId,
      sequence:$sequence,
      keyId:$keyId,
      payloadHash:$payloadHash,
      ttlSec:(if $ttlSec == "" then null else ($ttlSec | tonumber) end),
      refreshCadenceSec:(if $refreshCadenceSec == "" then null else ($refreshCadenceSec | tonumber) end),
      lkgMaxAgeSec:(if $lkgMaxAgeSec == "" then null else ($lkgMaxAgeSec | tonumber) end)
    }' >"$METADATA_PATH"
  echo "dry run complete"
  echo "  outputDir=$OUTPUT_DIR"
  echo "  snapshotId=$PUBLISHED_SNAPSHOT_ID"
  echo "  sequence=$PUBLISHED_SEQUENCE"
  exit 0
fi

echo "publishing signed projection..."
bash "$PUBLISH_HELPER" \
  --worker-url "$PUBLISH_URL" \
  --input "$SIGNED_PATH" \
  --auth-token "$PUBLISH_AUTH_TOKEN" \
  --output "$PUBLISH_RESPONSE_PATH"

echo "verifying worker current snapshot..."
curl -fsS "$CURRENT_URL" >"$CURRENT_AFTER_PATH"
jq -e --arg snapshotId "$PUBLISHED_SNAPSHOT_ID" --arg payloadHash "$PUBLISHED_PAYLOAD_HASH" \
  '.snapshotId == $snapshotId and .payloadHash == $payloadHash' "$CURRENT_AFTER_PATH" >/dev/null

for url in "${VERIFY_NODE_STATE_URLS[@]}"; do
  echo "waiting for joined node activation: $url"
  wait_for_node_sequence "$url" "$PUBLISHED_SEQUENCE" "$NODE_WAIT_SEC" "$POLL_INTERVAL_SEC"
done

jq -n \
  --arg mode "published" \
  --arg workerBaseUrl "$WORKER_BASE_URL" \
  --arg currentUrl "$CURRENT_URL" \
  --arg outputDir "$OUTPUT_DIR" \
  --arg trustManifest "$TRUST_MANIFEST" \
  --arg diffDir "$DIFF_DIR" \
  --arg ttlSec "${TTL_SEC:-}" \
  --arg refreshCadenceSec "${REFRESH_CADENCE_SEC:-}" \
  --arg lkgMaxAgeSec "${LKG_MAX_AGE_SEC:-}" \
  --arg previousSnapshotId "$CURRENT_SNAPSHOT_ID" \
  --arg previousKeyId "$CURRENT_KEY_ID" \
  --arg snapshotId "$PUBLISHED_SNAPSHOT_ID" \
  --arg keyId "$PUBLISHED_KEY_ID" \
  --arg payloadHash "$PUBLISHED_PAYLOAD_HASH" \
  --argjson previousSequence "$CURRENT_SEQUENCE" \
  --argjson sequence "$PUBLISHED_SEQUENCE" \
  --argjson verifyNodeStateUrls "$(printf '%s\n' "${VERIFY_NODE_STATE_URLS[@]}" | jq -R . | jq -s .)" \
  '{
    mode:$mode,
    workerBaseUrl:$workerBaseUrl,
    currentUrl:$currentUrl,
    outputDir:$outputDir,
    trustManifest:$trustManifest,
    diffDir:$diffDir,
    ttlSec:(if $ttlSec == "" then null else ($ttlSec | tonumber) end),
    refreshCadenceSec:(if $refreshCadenceSec == "" then null else ($refreshCadenceSec | tonumber) end),
    lkgMaxAgeSec:(if $lkgMaxAgeSec == "" then null else ($lkgMaxAgeSec | tonumber) end),
    previous:{snapshotId:$previousSnapshotId,sequence:$previousSequence,keyId:$previousKeyId},
    published:{snapshotId:$snapshotId,sequence:$sequence,keyId:$keyId,payloadHash:$payloadHash},
    verifyNodeStateUrls:$verifyNodeStateUrls
  }' >"$METADATA_PATH"

echo "projection release complete"
echo "  outputDir=$OUTPUT_DIR"
echo "  previousSequence=$CURRENT_SEQUENCE"
echo "  sequence=$PUBLISHED_SEQUENCE"
echo "  snapshotId=$PUBLISHED_SNAPSHOT_ID"
echo "  keyId=$PUBLISHED_KEY_ID"
