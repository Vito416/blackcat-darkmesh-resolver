#!/usr/bin/env bash
set -euo pipefail

PROJECTION_URL="${DARKMESH_PROJECTION_URL:-}"
LEGACY_SNIPPET_PATH="${DARKMESH_HOST_ROUTING_SNIPPET_PATH:-}"
MAP_PATH="${DARKMESH_HOST_ROUTING_MAP_PATH:-${LEGACY_SNIPPET_PATH:-/etc/nginx/conf.d/darkmesh-host-routing-map.conf}}"
STATE_DIR="${DARKMESH_HOST_ROUTING_STATE_DIR:-/var/lib/darkmesh/host-routing}"
STATE_FILE="${STATE_DIR}/state.json"
RESPONSE_CACHE_FILE="${STATE_DIR}/last-response.json"
ENVELOPE_CACHE_FILE="${STATE_DIR}/last-envelope.json"
FETCH_TIMEOUT_SEC="${DARKMESH_PROJECTION_FETCH_TIMEOUT_SEC:-10}"
LKG_MAX_AGE_SEC="${DARKMESH_HOST_ROUTING_LKG_MAX_AGE_SEC:-900}"
SIGNER_ALLOWLIST="${DARKMESH_PROJECTION_SIGNER_ALLOWLIST:-}"
TRUST_MANIFEST_PATH="${DARKMESH_PROJECTION_TRUST_MANIFEST:-}"
REQUIRE_SIGNED="${DARKMESH_PROJECTION_REQUIRE_SIGNED:-0}"
VERIFY_BIN="${DARKMESH_PROJECTION_VERIFY_BIN:-/usr/local/sbin/projection-envelope-tool.py}"
REQUIRE_DM1_PARITY="${DARKMESH_PROJECTION_REQUIRE_DM1_PARITY:-0}"
DM1_PARITY_BIN="${DARKMESH_PROJECTION_DM1_PARITY_BIN:-/usr/local/sbin/verify-projection-dm1-parity.sh}"
DM1_PARITY_DNS_URL="${DARKMESH_PROJECTION_DM1_DNS_URL:-https://dns.google/resolve}"
DM1_PARITY_AR_BASE="${DARKMESH_PROJECTION_DM1_AR_BASE:-https://arweave.net}"
RELOAD_ON_CHANGE="${DARKMESH_HOST_ROUTING_RELOAD_ON_CHANGE:-1}"
DRY_RUN="${DARKMESH_HOST_ROUTING_DRY_RUN:-0}"
MAP_HASH_BUCKET_SIZE="${DARKMESH_NGINX_MAP_HASH_BUCKET_SIZE:-128}"
MAP_HASH_MAX_SIZE="${DARKMESH_NGINX_MAP_HASH_MAX_SIZE:-4096}"
DM1_AUTOBUILD="${DARKMESH_DM1_AUTOBUILD:-0}"
DM1_BUILDER_BIN="${DARKMESH_DM1_BUILDER_BIN:-/usr/local/sbin/build-host-routing-envelope-from-dm1.sh}"
DM1_DOMAINS_FILE="${DARKMESH_DM1_DOMAINS_FILE:-}"
DM1_DOMAINS_CSV="${DARKMESH_DM1_DOMAINS_CSV:-}"
DM1_DNS_URL="${DARKMESH_DM1_DNS_URL:-https://dns.google/resolve}"
DM1_AR_BASE="${DARKMESH_DM1_AR_BASE:-https://arweave.net}"
DM1_TTL_SEC="${DARKMESH_DM1_TTL_SEC:-3600}"
DM1_INCLUDE_WWW="${DARKMESH_DM1_INCLUDE_WWW:-0}"
DM1_SIGNED_BY="${DARKMESH_DM1_SIGNED_BY:-bootstrap-local}"
DM1_KEY_ID="${DARKMESH_DM1_KEY_ID:-bootstrap-local-key}"
DM1_SIGNATURE_ALG="${DARKMESH_DM1_SIGNATURE_ALG:-bootstrap-none}"
DM1_SIGNATURE="${DARKMESH_DM1_SIGNATURE:-bootstrap}"
DM1_ENVELOPE_VERSION="${DARKMESH_DM1_ENVELOPE_VERSION:-v1}"
DM1_SNAPSHOT_ID="${DARKMESH_DM1_SNAPSHOT_ID:-}"
DM1_SEQUENCE="${DARKMESH_DM1_SEQUENCE:-0}"
DM1_REFRESH_CADENCE_SEC="${DARKMESH_DM1_REFRESH_CADENCE_SEC:-60}"
DM1_LKG_MAX_AGE_SEC="${DARKMESH_DM1_LKG_MAX_AGE_SEC:-900}"
DM1_ISSUED_BY_NODE="${DARKMESH_DM1_ISSUED_BY_NODE:-}"
DM1_ISSUED_BY_RESOLVER="${DARKMESH_DM1_ISSUED_BY_RESOLVER:-}"
DM1_SOURCE_DESCRIPTION="${DARKMESH_DM1_SOURCE_DESCRIPTION:-}"
DM1_PROJECTION_TOOL_BIN="${DARKMESH_DM1_PROJECTION_TOOL_BIN:-$VERIFY_BIN}"
DM1_SIGN_WITH_PRIVATE_KEY="${DARKMESH_DM1_SIGN_WITH_PRIVATE_KEY:-}"

