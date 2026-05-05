#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  projection-release-private-file.sh [options] [domain...]

Private/operator projection release path without async-worker bearer tokens.

What it does:
  1. build a signed dm-hostmap-envelope.v2 locally with a local Ed25519 key
  2. verify it locally against the trust manifest
  3. optionally copy it to a joined node over SSH/Tailscale
  4. optionally flip the joined node to file:// verify-only mode
  5. optionally trigger sync and wait for activation

Default safety posture:
  - local build + verify only
  - no SSH/write unless --execute-live 1 is provided

Examples:
  projection-release-private-file.sh \
    --domains jdwt.fun,vddl.fun,blgateway.fun

  projection-release-private-file.sh \
    --domains jdwt.fun,vddl.fun,blgateway.fun \
    --execute-live 1 \
    --ssh-target adminops@100.104.75.121 \
    --ssh-key ~/.ssh/darkmesh_new_vps_adminops \
    --switch-node-to-file-url 1 \
    --verify-node-state-via-ssh 1

Important:
  This is the minimal-surface operator path. It does not require:
  - RESOLVER_SIGNER_AUTH_TOKEN
  - RESOLVER_PUBLISH_AUTH_TOKEN
  - RESOLVER_CONTROL_AUTH_TOKEN

Options:
  --domains <csv>                Comma-separated domains.
  --domains-file <path>          One domain per line.
  --output-dir <path>            Artifact output directory.
  --signing-key <path>           Local Ed25519 private key PEM.
  --trust-manifest <path>        Local trust manifest.
  --current-projection-url <u>   Read-only URL used for auto sequence.
  --current-node-state-url <u>   Optional read-only node state URL for auto sequence.
  --sequence <n|auto>            Default: auto
  --ttl-sec <n>                  Projection expiresAt horizon.
  --refresh-cadence-sec <n>      cacheHints.refreshCadenceSec.
  --lkg-max-age-sec <n>          cacheHints.lkgMaxAgeSec.
  --execute-live <0|1>           Actually copy/install/sync on the node. Default: 0
  --ssh-target <user@host>       Tailscale/private SSH target.
  --ssh-key <path>               SSH private key for the target.
  --remote-projection-path <p>   Default: /etc/darkmesh/projections/resolver-projection.active.v2.json
  --remote-env-file <path>       Default: /etc/darkmesh/resolver-projection.env
  --remote-state-file <path>     Default: /var/lib/darkmesh/host-routing/state.json
  --switch-node-to-file-url <0|1>
                                 Update remote env to file:// verify-only mode.
                                 Default: 0
  --verify-node-state-url <u>    Poll this URL after live sync.
  --verify-node-state-via-ssh <0|1>
                                 Poll remote state.json over SSH after live sync.
                                 Default: 0
  --node-wait-sec <n>            Default: 60
  --poll-interval-sec <n>        Default: 5
  --include-www                  Include www aliases. Default: on
  --no-include-www               Disable www alias generation.
  --allow-routing-diff           Allow removals/target changes vs current projection.
  --strict                       Builder strict mode.
  -h, --help                     Show this help.
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

fetch_sequence_from_url() {
  local url="$1"
  local out="$2"
  if [[ -z "$url" ]]; then
    echo 0 >"$out"
    return 0
  fi
  if curl -fsS "$url" >"$out" 2>/dev/null; then
    jq -r '.sequence // .projection.sequence // .projection.lastSequence // 0' "$out" 2>/dev/null || echo 0
  else
    echo 0
  fi
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
      local mode
      mode="$(jq -r '.projection.mode // empty' "$tmp" 2>/dev/null || true)"
      if [[ -n "$seq" && "$seq" =~ ^[0-9]+$ && "$seq" -ge "$target_sequence" && "$mode" == "active" ]]; then
        rm -f "$tmp"
        echo "node activated: $url (sequence=$seq mode=$mode verificationReason=${reason:-unknown})"
        return 0
      fi
    fi
    sleep "$poll_sec"
  done

  rm -f "$tmp"
  echo "node activation timeout: $url (wanted active sequence >= $target_sequence)" >&2
  return 1
}

