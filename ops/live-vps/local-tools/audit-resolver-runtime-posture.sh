#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  audit-resolver-runtime-posture.sh [options]

Read-only audit helper for the current DarkMesh Resolver runtime posture.

What it reports:
  - projection URL / signed / DM1 parity posture from resolver env
  - current sync state from host-routing state.json when available
  - systemd enabled/active states for:
    - darkmesh-resolver-read-adapter.service
    - darkmesh-host-routing-sync.service
    - darkmesh-host-routing-sync.timer
  - derived completion gaps such as:
    - projection adapter still in serving path
    - signed mode not required
    - DM1 parity not required
    - sync timer not enabled

Options:
  --env-file <path>         Resolver env file.
                            Default: /etc/darkmesh/resolver-projection.env
  --state-file <path>       Host-routing state file.
                            Default: /var/lib/darkmesh/host-routing/state.json
  --output <path>           Optional JSON output path.
  --sudo                    Read env/state via sudo for root-owned node files.
  --skip-systemctl          Do not query systemctl states.
  -h, --help                Show help.
USAGE
}

ENV_FILE="/etc/darkmesh/resolver-projection.env"
STATE_FILE="/var/lib/darkmesh/host-routing/state.json"
OUTPUT_PATH=""
USE_SUDO=0
SKIP_SYSTEMCTL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --sudo) USE_SUDO=1; shift ;;
    --skip-systemctl) SKIP_SYSTEMCTL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

require_cmd jq

maybe_sudo() {
  if (( USE_SUDO == 1 )); then
    sudo "$@"
  else
    "$@"
  fi
}

can_read_path() {
  local path="$1"
  if (( USE_SUDO == 1 )); then
    sudo test -r "$path"
  else
    test -r "$path"
  fi
}

read_env_value() {
  local key="$1"
  local default="${2:-}"
  if (( USE_SUDO == 1 )); then
    if ! sudo test -f "$ENV_FILE"; then
      printf '%s' "$default"
      return 0
    fi
  elif [[ ! -f "$ENV_FILE" ]]; then
    printf '%s' "$default"
    return 0
  fi

  maybe_sudo awk -v key="$key" -v def="$default" '
    BEGIN {
      found = 0
      value = def
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, key "=") == 1) {
        raw = substr(line, length(key) + 2)
        sub(/^[[:space:]]+/, "", raw)
        sub(/[[:space:]]+$/, "", raw)
        if ((raw ~ /^".*"$/) || (raw ~ /^'\''.*'\''$/)) {
          raw = substr(raw, 2, length(raw) - 2)
        }
        value = raw
        found = 1
      }
    }
    END {
      print value
    }
  ' "$ENV_FILE"
}

bool_from_env() {
  local value="$1"
  case "${value:-}" in
    1|true|TRUE|yes|YES|on|ON) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

json_string_or_null() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'null'
  else
    jq -Rn --arg v "$value" '$v'
  fi
}

read_state_field_raw() {
  local expr="$1"
  if (( USE_SUDO == 1 )); then
    if ! sudo test -f "$STATE_FILE"; then
      printf ''
      return 0
    fi
  elif [[ ! -f "$STATE_FILE" ]]; then
    printf ''
    return 0
  fi
  maybe_sudo jq -r "$expr // empty" "$STATE_FILE" 2>/dev/null || true
}

systemctl_prop() {
  local unit="$1"
  local prop="$2"
  if (( SKIP_SYSTEMCTL == 1 )); then
    printf 'skipped'
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'unavailable'
    return 0
  fi
  local value
  value="$(systemctl show "$unit" -p "$prop" --value 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    printf 'unknown'
  else
    printf '%s' "$value"
  fi
}

projection_url="$(read_env_value DARKMESH_PROJECTION_URL "")"
require_signed_raw="$(read_env_value DARKMESH_PROJECTION_REQUIRE_SIGNED "0")"
require_dm1_parity_raw="$(read_env_value DARKMESH_PROJECTION_REQUIRE_DM1_PARITY "0")"
trust_manifest_path="$(read_env_value DARKMESH_PROJECTION_TRUST_MANIFEST "")"
state_dir="$(read_env_value DARKMESH_HOST_ROUTING_STATE_DIR "/var/lib/darkmesh/host-routing")"
signer_allowlist="$(read_env_value DARKMESH_PROJECTION_SIGNER_ALLOWLIST "")"
envReadable='false'
stateReadable='false'
can_read_path "$ENV_FILE" && envReadable='true'
can_read_path "$STATE_FILE" && stateReadable='true'

require_signed_json="$(bool_from_env "$require_signed_raw")"
require_dm1_parity_json="$(bool_from_env "$require_dm1_parity_raw")"
signer_allowlist_configured_json='false'
[[ -n "$signer_allowlist" ]] && signer_allowlist_configured_json='true'

state_mode="$(read_state_field_raw '.mode')"
state_reason="$(read_state_field_raw '.reason')"
state_sequence="$(read_state_field_raw '.lastSequence')"
state_verification_reason="$(read_state_field_raw '.lastVerificationReason')"
state_payload_hash="$(read_state_field_raw '.lastPayloadHash')"