RENDER_FAILURE_REASON=""
RENDER_ENVELOPE_VERSION=""
RENDER_SIGNER=""
RENDER_GENERATED_AT=""
RENDER_EXPIRES_AT=""
RENDER_SNAPSHOT_HASH=""
RENDER_KEY_ID=""
RENDER_SEQUENCE=""
RENDER_PAYLOAD_HASH=""
RENDER_VERIFIED_AT=""
RENDER_VERIFICATION_REASON=""

log() {
  printf '[darkmesh-host-routing] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
}

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

is_positive_int() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 ))
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

read_state_field() {
  local field="$1"
  if [[ -s "$STATE_FILE" ]]; then
    jq -r "$field // empty" "$STATE_FILE" 2>/dev/null || true
  fi
}

is_signer_allowed() {
  local signer="$1"
  if [[ -z "$SIGNER_ALLOWLIST" ]]; then
    return 0
  fi

  local item=""
  IFS=',' read -r -a _items <<<"$SIGNER_ALLOWLIST"
  for item in "${_items[@]}"; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    if [[ "$signer" == "$item" ]]; then
      return 0
    fi
  done

  return 1
}

write_state() {
  local mode="$1"
  local reason="$2"
  local now_epoch="$3"
  local signer="${4:-}"
  local generated_at="${5:-}"
  local expires_at="${6:-}"
  local snapshot_hash="${7:-}"
  local envelope_version="${8:-}"
  local key_id="${9:-}"
  local sequence="${10:-}"
  local payload_hash="${11:-}"
  local verified_at="${12:-}"
  local verification_reason="${13:-}"

  local last_success_epoch=""
  last_success_epoch="$(read_state_field '.lastSuccessEpoch')"
  if [[ "$mode" == "active" ]]; then
    last_success_epoch="$now_epoch"
  fi
  if [[ -z "$last_success_epoch" ]]; then
    last_success_epoch=0
  fi

  local tmp
  tmp="$(mktemp)"
  jq -n \
    --arg mode "$mode" \
    --arg reason "$reason" \
    --arg now_iso "$(iso_now)" \
    --arg signer "$signer" \
    --arg generated_at "$generated_at" \
    --arg expires_at "$expires_at" \
    --arg snapshot_hash "$snapshot_hash" \
    --arg envelope_version "$envelope_version" \
    --arg key_id "$key_id" \
    --arg sequence "$sequence" \
    --arg payload_hash "$payload_hash" \
    --arg verified_at "$verified_at" \
    --arg verification_reason "$verification_reason" \
    --argjson now_epoch "$now_epoch" \
    --argjson last_success_epoch "$last_success_epoch" \
    '{
      mode: $mode,
      reason: $reason,
      updatedAt: $now_iso,
      updatedEpoch: $now_epoch,
      lastSuccessEpoch: $last_success_epoch
    }
    + (if $signer != "" then {lastSigner: $signer} else {} end)
    + (if $generated_at != "" then {lastGeneratedAt: $generated_at} else {} end)
    + (if $expires_at != "" then {lastExpiresAt: $expires_at} else {} end)
    + (if $snapshot_hash != "" then {lastSnapshotHash: $snapshot_hash} else {} end)
    + (if $envelope_version != "" then {lastEnvelopeVersion: $envelope_version} else {} end)
    + (if $key_id != "" then {lastKeyId: $key_id} else {} end)
    + (if $sequence != "" then {lastSequence: ($sequence|tonumber)} else {} end)
    + (if $payload_hash != "" then {lastPayloadHash: $payload_hash} else {} end)
    + (if $verified_at != "" then {lastVerifiedAt: $verified_at} else {} end)
    + (if $verification_reason != "" then {lastVerificationReason: $verification_reason} else {} end)' \
    >"$tmp"

  install -d -m 0755 "$STATE_DIR"
  install -m 0644 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