wait_for_remote_node_sequence() {
  local ssh_target="$1"
  local target_sequence="$2"
  local timeout_sec="$3"
  local poll_sec="$4"
  local remote_state_file="$5"
  local deadline=$(( $(date +%s) + timeout_sec ))
  local mode=""
  local seq=""
  local reason=""

  while (( $(date +%s) <= deadline )); do
    if read -r mode seq reason < <(
      ssh "${SSH_ARGS[@]}" "$ssh_target" \
        "sudo jq -r '[.mode // \"\", (.lastSequence // \"\" | tostring), .lastVerificationReason // \"\"] | @tsv' '$remote_state_file' 2>/dev/null" \
        | awk -F '\t' 'NF >= 3 { print $1, $2, $3 }'
    ); then
      if [[ -n "$seq" && "$seq" =~ ^[0-9]+$ && "$seq" -ge "$target_sequence" && "$mode" == "active" ]]; then
        echo "node activated via ssh: $ssh_target (sequence=$seq mode=$mode verificationReason=${reason:-unknown})"
        return 0
      fi
    fi
    sleep "$poll_sec"
  done

  echo "node activation timeout via ssh: $ssh_target (wanted active sequence >= $target_sequence)" >&2
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
PROJECTION_TOOL="$REPO_ROOT/scripts/projection-envelope-tool.py"

DOMAINS_CSV=""
DOMAINS_FILE=""
OUTPUT_DIR=""
SIGNING_KEY="${HOME}/.config/darkmesh/projection-signer-2026-q2/projection-signing-key.pem"
TRUST_MANIFEST="${HOME}/.config/darkmesh/projection-signer-2026-q2/projection-trust.json"
CURRENT_PROJECTION_URL="${DARKMESH_CURRENT_PROJECTION_URL:-https://blackcat-async-worker.vitek-pasek.workers.dev/resolver/projection/current}"
CURRENT_NODE_STATE_URL=""
SEQUENCE_MODE="auto"
TTL_SEC=""
REFRESH_CADENCE_SEC=""
LKG_MAX_AGE_SEC=""
INCLUDE_WWW=1
STRICT=0
ALLOW_ROUTING_DIFF=0
EXECUTE_LIVE=0
SSH_TARGET="${DARKMESH_REFERENCE_NODE_SSH_TARGET:-}"
SSH_KEY="${DARKMESH_REFERENCE_NODE_SSH_KEY:-}"
REMOTE_PROJECTION_PATH="/etc/darkmesh/projections/resolver-projection.active.v2.json"
REMOTE_ENV_FILE="/etc/darkmesh/resolver-projection.env"
REMOTE_STATE_FILE="/var/lib/darkmesh/host-routing/state.json"
SWITCH_NODE_TO_FILE_URL=0
VERIFY_NODE_STATE_URL=""
VERIFY_NODE_STATE_VIA_SSH=0
NODE_WAIT_SEC=60
POLL_INTERVAL_SEC=5
DNS_URL=""
AR_BASE=""
SOURCE_DESCRIPTION="private-file-release"
ISSUED_BY_NODE="control-plane"
ISSUED_BY_RESOLVER="darkmesh-resolver-mainnet"
SIGNED_BY="darkmesh-resolver-mainnet"
KEY_ID="darkmesh-projection-key-2026-q2"
declare -a POSITIONAL_DOMAINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domains) DOMAINS_CSV="${2:-}"; shift 2 ;;
    --domains-file) DOMAINS_FILE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --signing-key) SIGNING_KEY="${2:-}"; shift 2 ;;
    --trust-manifest) TRUST_MANIFEST="${2:-}"; shift 2 ;;
    --current-projection-url) CURRENT_PROJECTION_URL="${2:-}"; shift 2 ;;
    --current-node-state-url) CURRENT_NODE_STATE_URL="${2:-}"; shift 2 ;;
    --sequence) SEQUENCE_MODE="${2:-}"; shift 2 ;;
    --ttl-sec) TTL_SEC="${2:-}"; shift 2 ;;
    --refresh-cadence-sec) REFRESH_CADENCE_SEC="${2:-}"; shift 2 ;;
    --lkg-max-age-sec) LKG_MAX_AGE_SEC="${2:-}"; shift 2 ;;
    --execute-live) EXECUTE_LIVE="${2:-}"; shift 2 ;;
    --ssh-target) SSH_TARGET="${2:-}"; shift 2 ;;
    --ssh-key) SSH_KEY="${2:-}"; shift 2 ;;
    --remote-projection-path) REMOTE_PROJECTION_PATH="${2:-}"; shift 2 ;;
    --remote-env-file) REMOTE_ENV_FILE="${2:-}"; shift 2 ;;
    --remote-state-file) REMOTE_STATE_FILE="${2:-}"; shift 2 ;;
    --switch-node-to-file-url) SWITCH_NODE_TO_FILE_URL="${2:-}"; shift 2 ;;
    --verify-node-state-url) VERIFY_NODE_STATE_URL="${2:-}"; shift 2 ;;
    --verify-node-state-via-ssh) VERIFY_NODE_STATE_VIA_SSH="${2:-}"; shift 2 ;;
    --node-wait-sec) NODE_WAIT_SEC="${2:-}"; shift 2 ;;
    --poll-interval-sec) POLL_INTERVAL_SEC="${2:-}"; shift 2 ;;
    --dns-url) DNS_URL="${2:-}"; shift 2 ;;
    --ar-base) AR_BASE="${2:-}"; shift 2 ;;
    --source-description) SOURCE_DESCRIPTION="${2:-}"; shift 2 ;;
    --issued-by-node) ISSUED_BY_NODE="${2:-}"; shift 2 ;;
    --issued-by-resolver) ISSUED_BY_RESOLVER="${2:-}"; shift 2 ;;
    --signed-by) SIGNED_BY="${2:-}"; shift 2 ;;
    --key-id) KEY_ID="${2:-}"; shift 2 ;;
    --include-www) INCLUDE_WWW=1; shift ;;
    --no-include-www) INCLUDE_WWW=0; shift ;;
    --allow-routing-diff) ALLOW_ROUTING_DIFF=1; shift ;;
    --strict) STRICT=1; shift ;;
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