adapter_unit="darkmesh-resolver-read-adapter.service"
sync_service_unit="darkmesh-host-routing-sync.service"
sync_timer_unit="darkmesh-host-routing-sync.timer"

adapter_enabled="$(systemctl_prop "$adapter_unit" UnitFileState)"
adapter_active="$(systemctl_prop "$adapter_unit" ActiveState)"
sync_service_enabled="$(systemctl_prop "$sync_service_unit" UnitFileState)"
sync_service_active="$(systemctl_prop "$sync_service_unit" ActiveState)"
sync_timer_enabled="$(systemctl_prop "$sync_timer_unit" UnitFileState)"
sync_timer_active="$(systemctl_prop "$sync_timer_unit" ActiveState)"

read_path_mode="unknown"
if [[ "$adapter_active" == "active" || "$adapter_enabled" == "enabled" ]]; then
  read_path_mode="projection_adapter"
fi

activation_trust_mode="unsigned_or_mixed"
if [[ "$require_signed_json" == "true" && "$require_dm1_parity_json" == "true" ]]; then
  activation_trust_mode="signed_plus_dm1_parity"
elif [[ "$require_signed_json" == "true" ]]; then
  activation_trust_mode="signed_only"
fi

declare -a gaps=()
if [[ "$read_path_mode" == "projection_adapter" ]]; then
  gaps+=("projection_adapter_still_in_serving_path")
fi
if [[ "$require_signed_json" != "true" ]]; then
  gaps+=("signed_projection_not_required")
fi
if [[ "$require_dm1_parity_json" != "true" ]]; then
  gaps+=("dm1_parity_not_required")
fi
if [[ "$sync_timer_enabled" != "enabled" ]]; then
  gaps+=("sync_timer_not_enabled")
fi
if [[ "$sync_timer_active" != "active" && "$sync_timer_active" != "activating" ]]; then
  gaps+=("sync_timer_not_active")
fi

gaps_json='[]'
if (( ${#gaps[@]} > 0 )); then
  gaps_json="$(printf '%s\n' "${gaps[@]}" | jq -R . | jq -s .)"
fi

report="$(jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg envFile "$ENV_FILE" \
  --arg stateFile "$STATE_FILE" \
  --arg projectionUrl "$projection_url" \
  --arg trustManifestPath "$trust_manifest_path" \
  --arg stateDir "$state_dir" \
  --argjson envReadable "$envReadable" \
  --argjson stateReadable "$stateReadable" \
  --arg stateMode "$state_mode" \
  --arg stateReason "$state_reason" \
  --arg stateVerificationReason "$state_verification_reason" \
  --arg statePayloadHash "$state_payload_hash" \
  --arg adapterEnabled "$adapter_enabled" \
  --arg adapterActive "$adapter_active" \
  --arg syncServiceEnabled "$sync_service_enabled" \
  --arg syncServiceActive "$sync_service_active" \
  --arg syncTimerEnabled "$sync_timer_enabled" \
  --arg syncTimerActive "$sync_timer_active" \
  --arg readPathMode "$read_path_mode" \
  --arg activationTrustMode "$activation_trust_mode" \
  --argjson requireSigned "$require_signed_json" \
  --argjson requireDm1Parity "$require_dm1_parity_json" \
  --argjson signerAllowlistConfigured "$signer_allowlist_configured_json" \
  --argjson gaps "$gaps_json" \
  --argjson stateSequence "$(if [[ -n "$state_sequence" ]]; then printf '%s' "$state_sequence"; else printf 'null'; fi)" \
  '{
    generatedAt: $generatedAt,
    envFile: $envFile,
    stateFile: $stateFile,
    projection: {
      url: (if $projectionUrl == "" then null else $projectionUrl end),
      requireSigned: $requireSigned,
      requireDm1Parity: $requireDm1Parity,
      trustManifestPath: (if $trustManifestPath == "" then null else $trustManifestPath end),
      signerAllowlistConfigured: $signerAllowlistConfigured,
      envReadable: $envReadable
    },
    state: {
      readable: $stateReadable,
      mode: (if $stateMode == "" then null else $stateMode end),
      reason: (if $stateReason == "" then null else $stateReason end),
      sequence: $stateSequence,
      verificationReason: (if $stateVerificationReason == "" then null else $stateVerificationReason end),
      payloadHash: (if $statePayloadHash == "" then null else $statePayloadHash end)
    },
    services: {
      readAdapter: {
        unit: "darkmesh-resolver-read-adapter.service",
        enabled: $adapterEnabled,
        active: $adapterActive
      },
      syncService: {
        unit: "darkmesh-host-routing-sync.service",
        enabled: $syncServiceEnabled,
        active: $syncServiceActive
      },
      syncTimer: {
        unit: "darkmesh-host-routing-sync.timer",
        enabled: $syncTimerEnabled,
        active: $syncTimerActive
      }
    },
    posture: {
      readPathMode: $readPathMode,
      activationTrustMode: $activationTrustMode,
      completionGaps: $gaps
    }
  }')"

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  printf '%s\n' "$report" >"$OUTPUT_PATH"
fi

printf '%s\n' "$report"