reset_render_metadata() {
  RENDER_FAILURE_REASON=""
  RENDER_ENVELOPE_VERSION=""
  RENDER_SIGNER=""
  RENDER_GENERATED_AT=""
  RENDER_EXPIRES_AT=""
  RENDER_SNAPSHOT_HASH=""
  RENDER_KEY_ID=""
  RENDER_SEQUENCE=""
  RENDER_PAYLOAD_HASH=""
  RENDER_VERIFIED_AT=""
  RENDER_VERIFICATION_REASON=""
}

projection_version() {
  local envelope_json="$1"
  jq -r '.version // empty' "$envelope_json"
}

verify_v2_envelope() {
  local envelope_json="$1"
  local verify_tmp=""
  verify_tmp="$(mktemp)"

  if [[ -z "$TRUST_MANIFEST_PATH" ]]; then
    RENDER_FAILURE_REASON="trust_manifest_missing"
    rm -f "$verify_tmp"
    return 1
  fi
  if [[ ! -f "$TRUST_MANIFEST_PATH" ]]; then
    RENDER_FAILURE_REASON="trust_manifest_not_found"
    rm -f "$verify_tmp"
    return 1
  fi
  if [[ ! -x "$VERIFY_BIN" ]]; then
    RENDER_FAILURE_REASON="verify_bin_not_executable"
    rm -f "$verify_tmp"
    return 1
  fi

  if "$VERIFY_BIN" verify "$envelope_json" "$TRUST_MANIFEST_PATH" >"$verify_tmp" 2>/dev/null; then
    :
  else
    if jq -e type "$verify_tmp" >/dev/null 2>&1; then
      RENDER_FAILURE_REASON="$(jq -r '.reason // "signature_verification_failed"' "$verify_tmp")"
      RENDER_KEY_ID="$(jq -r '.keyId // empty' "$verify_tmp")"
      RENDER_SEQUENCE="$(jq -r '.sequence // empty' "$verify_tmp")"
      RENDER_PAYLOAD_HASH="$(jq -r '.payloadHash // empty' "$verify_tmp")"
      RENDER_VERIFICATION_REASON="$RENDER_FAILURE_REASON"
    else
      RENDER_FAILURE_REASON="signature_verification_failed"
      RENDER_VERIFICATION_REASON="$RENDER_FAILURE_REASON"
    fi
    rm -f "$verify_tmp"
    return 1
  fi

  if ! jq -e '.ok == true' "$verify_tmp" >/dev/null 2>&1; then
    RENDER_FAILURE_REASON="$(jq -r '.reason // "signature_verification_failed"' "$verify_tmp" 2>/dev/null || printf 'signature_verification_failed')"
    RENDER_KEY_ID="$(jq -r '.keyId // empty' "$verify_tmp" 2>/dev/null || true)"
    RENDER_SEQUENCE="$(jq -r '.sequence // empty' "$verify_tmp" 2>/dev/null || true)"
    RENDER_PAYLOAD_HASH="$(jq -r '.payloadHash // empty' "$verify_tmp" 2>/dev/null || true)"
    RENDER_VERIFICATION_REASON="$RENDER_FAILURE_REASON"
    rm -f "$verify_tmp"
    return 1
  fi

  RENDER_FAILURE_REASON=""
  RENDER_KEY_ID="$(jq -r '.keyId // empty' "$verify_tmp")"
  RENDER_SEQUENCE="$(jq -r '.sequence // empty' "$verify_tmp")"
  RENDER_PAYLOAD_HASH="$(jq -r '.payloadHash // empty' "$verify_tmp")"
  RENDER_VERIFICATION_REASON="$(jq -r '.reason // "ok"' "$verify_tmp")"
  RENDER_VERIFIED_AT="$(iso_now)"
  rm -f "$verify_tmp"
  return 0
}

verify_dm1_parity() {
  local envelope_json="$1"
  local parity_tmp=""
  parity_tmp="$(mktemp)"

  if [[ ! -x "$DM1_PARITY_BIN" ]]; then
    RENDER_FAILURE_REASON="dm1_parity_bin_not_executable"
    rm -f "$parity_tmp"
    return 1
  fi

  if "$DM1_PARITY_BIN" \
    --envelope "$envelope_json" \
    --builder-bin "$DM1_BUILDER_BIN" \
    --projection-tool-bin "$VERIFY_BIN" \
    --dns-url "$DM1_PARITY_DNS_URL" \
    --ar-base "$DM1_PARITY_AR_BASE" \
    --output "$parity_tmp" >/dev/null 2>&1; then
    RENDER_VERIFICATION_REASON="ok_signature_and_dm1_parity"
    rm -f "$parity_tmp"
    return 0
  fi

  if jq -e type "$parity_tmp" >/dev/null 2>&1; then
    RENDER_FAILURE_REASON="$(jq -r '.reason // "dm1_parity_failed"' "$parity_tmp")"
  else
    RENDER_FAILURE_REASON="dm1_parity_failed"
  fi
  rm -f "$parity_tmp"
  return 1
}