[[ -f "$SIGNING_KEY" ]] || { echo "signing key not found: $SIGNING_KEY" >&2; exit 2; }
[[ -f "$TRUST_MANIFEST" ]] || { echo "trust manifest not found: $TRUST_MANIFEST" >&2; exit 2; }

if [[ -z "$DOMAINS_CSV" && -z "$DOMAINS_FILE" && "${#POSITIONAL_DOMAINS[@]}" -eq 0 ]]; then
  echo "provide domains via --domains, --domains-file, or positional args" >&2
  exit 2
fi

if ! [[ "$NODE_WAIT_SEC" =~ ^[0-9]+$ ]] || ! [[ "$POLL_INTERVAL_SEC" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_SEC < 1 )); then
  echo "--node-wait-sec and --poll-interval-sec must be positive integers" >&2
  exit 2
fi

if [[ "$EXECUTE_LIVE" != "0" && "$EXECUTE_LIVE" != "1" ]]; then
  echo "--execute-live must be 0 or 1" >&2
  exit 2
fi
if [[ "$SWITCH_NODE_TO_FILE_URL" != "0" && "$SWITCH_NODE_TO_FILE_URL" != "1" ]]; then
  echo "--switch-node-to-file-url must be 0 or 1" >&2
  exit 2
fi
if [[ "$VERIFY_NODE_STATE_VIA_SSH" != "0" && "$VERIFY_NODE_STATE_VIA_SSH" != "1" ]]; then
  echo "--verify-node-state-via-ssh must be 0 or 1" >&2
  exit 2
fi

if (( EXECUTE_LIVE == 1 )); then
  [[ -n "$SSH_TARGET" ]] || { echo "--ssh-target is required when --execute-live 1" >&2; exit 2; }
  require_cmd ssh
  require_cmd scp
fi