write_fail_closed_map() {
  local out="$1"
  local reason="$2"
  cat >"$out" <<EOF
# Managed by sync-nginx-host-routing.sh. Do not edit manually.
# mode=fail_closed
# reason=${reason}
# generated_at=$(iso_now)
map_hash_bucket_size ${MAP_HASH_BUCKET_SIZE};
map_hash_max_size ${MAP_HASH_MAX_SIZE};
map \$host \$dm_host_target_prefix {
    default "";
}
EOF
}

apply_map_file() {
  local candidate="$1"
  local mode="$2"
  local reason="$3"
  local changed=0
  local before_hash=""
  local after_hash=""

  if [[ -f "$MAP_PATH" ]]; then
    before_hash="$(sha256sum "$MAP_PATH" | awk '{print $1}')"
  fi
  after_hash="$(sha256sum "$candidate" | awk '{print $1}')"

  if [[ "$before_hash" != "$after_hash" ]]; then
    changed=1
  fi

  if [[ "$changed" -eq 0 ]]; then
    log "routing map unchanged (${mode})"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: routing map change detected (${mode}), skipping install/reload"
    return 0
  fi

  install -d -m 0755 "$(dirname "$MAP_PATH")"
  local backup=""
  if [[ -f "$MAP_PATH" ]]; then
    backup="$(mktemp)"
    cp -f "$MAP_PATH" "$backup"
  fi

  install -m 0644 "$candidate" "$MAP_PATH"

  if ! nginx -t >/dev/null 2>&1; then
    if [[ -n "$backup" && -f "$backup" ]]; then
      install -m 0644 "$backup" "$MAP_PATH"
    fi
    rm -f "$backup"
    fail "nginx -t failed after routing map update (${mode}:${reason})"
  fi

  if [[ "$RELOAD_ON_CHANGE" == "1" ]]; then
    systemctl reload nginx
    log "nginx reloaded (${mode})"
  else
    log "routing map installed (${mode}), reload disabled"
  fi

  rm -f "$backup"
}

extract_envelope_json() {
  local input="$1"
  local output="$2"

  # Direct envelope.
  if jq -e '
    type == "object"
    and (.version | type == "string")
    and (.payload | type == "object")
  ' "$input" >/dev/null 2>&1; then
    cp "$input" "$output"
    return 0
  fi

  # AO response where body is object.
  if jq -e '
    type == "object"
    and (.body | type == "object")
    and (.body.version | type == "string")
    and (.body.payload | type == "object")
  ' "$input" >/dev/null 2>&1; then
    jq '.body' "$input" >"$output"
    return 0
  fi

  # AO response where body is JSON string.
  if jq -e '
    type == "object"
    and (.body | type == "string")
  ' "$input" >/dev/null 2>&1; then
    local body_tmp
    body_tmp="$(mktemp)"
    jq -r '.body' "$input" >"$body_tmp"
    if jq -e '
      type == "object"
      and (.version | type == "string")
      and (.payload | type == "object")
    ' "$body_tmp" >/dev/null 2>&1; then
      mv "$body_tmp" "$output"
      return 0
    fi
    rm -f "$body_tmp"
  fi

  return 1
}

sanitize_host() {
  local host="$1"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  host="$(trim "$host")"
  # No wildcard, no slash, no spaces.
  if [[ ! "$host" =~ ^[a-z0-9][a-z0-9.-]{0,252}$ ]]; then
    return 1
  fi
  if [[ "$host" == *..* ]]; then
    return 1
  fi
  if [[ "$host" == -* || "$host" == *- ]]; then
    return 1
  fi
  printf '%s' "$host"
}

sanitize_path_prefix() {
  local path_prefix="$1"
  if [[ -z "$path_prefix" ]]; then
    path_prefix="/"
  fi
  if ! printf '%s' "$path_prefix" | grep -Eq '^/[A-Za-z0-9._~!$()*+,;=:@%/-]*$'; then
    return 1
  fi
  printf '%s' "$path_prefix"
}

render_candidate_map() {
  local envelope_json="$1"
  local out="$2"

  reset_render_metadata

  validation_error() {
    log "ERROR: $1"
    RENDER_FAILURE_REASON="${2:-projection_validation_failed}"
    return 1
  }

  local version
  version="$(projection_version "$envelope_json")"
  RENDER_ENVELOPE_VERSION="$version"

  local signer
  signer="$(jq -r '.signedBy // empty' "$envelope_json")"
  local signature
  signature="$(jq -r '.signature // empty' "$envelope_json")"
  local signature_alg
  signature_alg="$(jq -r '.signatureAlg // empty' "$envelope_json")"
  local generated_at
  generated_at="$(jq -r '.generatedAt // empty' "$envelope_json")"
  local expires_at
  expires_at="$(jq -r '.expiresAt // empty' "$envelope_json")"
  local payload_version
  payload_version="$(jq -r '.payload.version // empty' "$envelope_json")"
  local key_id=""
  key_id="$(jq -r '.keyId // empty' "$envelope_json")"
  local sequence=""
  sequence="$(jq -r '.sequence // empty' "$envelope_json")"
  local payload_hash=""
  payload_hash="$(jq -r '.payloadHash // empty' "$envelope_json")"

  is_positive_int "$MAP_HASH_BUCKET_SIZE" || {
    validation_error "invalid DARKMESH_NGINX_MAP_HASH_BUCKET_SIZE: ${MAP_HASH_BUCKET_SIZE}" "invalid_map_hash_bucket_size"
    return 1
  }
  is_positive_int "$MAP_HASH_MAX_SIZE" || {
    validation_error "invalid DARKMESH_NGINX_MAP_HASH_MAX_SIZE: ${MAP_HASH_MAX_SIZE}" "invalid_map_hash_max_size"
    return 1
  }

  [[ -n "$signer" ]] || { validation_error "projection signer missing" "signer_missing"; return 1; }
  [[ -n "$signature" ]] || { validation_error "projection signature missing" "signature_missing"; return 1; }
  [[ -n "$signature_alg" ]] || { validation_error "projection signatureAlg missing" "signature_alg_missing"; return 1; }
  [[ -n "$generated_at" ]] || { validation_error "projection generatedAt missing" "generated_at_missing"; return 1; }
  [[ -n "$expires_at" ]] || { validation_error "projection expiresAt missing" "expires_at_missing"; return 1; }

  case "$version" in
    dm-hostmap-envelope.v1)
      if [[ "$REQUIRE_SIGNED" == "1" ]]; then
        validation_error "signed projection required, legacy v1 envelope rejected" "signed_required_legacy_v1_rejected"
        return 1
      fi
      if [[ "$payload_version" != "dm-hostmap.v1" ]]; then
        validation_error "unexpected payload version: ${payload_version:-<empty>} (expected dm-hostmap.v1)" "unexpected_payload_version"
        return 1
      fi
      if ! is_signer_allowed "$signer"; then
        validation_error "projection signer is not in allowlist: $signer" "signer_not_allowed"
        return 1
      fi
      ;;
    dm-hostmap-envelope.v2)
      [[ -n "$key_id" ]] || { validation_error "projection keyId missing" "key_id_missing"; return 1; }
      [[ -n "$sequence" ]] || { validation_error "projection sequence missing" "sequence_missing"; return 1; }
      [[ -n "$payload_hash" ]] || { validation_error "projection payloadHash missing" "payload_hash_missing"; return 1; }
      if [[ "$payload_version" != "dm-hostmap.v2" ]]; then
        validation_error "unexpected payload version: ${payload_version:-<empty>} (expected dm-hostmap.v2)" "unexpected_payload_version"
        return 1
      fi
      if ! verify_v2_envelope "$envelope_json"; then
        log "ERROR: v2 projection verification failed: ${RENDER_FAILURE_REASON}"
        return 1
      fi
      ;;
    *)
      validation_error "unexpected envelope version: ${version:-<empty>} (expected dm-hostmap-envelope.v1|dm-hostmap-envelope.v2)" "unexpected_envelope_version"
      return 1
      ;;
  esac

  local generated_epoch
  local expires_epoch
  local now_epoch
  generated_epoch="$(date -u -d "$generated_at" +%s 2>/dev/null || true)"
  expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  [[ -n "$generated_epoch" ]] || { validation_error "generatedAt is not RFC3339: $generated_at" "generated_at_invalid"; return 1; }
  [[ -n "$expires_epoch" ]] || { validation_error "expiresAt is not RFC3339: $expires_at" "expires_at_invalid"; return 1; }
  if (( expires_epoch <= generated_epoch )); then
    validation_error "expiresAt must be after generatedAt" "expires_before_generated"
    return 1
  fi
  if (( now_epoch > expires_epoch )); then
    validation_error "projection expired at $expires_at" "expired"
    return 1
  fi

  if [[ "$version" == "dm-hostmap-envelope.v2" && "$REQUIRE_DM1_PARITY" == "1" ]]; then
    if ! verify_dm1_parity "$envelope_json"; then
      log "ERROR: v2 projection DM1 parity failed: ${RENDER_FAILURE_REASON}"
      return 1
    fi
  fi

  local rows_tmp
  rows_tmp="$(mktemp)"
  jq -r '
    .payload.entries // []
    | .[]
    | select((.enabled // true) == true)
    | (
        (.targetType // .type // "")
        | ascii_downcase
      ) as $explicit_type
    | (.targetPid // .pid // "") as $pid
    | (.targetTx // .tx // "") as $tx
    | (
        if $explicit_type == "process" then "process"
        elif $explicit_type == "tx" then "tx"
        elif ($pid | type) == "string" and ($pid | length) > 0 then "process"
        elif ($tx | type) == "string" and ($tx | length) > 0 then "tx"
        else ""
        end
      ) as $target_type
    | (
        if $target_type == "process" then $pid
        elif $target_type == "tx" then $tx
        else ""
        end
      ) as $target
    | (.pathPrefix // "/") as $prefix
    | if (.hosts | type) == "array" then
        .hosts[] | [., $target_type, $target, $prefix] | @tsv
      else
        [(.host // ""), $target_type, $target, $prefix] | @tsv
      end
  ' "$envelope_json" >"$rows_tmp"

  declare -A host_target_map=()
  local host_raw=""
  local target_type=""
  local target_id=""
  local prefix=""

  while IFS=$'\t' read -r host_raw target_type target_id prefix; do
    [[ -z "$host_raw" ]] && continue
    local host
    host="$(sanitize_host "$host_raw")" || {
      validation_error "invalid host in projection: $host_raw" "invalid_host"
      return 1
    }
    if [[ "$target_type" != "process" && "$target_type" != "tx" ]]; then
      validation_error "invalid targetType for host ${host}: ${target_type:-<empty>} (allowed: process|tx)" "invalid_target_type"
      return 1
    fi
    [[ "$target_id" =~ ^[A-Za-z0-9_-]{43}$ ]] || {
      if [[ "$target_type" == "process" ]]; then
        validation_error "invalid targetPid for host ${host}: ${target_id}" "invalid_target_pid"
      else
        validation_error "invalid targetTx for host ${host}: ${target_id}" "invalid_target_tx"
      fi
      return 1
    }
    prefix="$(sanitize_path_prefix "$prefix")" || {
      validation_error "invalid pathPrefix for host ${host}: ${prefix}" "invalid_path_prefix"
      return 1
    }

    local target
    if [[ "$target_type" == "process" ]]; then
      target="/${target_id}~process@1.0"
    else
      target="/${target_id}"
    fi
    if [[ "$prefix" != "/" ]]; then
      target="${target}${prefix}"
    fi
    host_target_map["$host"]="$target"
  done <"$rows_tmp"
  rm -f "$rows_tmp"

  local hosts_sorted=()
  if [[ ${#host_target_map[@]} -gt 0 ]]; then
    mapfile -t hosts_sorted < <(printf '%s\n' "${!host_target_map[@]}" | sort)
  fi

  {
    printf '# Managed by sync-nginx-host-routing.sh. Do not edit manually.\n'
    printf '# mode=active\n'
    printf '# signer=%s\n' "$signer"
    printf '# signature_alg=%s\n' "$signature_alg"
    printf '# generated_at=%s\n' "$generated_at"
    printf '# expires_at=%s\n' "$expires_at"
    if [[ -n "$key_id" ]]; then
      printf '# key_id=%s\n' "$key_id"
    fi
    if [[ -n "$sequence" ]]; then
      printf '# sequence=%s\n' "$sequence"
    fi
    if [[ -n "$payload_hash" ]]; then
      printf '# payload_hash=%s\n' "$payload_hash"
    fi
    printf 'map_hash_bucket_size %s;\n' "$MAP_HASH_BUCKET_SIZE"
    printf 'map_hash_max_size %s;\n' "$MAP_HASH_MAX_SIZE"
    printf 'map $host $dm_host_target_prefix {\n'
    printf '    default "";\n'
    local h=""
    for h in "${hosts_sorted[@]}"; do
      printf '    %s "%s";\n' "$h" "${host_target_map[$h]}"
    done
    printf '}\n'
  } >"$out"

  RENDER_SIGNER="$signer"
  RENDER_GENERATED_AT="$generated_at"
  RENDER_EXPIRES_AT="$expires_at"
  RENDER_SNAPSHOT_HASH="$(sha256sum "$envelope_json" | awk '{print $1}')"
  if [[ -z "$RENDER_KEY_ID" ]]; then
    RENDER_KEY_ID="$key_id"
  fi
  if [[ -z "$RENDER_SEQUENCE" ]]; then
    RENDER_SEQUENCE="$sequence"
  fi
  if [[ -z "$RENDER_PAYLOAD_HASH" ]]; then
    RENDER_PAYLOAD_HASH="$payload_hash"
  fi
  if [[ -z "$RENDER_VERIFICATION_REASON" ]]; then
    if [[ "$version" == "dm-hostmap-envelope.v2" ]]; then
      RENDER_VERIFICATION_REASON="ok"
    else
      RENDER_VERIFICATION_REASON="legacy_v1_bootstrap"
    fi
  fi
}

handle_projection_failure() {
  local reason="$1"
  local now_epoch
  now_epoch="$(date -u +%s)"

  local last_success_epoch
  last_success_epoch="$(read_state_field '.lastSuccessEpoch')"
  if [[ -z "$last_success_epoch" ]]; then
    last_success_epoch=0
  fi

  local age=$(( now_epoch - last_success_epoch ))
  if (( last_success_epoch > 0 && age <= LKG_MAX_AGE_SEC )) && [[ -f "$MAP_PATH" ]]; then
    log "projection failed (${reason}); keeping last-known-good (age=${age}s <= ${LKG_MAX_AGE_SEC}s)"
    write_state "lkg" "$reason" "$now_epoch"
    return 0
  fi

  local fail_closed
  fail_closed="$(mktemp)"
  write_fail_closed_map "$fail_closed" "$reason"
  apply_map_file "$fail_closed" "fail_closed" "$reason"
  rm -f "$fail_closed"
  write_state "fail_closed" "$reason" "$now_epoch"
  log "projection failed (${reason}); stale window exceeded -> fail-closed routing active"
}

autobuild_projection_file_if_enabled() {
  local local_path="$1"

  if [[ "$DM1_AUTOBUILD" != "1" ]]; then
    return 0
  fi
  if [[ ! "$PROJECTION_URL" =~ ^file:// ]]; then
    log "dm1 autobuild enabled but projection URL is not file://, skipping"
    return 0
  fi
  if [[ ! -x "$DM1_BUILDER_BIN" ]]; then
    log "dm1 autobuild enabled but builder is not executable: $DM1_BUILDER_BIN"
    return 1
  fi

  local args=(
    --output "$local_path"
    --dns-url "$DM1_DNS_URL"
    --ar-base "$DM1_AR_BASE"
    --ttl-sec "$DM1_TTL_SEC"
    --signed-by "$DM1_SIGNED_BY"
    --key-id "$DM1_KEY_ID"
    --signature-alg "$DM1_SIGNATURE_ALG"
    --signature "$DM1_SIGNATURE"
    --envelope-version "$DM1_ENVELOPE_VERSION"
    --sequence "$DM1_SEQUENCE"
    --refresh-cadence-sec "$DM1_REFRESH_CADENCE_SEC"
    --lkg-max-age-sec "$DM1_LKG_MAX_AGE_SEC"
    --projection-tool-bin "$DM1_PROJECTION_TOOL_BIN"
  )

  if [[ -n "$DM1_SNAPSHOT_ID" ]]; then
    args+=(--snapshot-id "$DM1_SNAPSHOT_ID")
  fi
  if [[ -n "$DM1_ISSUED_BY_NODE" ]]; then
    args+=(--issued-by-node "$DM1_ISSUED_BY_NODE")
  fi
  if [[ -n "$DM1_ISSUED_BY_RESOLVER" ]]; then
    args+=(--issued-by-resolver "$DM1_ISSUED_BY_RESOLVER")
  fi
  if [[ -n "$DM1_SOURCE_DESCRIPTION" ]]; then
    args+=(--source-description "$DM1_SOURCE_DESCRIPTION")
  fi
  if [[ -n "$DM1_SIGN_WITH_PRIVATE_KEY" ]]; then
    args+=(--sign-with "$DM1_SIGN_WITH_PRIVATE_KEY")
  fi

  if [[ -n "$DM1_DOMAINS_FILE" ]]; then
    args+=(--domains-file "$DM1_DOMAINS_FILE")
  elif [[ -n "$DM1_DOMAINS_CSV" ]]; then
    args+=(--domains "$DM1_DOMAINS_CSV")
  else
    log "dm1 autobuild enabled but DARKMESH_DM1_DOMAINS_FILE/CSV is not set"
    return 1
  fi

  if [[ "$DM1_INCLUDE_WWW" == "1" ]]; then
    args+=(--include-www)
  fi

  if "$DM1_BUILDER_BIN" "${args[@]}" >/dev/null 2>&1; then
    log "dm1 autobuild refreshed projection file: ${local_path}"
    return 0
  fi

  log "dm1 autobuild failed, keeping existing projection file if present"
  return 1
}

main() {
  require_cmd curl
  require_cmd jq
  require_cmd sha256sum
  if [[ -n "$VERIFY_BIN" && -x "$VERIFY_BIN" ]]; then
    require_cmd "$VERIFY_BIN"
  fi
  if [[ "$REQUIRE_DM1_PARITY" == "1" ]]; then
    [[ -x "$DM1_PARITY_BIN" ]] || fail "DM1 parity verifier not executable: $DM1_PARITY_BIN"
    [[ -x "$DM1_BUILDER_BIN" ]] || fail "DM1 builder not executable for parity: $DM1_BUILDER_BIN"
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    require_cmd nginx
    require_cmd systemctl
  fi

  [[ -n "$PROJECTION_URL" ]] || fail "DARKMESH_PROJECTION_URL is required"

  install -d -m 0755 "$STATE_DIR"
  install -d -m 0755 "$(dirname "$MAP_PATH")"

  if [[ -n "$LEGACY_SNIPPET_PATH" && -z "${DARKMESH_HOST_ROUTING_MAP_PATH:-}" ]]; then
    log "using deprecated DARKMESH_HOST_ROUTING_SNIPPET_PATH; prefer DARKMESH_HOST_ROUTING_MAP_PATH"
  fi

  local lock_file="${STATE_DIR}/sync.lock"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    log "another sync run is active, skipping"
    exit 0
  fi

  local response_tmp
  response_tmp="$(mktemp)"
  local envelope_tmp
  envelope_tmp="$(mktemp)"
  local map_tmp
  map_tmp="$(mktemp)"

  local http_code=""
  if [[ "$PROJECTION_URL" =~ ^file:// ]]; then
    local local_path="${PROJECTION_URL#file://}"
    autobuild_projection_file_if_enabled "$local_path" || true
    if [[ -s "$local_path" ]]; then
      cp -f "$local_path" "$response_tmp"
      http_code="200"
    else
      http_code="404"
    fi
  else
    http_code="$(curl -sS \
      --max-time "$FETCH_TIMEOUT_SEC" \
      --connect-timeout 3 \
      -H 'Accept: application/json' \
      -w '%{http_code}' \
      -o "$response_tmp" \
      "$PROJECTION_URL" || true)"
  fi

  if [[ "$http_code" != "200" ]]; then
    handle_projection_failure "http_${http_code:-curl_error}"
    rm -f "$response_tmp" "$envelope_tmp" "$map_tmp"
    exit 0
  fi

  if ! jq -e type "$response_tmp" >/dev/null 2>&1; then
    handle_projection_failure "invalid_json"
    rm -f "$response_tmp" "$envelope_tmp" "$map_tmp"
    exit 0
  fi

  cp -f "$response_tmp" "$RESPONSE_CACHE_FILE"

  if ! extract_envelope_json "$response_tmp" "$envelope_tmp"; then
    handle_projection_failure "unsupported_payload_shape"
    rm -f "$response_tmp" "$envelope_tmp" "$map_tmp"
    exit 0
  fi

  if ! render_candidate_map "$envelope_tmp" "$map_tmp"; then
    local err=$?
    handle_projection_failure "${RENDER_FAILURE_REASON:-projection_validation_failed}"
    rm -f "$response_tmp" "$envelope_tmp" "$map_tmp"
    exit "$err"
  fi

  apply_map_file "$map_tmp" "active" "projection_ok"
  local now_epoch
  now_epoch="$(date -u +%s)"
  write_state "active" "projection_ok" "$now_epoch" \
    "$RENDER_SIGNER" \
    "$RENDER_GENERATED_AT" \
    "$RENDER_EXPIRES_AT" \
    "$RENDER_SNAPSHOT_HASH" \
    "$RENDER_ENVELOPE_VERSION" \
    "$RENDER_KEY_ID" \
    "$RENDER_SEQUENCE" \
    "$RENDER_PAYLOAD_HASH" \
    "$RENDER_VERIFIED_AT" \
    "$RENDER_VERIFICATION_REASON"
  cp -f "$envelope_tmp" "$ENVELOPE_CACHE_FILE"
  rm -f "$response_tmp" "$envelope_tmp" "$map_tmp"
  log "sync completed"
}

main "$@"