if (( VERIFY_NODE_STATE_VIA_SSH == 1 && EXECUTE_LIVE != 1 )); then
  echo "--verify-node-state-via-ssh 1 requires --execute-live 1" >&2
  exit 2
fi
if (( VERIFY_NODE_STATE_VIA_SSH == 1 )) && [[ -z "$SSH_TARGET" ]]; then
  echo "--verify-node-state-via-ssh 1 requires --ssh-target" >&2
  exit 2
fi

if (( SWITCH_NODE_TO_FILE_URL == 1 && EXECUTE_LIVE != 1 )); then
  echo "--switch-node-to-file-url 1 requires --execute-live 1" >&2
  exit 2
fi

SSH_ARGS=()
SCP_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_ARGS+=(-i "$SSH_KEY")
  SCP_ARGS+=(-i "$SSH_KEY")
fi
SSH_ARGS+=(-o BatchMode=yes)
SCP_ARGS+=(-o BatchMode=yes)

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
else
  mkdir -p "$OUTPUT_DIR"
fi

CURRENT_PROJECTION_JSON="$OUTPUT_DIR/current-projection.json"
CURRENT_NODE_STATE_JSON="$OUTPUT_DIR/current-node-state.json"
SIGNED_PATH="$OUTPUT_DIR/resolver-projection.signed.v2.json"
LOCAL_VERIFY_PATH="$OUTPUT_DIR/local-verify.json"
METADATA_PATH="$OUTPUT_DIR/private-file-release.json"
DIFF_DIR="$OUTPUT_DIR/diff"

CURRENT_PROJECTION_SEQUENCE="$(fetch_sequence_from_url "$CURRENT_PROJECTION_URL" "$CURRENT_PROJECTION_JSON")"
CURRENT_NODE_SEQUENCE="$(fetch_sequence_from_url "$CURRENT_NODE_STATE_URL" "$CURRENT_NODE_STATE_JSON")"
if ! [[ "$CURRENT_PROJECTION_SEQUENCE" =~ ^[0-9]+$ ]]; then CURRENT_PROJECTION_SEQUENCE=0; fi
if ! [[ "$CURRENT_NODE_SEQUENCE" =~ ^[0-9]+$ ]]; then CURRENT_NODE_SEQUENCE=0; fi

CURRENT_SEQUENCE="$CURRENT_PROJECTION_SEQUENCE"
if (( CURRENT_NODE_SEQUENCE > CURRENT_SEQUENCE )); then
  CURRENT_SEQUENCE="$CURRENT_NODE_SEQUENCE"
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
  --output "$SIGNED_PATH"
  --envelope-version v2
  --sequence "$NEXT_SEQUENCE"
  --signed-by "$SIGNED_BY"
  --key-id "$KEY_ID"
  --issued-by-node "$ISSUED_BY_NODE"
  --issued-by-resolver "$ISSUED_BY_RESOLVER"
  --source-description "$SOURCE_DESCRIPTION"
  --projection-tool-bin "$PROJECTION_TOOL"
  --sign-with "$SIGNING_KEY"
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

echo "building and signing projection locally..."
bash "$BUILD_SCRIPT" "${BUILD_ARGS[@]}"

echo "verifying signed projection locally..."
python3 "$PROJECTION_TOOL" verify "$SIGNED_PATH" "$TRUST_MANIFEST" >"$LOCAL_VERIFY_PATH"
jq -e '.ok == true' "$LOCAL_VERIFY_PATH" >/dev/null

PUBLISHED_SEQUENCE="$(json_get "$SIGNED_PATH" '.sequence // 0')"
PUBLISHED_SNAPSHOT_ID="$(json_get "$SIGNED_PATH" '.snapshotId // empty')"
PUBLISHED_KEY_ID="$(json_get "$SIGNED_PATH" '.keyId // empty')"
PUBLISHED_PAYLOAD_HASH="$(json_get "$SIGNED_PATH" '.payloadHash // empty')"

if [[ -s "$CURRENT_PROJECTION_JSON" ]]; then
  summarize_projection_diff "$CURRENT_PROJECTION_JSON" "$SIGNED_PATH" "$DIFF_DIR"
  REMOVED_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.removedCount // 0')"
  CHANGED_COUNT="$(json_get "$DIFF_DIR/projection-diff-summary.json" '.changedCount // 0')"
  if (( REMOVED_COUNT > 0 || CHANGED_COUNT > 0 )) && (( ALLOW_ROUTING_DIFF == 0 )); then
    echo "routing diff guard triggered; review $DIFF_DIR and rerun with --allow-routing-diff if intended" >&2
    exit 1
  fi
fi

if (( EXECUTE_LIVE == 0 )); then
  jq -n \
    --arg mode "local_verified_only" \
    --arg outputDir "$OUTPUT_DIR" \
    --arg signingKey "$SIGNING_KEY" \
    --arg trustManifest "$TRUST_MANIFEST" \
    --arg currentProjectionUrl "$CURRENT_PROJECTION_URL" \
    --arg currentNodeStateUrl "$CURRENT_NODE_STATE_URL" \
    --arg remoteProjectionPath "$REMOTE_PROJECTION_PATH" \
    --arg remoteEnvFile "$REMOTE_ENV_FILE" \
    --arg snapshotId "$PUBLISHED_SNAPSHOT_ID" \
    --arg keyId "$PUBLISHED_KEY_ID" \
    --arg payloadHash "$PUBLISHED_PAYLOAD_HASH" \
    --arg diffDir "$DIFF_DIR" \
    --argjson executeLive false \
    --argjson switchNodeToFileUrl "$( [[ "$SWITCH_NODE_TO_FILE_URL" == "1" ]] && echo true || echo false )" \
    --argjson currentSequence "$CURRENT_SEQUENCE" \
    --argjson sequence "$PUBLISHED_SEQUENCE" \
    '{
      mode:$mode,
      executeLive:$executeLive,
      switchNodeToFileUrl:$switchNodeToFileUrl,
      outputDir:$outputDir,
      signingKey:$signingKey,
      trustManifest:$trustManifest,
      currentProjectionUrl:$currentProjectionUrl,
      currentNodeStateUrl:(if $currentNodeStateUrl == "" then null else $currentNodeStateUrl end),
      remoteProjectionPath:$remoteProjectionPath,
      remoteEnvFile:$remoteEnvFile,
      currentSequence:$currentSequence,
      published:{snapshotId:$snapshotId,sequence:$sequence,keyId:$keyId,payloadHash:$payloadHash},
      diffDir:$diffDir
    }' >"$METADATA_PATH"
  echo "local signed release is ready"
  echo "  outputDir=$OUTPUT_DIR"
  echo "  snapshotId=$PUBLISHED_SNAPSHOT_ID"
  echo "  sequence=$PUBLISHED_SEQUENCE"
  exit 0
fi

REMOTE_TMP="resolver-projection-${PUBLISHED_SEQUENCE}-$$.json"
echo "copying signed projection to $SSH_TARGET..."
scp "${SCP_ARGS[@]}" "$SIGNED_PATH" "${SSH_TARGET}:${REMOTE_TMP}"

echo "installing signed projection on $SSH_TARGET..."
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "sudo install -d -m 0755 '$(dirname "$REMOTE_PROJECTION_PATH")' && sudo install -m 0640 '$REMOTE_TMP' '$REMOTE_PROJECTION_PATH' && rm -f '$REMOTE_TMP'"

if (( SWITCH_NODE_TO_FILE_URL == 1 )); then
  REMOTE_FILE_URL="file://${REMOTE_PROJECTION_PATH}"
  echo "switching remote env to file:// verify-only mode..."
  ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "sudo python3 - '$REMOTE_ENV_FILE' '$REMOTE_FILE_URL' <<'PY'
from pathlib import Path
import sys
env_path = Path(sys.argv[1])
projection_url = sys.argv[2]
lines = env_path.read_text().splitlines()
out = []
seen_url = False
seen_signed = False
seen_autobuild = False
for line in lines:
    if line.startswith('DARKMESH_PROJECTION_URL='):
        out.append(f'DARKMESH_PROJECTION_URL={projection_url}')
        seen_url = True
        continue
    if line.startswith('DARKMESH_PROJECTION_REQUIRE_SIGNED='):
        out.append('DARKMESH_PROJECTION_REQUIRE_SIGNED=1')
        seen_signed = True
        continue
    if line.startswith('DARKMESH_DM1_AUTOBUILD='):
        out.append('DARKMESH_DM1_AUTOBUILD=0')
        seen_autobuild = True
        continue
    if line.startswith('DARKMESH_DM1_SIGN_WITH_PRIVATE_KEY='):
        continue
    out.append(line)
if not seen_url:
    out.append(f'DARKMESH_PROJECTION_URL={projection_url}')
if not seen_signed:
    out.append('DARKMESH_PROJECTION_REQUIRE_SIGNED=1')
if not seen_autobuild:
    out.append('DARKMESH_DM1_AUTOBUILD=0')
backup = env_path.with_name(env_path.name + '.bak')
backup.write_text(env_path.read_text())
env_path.write_text('\\n'.join(out) + '\\n')
PY"
fi

echo "triggering remote sync..."
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "sudo systemctl start darkmesh-host-routing-sync.service"

if [[ -n "$VERIFY_NODE_STATE_URL" ]]; then
  echo "waiting for joined node activation..."
  wait_for_node_sequence "$VERIFY_NODE_STATE_URL" "$PUBLISHED_SEQUENCE" "$NODE_WAIT_SEC" "$POLL_INTERVAL_SEC"
fi
if (( VERIFY_NODE_STATE_VIA_SSH == 1 )); then
  echo "waiting for joined node activation via ssh..."
  wait_for_remote_node_sequence "$SSH_TARGET" "$PUBLISHED_SEQUENCE" "$NODE_WAIT_SEC" "$POLL_INTERVAL_SEC" "$REMOTE_STATE_FILE"
fi

jq -n \
  --arg mode "remote_installed" \
  --arg outputDir "$OUTPUT_DIR" \
  --arg sshTarget "$SSH_TARGET" \
  --arg remoteProjectionPath "$REMOTE_PROJECTION_PATH" \
  --arg remoteEnvFile "$REMOTE_ENV_FILE" \
  --arg remoteStateFile "$REMOTE_STATE_FILE" \
  --arg snapshotId "$PUBLISHED_SNAPSHOT_ID" \
  --arg keyId "$PUBLISHED_KEY_ID" \
  --arg payloadHash "$PUBLISHED_PAYLOAD_HASH" \
  --arg verifyNodeStateUrl "$VERIFY_NODE_STATE_URL" \
  --argjson verifyNodeStateViaSsh "$( [[ "$VERIFY_NODE_STATE_VIA_SSH" == "1" ]] && echo true || echo false )" \
  --argjson executeLive true \
  --argjson switchNodeToFileUrl "$( [[ "$SWITCH_NODE_TO_FILE_URL" == "1" ]] && echo true || echo false )" \
  --argjson sequence "$PUBLISHED_SEQUENCE" \
  '{
    mode:$mode,
    executeLive:$executeLive,
    switchNodeToFileUrl:$switchNodeToFileUrl,
    verifyNodeStateViaSsh:$verifyNodeStateViaSsh,
    outputDir:$outputDir,
    sshTarget:$sshTarget,
    remoteProjectionPath:$remoteProjectionPath,
    remoteEnvFile:$remoteEnvFile,
    remoteStateFile:$remoteStateFile,
    verifyNodeStateUrl:(if $verifyNodeStateUrl == "" then null else $verifyNodeStateUrl end),
    published:{snapshotId:$snapshotId,sequence:$sequence,keyId:$keyId,payloadHash:$payloadHash}
  }' >"$METADATA_PATH"

echo "private file release complete"
echo "  outputDir=$OUTPUT_DIR"
echo "  snapshotId=$PUBLISHED_SNAPSHOT_ID"
echo "  sequence=$PUBLISHED_SEQUENCE"
