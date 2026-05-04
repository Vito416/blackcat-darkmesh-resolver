#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  build-host-routing-envelope-from-dm1.sh [options] [domain...]

Build a dm-hostmap envelope JSON file from live DM1 DNS TXT + AR configs.

Target selection from DM1 cfg:
  - default: siteProcess -> targetType=process
  - tx mode: targetType/targetMode/x-targetType/x-targetMode = "tx"
    and siteTx/x-siteTx -> targetType=tx
  - if mode is omitted and siteProcess is missing but siteTx/x-siteTx exists,
    tx mode is selected automatically.

Options:
  --domains <csv>         Comma-separated domains.
  --domains-file <path>   One domain per line (# comments supported).
  --output <path>         Output envelope path.
                          Default: /etc/darkmesh/resolver-projection.bootstrap.json
  --dns-url <url>         DNS JSON resolver base URL.
                          Default: https://dns.google/resolve
  --ar-base <url>         Arweave gateway base URL.
                          Default: https://arweave.net
  --ttl-sec <n>           Fallback TTL when TXT has no ttl key.
                          Default: 3600
  --expires-in-sec <n>    Override envelope expiresAt horizon from now.
                          If set, this wins over TXT-derived TTL.
  --signed-by <id>        Envelope signedBy field.
                          Default: bootstrap-local
  --key-id <id>           Envelope keyId field for v2.
                          Default: bootstrap-local-key
  --signature-alg <alg>   Envelope signatureAlg field.
                          Default: bootstrap-none
  --signature <value>     Envelope signature field.
                          Default: bootstrap
  --envelope-version <v>  Envelope version to emit.
                          Allowed: v1, v2
                          Default: v1
  --snapshot-id <id>      Snapshot id for v2.
                          Default: projection-<generatedAt>
  --sequence <n>          Sequence number for v2.
                          Default: 0
  --refresh-cadence-sec <n>
                          cacheHints.refreshCadenceSec for v2.
                          Default: 60
  --lkg-max-age-sec <n>   cacheHints.lkgMaxAgeSec for v2.
                          Default: 900
  --issued-by-node <id>   issuedByNode field for v2.
  --issued-by-resolver <id>
                          issuedByResolver + payload.authority.resolverId for v2.
  --source-description <text>
                          payload.source.description for v2.
  --projection-tool-bin <path>
                          projection-envelope-tool.py path for hash/sign work.
  --sign-with <path>      Ed25519 private key file; emits signed v2 envelope.
                          When set, signatureAlg becomes ed25519.
  --include-www           Also add www.<domain> alias entries.
  --strict                Fail if any domain cannot be resolved.
  -h, --help              Show this help.
EOF
}

DOMAINS_CSV=""
DOMAINS_FILE=""
OUTPUT_PATH="/etc/darkmesh/resolver-projection.bootstrap.json"
DNS_URL="https://dns.google/resolve"
AR_BASE="https://arweave.net"
TTL_FALLBACK=3600
EXPIRES_IN_SEC=""
SIGNED_BY="bootstrap-local"
KEY_ID="bootstrap-local-key"
SIGNATURE_ALG="bootstrap-none"
SIGNATURE_VALUE="bootstrap"
ENVELOPE_VERSION="v1"
SNAPSHOT_ID=""
SEQUENCE=0
REFRESH_CADENCE_SEC=60
LKG_MAX_AGE_SEC=900
ISSUED_BY_NODE=""
ISSUED_BY_RESOLVER=""
SOURCE_DESCRIPTION=""
PROJECTION_TOOL_BIN=""
SIGN_WITH_PRIVATE_KEY=""
INCLUDE_WWW=0
STRICT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PROJECTION_TOOL_DIR=""
if REPO_PROJECTION_TOOL_DIR="$(cd "$SCRIPT_DIR/../../../../scripts" 2>/dev/null && pwd)"; then
  :
else
  REPO_PROJECTION_TOOL_DIR=""
fi
REPO_PROJECTION_TOOL_BIN=""
if [[ -n "$REPO_PROJECTION_TOOL_DIR" ]]; then
  REPO_PROJECTION_TOOL_BIN="${REPO_PROJECTION_TOOL_DIR}/projection-envelope-tool.py"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domains)
      DOMAINS_CSV="${2:-}"
      shift 2
      ;;
    --domains-file)
      DOMAINS_FILE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --dns-url)
      DNS_URL="${2:-}"
      shift 2
      ;;
    --ar-base)
      AR_BASE="${2:-}"
      shift 2
      ;;
    --ttl-sec)
      TTL_FALLBACK="${2:-}"
      shift 2
      ;;
    --expires-in-sec)
      EXPIRES_IN_SEC="${2:-}"
      shift 2
      ;;
    --signed-by)
      SIGNED_BY="${2:-}"
      shift 2
      ;;
    --key-id)
      KEY_ID="${2:-}"
      shift 2
      ;;
    --signature-alg)
      SIGNATURE_ALG="${2:-}"
      shift 2
      ;;
    --signature)
      SIGNATURE_VALUE="${2:-}"
      shift 2
      ;;
    --envelope-version)
      ENVELOPE_VERSION="${2:-}"
      shift 2
      ;;
    --snapshot-id)
      SNAPSHOT_ID="${2:-}"
      shift 2
      ;;
    --sequence)
      SEQUENCE="${2:-}"
      shift 2
      ;;
    --refresh-cadence-sec)
      REFRESH_CADENCE_SEC="${2:-}"
      shift 2
      ;;
    --lkg-max-age-sec)
      LKG_MAX_AGE_SEC="${2:-}"
      shift 2
      ;;
    --issued-by-node)
      ISSUED_BY_NODE="${2:-}"
      shift 2
      ;;
    --issued-by-resolver)
      ISSUED_BY_RESOLVER="${2:-}"
      shift 2
      ;;
    --source-description)
      SOURCE_DESCRIPTION="${2:-}"
      shift 2
      ;;
    --projection-tool-bin)
      PROJECTION_TOOL_BIN="${2:-}"
      shift 2
      ;;
    --sign-with)
      SIGN_WITH_PRIVATE_KEY="${2:-}"
      shift 2
      ;;
    --include-www)
      INCLUDE_WWW=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if ! [[ "$TTL_FALLBACK" =~ ^[0-9]+$ ]] || [[ "$TTL_FALLBACK" -lt 60 ]]; then
  echo "--ttl-sec must be integer >= 60" >&2
  exit 2
fi
if [[ -n "$EXPIRES_IN_SEC" ]] && { ! [[ "$EXPIRES_IN_SEC" =~ ^[0-9]+$ ]] || [[ "$EXPIRES_IN_SEC" -lt 60 ]]; }; then
  echo "--expires-in-sec must be integer >= 60" >&2
  exit 2
fi
if ! [[ "$REFRESH_CADENCE_SEC" =~ ^[0-9]+$ ]] || [[ "$REFRESH_CADENCE_SEC" -lt 10 ]]; then
  echo "--refresh-cadence-sec must be integer >= 10" >&2
  exit 2
fi
if ! [[ "$LKG_MAX_AGE_SEC" =~ ^[0-9]+$ ]] || [[ "$LKG_MAX_AGE_SEC" -lt 0 ]]; then
  echo "--lkg-max-age-sec must be integer >= 0" >&2
  exit 2
fi
if ! [[ "$SEQUENCE" =~ ^[0-9]+$ ]]; then
  echo "--sequence must be integer >= 0" >&2
  exit 2
fi
case "$ENVELOPE_VERSION" in
  v1|v2) ;;
  *)
    echo "--envelope-version must be v1 or v2" >&2
    exit 2
    ;;
esac
if [[ -z "$PROJECTION_TOOL_BIN" ]]; then
  if [[ -x "/usr/local/sbin/projection-envelope-tool.py" ]]; then
    PROJECTION_TOOL_BIN="/usr/local/sbin/projection-envelope-tool.py"
  elif [[ -n "$REPO_PROJECTION_TOOL_BIN" ]]; then
    PROJECTION_TOOL_BIN="$REPO_PROJECTION_TOOL_BIN"
  else
    echo "projection tool path could not be discovered; pass --projection-tool-bin" >&2
    exit 1
  fi
fi
if [[ -n "$SIGN_WITH_PRIVATE_KEY" ]]; then
  [[ "$ENVELOPE_VERSION" == "v2" ]] || {
    echo "--sign-with requires --envelope-version v2" >&2
    exit 2
  }
  [[ -n "$KEY_ID" ]] || {
    echo "--sign-with requires --key-id" >&2
    exit 2
  }
fi

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing command: $cmd" >&2
    exit 1
  }
}

require_cmd curl
require_cmd jq
require_cmd base64
if [[ "$ENVELOPE_VERSION" == "v2" || -n "$SIGN_WITH_PRIVATE_KEY" ]]; then
  require_cmd python3
  [[ -x "$PROJECTION_TOOL_BIN" ]] || {
    echo "projection tool not executable: $PROJECTION_TOOL_BIN" >&2
    exit 1
  }
fi

trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

normalize_domain() {
  local d="$1"
  d="$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')"
  d="$(trim "$d")"
  if [[ "$d" =~ ^[a-z0-9][a-z0-9.-]{0,252}$ && "$d" != *..* ]]; then
    printf '%s' "$d"
    return 0
  fi
  return 1
}

normalize_id_like() {
  local v="$1"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    return 1
  fi
  printf '%s' "$v"
}

default_snapshot_id_from_generated_at() {
  local ts="$1"
  printf 'projection-%s' "$(printf '%s' "$ts" | tr ':' '-')"
}

default_site_id_from_host() {
  local host="$1"
  local token
  token="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  token="${token:0:96}"
  if [[ -z "$token" ]]; then
    token="host"
  fi
  printf 'site-%s' "$token"
}

extract_cfg_tx() {
  local txt="$1"
  printf '%s' "$txt" | sed -nE 's/.*(^|;)cfg=([A-Za-z0-9_-]{43})(;|$).*/\2/p'
}

extract_ttl() {
  local txt="$1"
  local ttl
  ttl="$(printf '%s' "$txt" | sed -nE 's/.*(^|;)ttl=([0-9]+)(;|$).*/\2/p')"
  if [[ -n "$ttl" ]]; then
    printf '%s' "$ttl"
  else
    printf '%s' "$TTL_FALLBACK"
  fi
}

decode_ar_payload_json() {
  local payload="$1"

  # Direct JSON payload.
  if printf '%s' "$payload" | jq -e type >/dev/null 2>&1; then
    printf '%s' "$payload"
    return 0
  fi

  # Base64url -> JSON payload.
  local b64
  b64="$(printf '%s' "$payload" | tr '_-' '/+')"
  local rem=$(( ${#b64} % 4 ))
  if [[ "$rem" -eq 2 ]]; then
    b64="${b64}=="
  elif [[ "$rem" -eq 3 ]]; then
    b64="${b64}="
  elif [[ "$rem" -eq 1 ]]; then
    return 1
  fi

  local decoded
  decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
  if [[ -z "$decoded" ]]; then
    return 1
  fi
  if printf '%s' "$decoded" | jq -e type >/dev/null 2>&1; then
    printf '%s' "$decoded"
    return 0
  fi
  return 1
}

domains=()
if [[ -n "$DOMAINS_CSV" ]]; then
  while IFS=',' read -r -a arr; do
    for item in "${arr[@]}"; do
      d="$(normalize_domain "$item" || true)"
      [[ -n "$d" ]] && domains+=("$d")
    done
  done <<<"$DOMAINS_CSV"
fi

if [[ -n "$DOMAINS_FILE" ]]; then
  if [[ ! -f "$DOMAINS_FILE" ]]; then
    echo "domains file not found: $DOMAINS_FILE" >&2
    exit 2
  fi
  while IFS= read -r line; do
    line="${line%%#*}"
    d="$(normalize_domain "$line" || true)"
    [[ -n "$d" ]] && domains+=("$d")
  done <"$DOMAINS_FILE"
fi

for arg in "$@"; do
  d="$(normalize_domain "$arg" || true)"
  [[ -n "$d" ]] && domains+=("$d")
done

if [[ ${#domains[@]} -eq 0 ]]; then
  echo "No domains provided." >&2
  usage
  exit 2
fi

mapfile -t domains < <(printf '%s\n' "${domains[@]}" | sort -u)

entries_tmp="$(mktemp)"
errors_tmp="$(mktemp)"
min_ttl=0

for domain in "${domains[@]}"; do
  dns_json="$(curl -sS --max-time 15 --get "$DNS_URL" --data-urlencode "name=_darkmesh.${domain}" --data-urlencode "type=TXT" || true)"
  txt_record="$(printf '%s' "$dns_json" | jq -r '.Answer[0].data // empty' 2>/dev/null | sed 's/^"//; s/"$//')"
  if [[ -z "$txt_record" ]]; then
    echo "${domain}: missing TXT _darkmesh record" >>"$errors_tmp"
    continue
  fi

  cfg_tx="$(extract_cfg_tx "$txt_record")"
  if [[ -z "$cfg_tx" ]]; then
    echo "${domain}: TXT has no cfg txid" >>"$errors_tmp"
    continue
  fi

  ttl="$(extract_ttl "$txt_record")"
  if [[ "$min_ttl" -eq 0 || "$ttl" -lt "$min_ttl" ]]; then
    min_ttl="$ttl"
  fi

  # Prefer canonical tx data endpoint to avoid gateway html wrappers.
  cfg_payload="$(curl -sS --max-time 20 "${AR_BASE%/}/tx/${cfg_tx}/data" || true)"
  cfg_json="$(decode_ar_payload_json "$cfg_payload" || true)"
  if [[ -z "$cfg_json" ]]; then
    # Fallback for gateways that still return direct JSON on /<txid>.
    cfg_payload="$(curl -sS --max-time 20 "${AR_BASE%/}/${cfg_tx}" || true)"
    cfg_json="$(decode_ar_payload_json "$cfg_payload" || true)"
  fi
  if [[ -z "$cfg_json" ]]; then
    echo "${domain}: cfg tx ${cfg_tx} is not valid JSON payload" >>"$errors_tmp"
    continue
  fi

  site_pid="$(printf '%s' "$cfg_json" | jq -r '.siteProcess // empty')"
  site_tx="$(printf '%s' "$cfg_json" | jq -r '.siteTx // .["x-siteTx"] // empty')"
  target_mode="$(printf '%s' "$cfg_json" | jq -r '.targetType // .targetMode // .["x-targetType"] // .["x-targetMode"] // empty' | tr '[:upper:]' '[:lower:]')"
  entry_path="$(printf '%s' "$cfg_json" | jq -r '.entryPath // "/"')"

  target_type=""
  target_id=""
  site_pid_ok=0
  site_tx_ok=0
  if [[ "$site_pid" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    site_pid_ok=1
  fi
  if [[ "$site_tx" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    site_tx_ok=1
  fi

  case "$target_mode" in
    ""|process)
      if [[ "$site_pid_ok" -eq 1 ]]; then
        target_type="process"
        target_id="$site_pid"
      elif [[ "$target_mode" == "" && "$site_tx_ok" -eq 1 ]]; then
        target_type="tx"
        target_id="$site_tx"
      else
        if [[ -n "$target_mode" ]]; then
          echo "${domain}: target mode is process but siteProcess is missing/invalid in cfg ${cfg_tx}" >>"$errors_tmp"
        else
          echo "${domain}: no valid siteProcess/siteTx target in cfg ${cfg_tx}" >>"$errors_tmp"
        fi
        continue
      fi
      ;;
    tx)
      if [[ "$site_tx_ok" -eq 1 ]]; then
        target_type="tx"
        target_id="$site_tx"
      else
        echo "${domain}: target mode is tx but siteTx/x-siteTx is missing/invalid in cfg ${cfg_tx}" >>"$errors_tmp"
        continue
      fi
      ;;
    *)
      echo "${domain}: unsupported target mode '${target_mode}' in cfg ${cfg_tx} (allowed: process|tx)" >>"$errors_tmp"
      continue
      ;;
  esac

  if ! printf '%s' "$entry_path" | grep -Eq '^/[A-Za-z0-9._~!$()*+,;=:@%/-]*$'; then
    echo "${domain}: invalid entryPath in cfg ${cfg_tx}" >>"$errors_tmp"
    continue
  fi

  site_id="$(default_site_id_from_host "$domain")"

  if [[ "$target_type" == "process" ]]; then
      jq -cn \
        --arg host "$domain" \
        --arg canonicalHost "$domain" \
        --arg siteId "$site_id" \
        --arg pid "$target_id" \
      --arg path "$entry_path" \
      --arg cfg "$cfg_tx" \
      --arg txt "$txt_record" \
      '{host:$host,canonicalHost:$canonicalHost,siteId:$siteId,targetType:"process",targetPid:$pid,pathPrefix:$path,enabled:true,cfgTx:$cfg,txt:$txt}' >>"$entries_tmp"
  else
      jq -cn \
        --arg host "$domain" \
        --arg canonicalHost "$domain" \
        --arg siteId "$site_id" \
        --arg tx "$target_id" \
      --arg path "$entry_path" \
      --arg cfg "$cfg_tx" \
      --arg txt "$txt_record" \
      '{host:$host,canonicalHost:$canonicalHost,siteId:$siteId,targetType:"tx",targetTx:$tx,pathPrefix:$path,enabled:true,cfgTx:$cfg,txt:$txt}' >>"$entries_tmp"
  fi

  if [[ "$INCLUDE_WWW" == "1" && "$domain" != www.* ]]; then
    if [[ "$target_type" == "process" ]]; then
      jq -cn \
        --arg host "www.${domain}" \
        --arg canonicalHost "$domain" \
        --arg siteId "$site_id" \
        --arg pid "$target_id" \
        --arg path "$entry_path" \
        --arg cfg "$cfg_tx" \
        --arg txt "$txt_record" \
        '{host:$host,canonicalHost:$canonicalHost,siteId:$siteId,targetType:"process",targetPid:$pid,pathPrefix:$path,enabled:true,cfgTx:$cfg,txt:$txt}' >>"$entries_tmp"
    else
      jq -cn \
        --arg host "www.${domain}" \
        --arg canonicalHost "$domain" \
        --arg siteId "$site_id" \
        --arg tx "$target_id" \
        --arg path "$entry_path" \
        --arg cfg "$cfg_tx" \
        --arg txt "$txt_record" \
        '{host:$host,canonicalHost:$canonicalHost,siteId:$siteId,targetType:"tx",targetTx:$tx,pathPrefix:$path,enabled:true,cfgTx:$cfg,txt:$txt}' >>"$entries_tmp"
    fi
  fi
done

error_count="$(wc -l < "$errors_tmp" | tr -d '[:space:]')"
if [[ "$error_count" -gt 0 ]]; then
  echo "build warnings/errors:" >&2
  cat "$errors_tmp" >&2
  if [[ "$STRICT" == "1" ]]; then
    rm -f "$entries_tmp" "$errors_tmp"
    exit 1
  fi
fi

if [[ ! -s "$entries_tmp" ]]; then
  echo "no valid entries generated" >&2
  rm -f "$entries_tmp" "$errors_tmp"
  exit 1
fi

if [[ "$min_ttl" -eq 0 ]]; then
  min_ttl="$TTL_FALLBACK"
fi

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
expires_ttl_sec="$min_ttl"
if [[ -n "$EXPIRES_IN_SEC" ]]; then
  expires_ttl_sec="$EXPIRES_IN_SEC"
fi
expires_at="$(date -u -d "@$(( $(date -u +%s) + expires_ttl_sec ))" +"%Y-%m-%dT%H:%M:%SZ")"
if [[ -z "$SNAPSHOT_ID" ]]; then
  SNAPSHOT_ID="$(default_snapshot_id_from_generated_at "$generated_at")"
fi
if [[ -z "$SOURCE_DESCRIPTION" ]]; then
  SOURCE_DESCRIPTION="DM1 projection for $(IFS=,; printf '%s' "${domains[*]}")"
fi

domains_json="$(printf '%s\n' "${domains[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
cfg_txs_json="$(jq -s '[.[].cfgTx] | map(select(type == "string" and length > 0)) | unique' "$entries_tmp")"

out_tmp="$(mktemp)"
if [[ "$ENVELOPE_VERSION" == "v1" ]]; then
  jq -s \
    --arg generatedAt "$generated_at" \
    --arg expiresAt "$expires_at" \
    --arg signedBy "$SIGNED_BY" \
    --arg signatureAlg "$SIGNATURE_ALG" \
    --arg signature "$SIGNATURE_VALUE" \
    '{
      version: "dm-hostmap-envelope.v1",
      generatedAt: $generatedAt,
      expiresAt: $expiresAt,
      signedBy: $signedBy,
      signatureAlg: $signatureAlg,
      signature: $signature,
      payload: {
        version: "dm-hostmap.v1",
        entries: .
      }
    }' \
    "$entries_tmp" >"$out_tmp"
else
  unsigned_tmp="$(mktemp)"
  jq -s \
    --arg generatedAt "$generated_at" \
    --arg expiresAt "$expires_at" \
    --arg signedBy "$SIGNED_BY" \
    --arg keyId "$KEY_ID" \
    --arg signatureAlg "${SIGN_WITH_PRIVATE_KEY:+ed25519}" \
    --arg signature "${SIGN_WITH_PRIVATE_KEY:+base64:UNSIGNED}" \
    --arg snapshotId "$SNAPSHOT_ID" \
    --arg sequence "$SEQUENCE" \
    --arg issuedByNode "$ISSUED_BY_NODE" \
    --arg issuedByResolver "$ISSUED_BY_RESOLVER" \
    --arg sourceDescription "$SOURCE_DESCRIPTION" \
    --argjson domains "$domains_json" \
    --argjson cfgTxs "$cfg_txs_json" \
    --argjson refreshCadenceSec "$REFRESH_CADENCE_SEC" \
    --argjson lkgMaxAgeSec "$LKG_MAX_AGE_SEC" \
    '{
      version: "dm-hostmap-envelope.v2",
      snapshotId: $snapshotId,
      sequence: ($sequence | tonumber),
      generatedAt: $generatedAt,
      expiresAt: $expiresAt,
      signedBy: $signedBy,
      keyId: $keyId,
      signatureAlg: (if $signatureAlg == "" then "bootstrap-none" else $signatureAlg end),
      signature: (if $signature == "" then "bootstrap" else $signature end),
      payloadHash: "sha256:PLACEHOLDER",
      payload: {
        version: "dm-hostmap.v2",
        authority: (
          {
            mode: (if ((if $signatureAlg == "" then "bootstrap-none" else $signatureAlg end) == "bootstrap-none") then "bootstrap" else "signed" end),
            sourceType: "dm1"
          }
          + (if $issuedByResolver != "" then {resolverId: $issuedByResolver} else {} end)
        ),
        source: {
          description: $sourceDescription,
          domains: $domains,
          cfgTxs: $cfgTxs
        },
        cacheHints: {
          refreshCadenceSec: $refreshCadenceSec,
          lkgMaxAgeSec: $lkgMaxAgeSec
        },
        entries: (
          map({
            host: .host,
            enabled: (.enabled // true),
            siteId: .siteId,
            cfgTx: .cfgTx,
            targetType: .targetType,
            pathPrefix: (.pathPrefix // "/"),
            canonicalHost: (.canonicalHost // .host)
          }
          + (if .targetType == "process" then {targetPid: .targetPid} else {targetTx: .targetTx} end))
        )
      }
    }
    + (if $issuedByNode != "" then {issuedByNode: $issuedByNode} else {} end)
    + (if $issuedByResolver != "" then {issuedByResolver: $issuedByResolver} else {} end)
    ' "$entries_tmp" >"$unsigned_tmp"

  payload_hash="$(python3 "$PROJECTION_TOOL_BIN" hash "$unsigned_tmp")"
  jq --arg payloadHash "$payload_hash" '.payloadHash = $payloadHash' "$unsigned_tmp" >"$out_tmp"

  if [[ -n "$SIGN_WITH_PRIVATE_KEY" ]]; then
    signed_tmp="$(mktemp)"
    python3 "$PROJECTION_TOOL_BIN" sign "$out_tmp" \
      --private-key-file "$SIGN_WITH_PRIVATE_KEY" \
      --signed-by "$SIGNED_BY" \
      --key-id "$KEY_ID" \
      --output "$signed_tmp"
    mv "$signed_tmp" "$out_tmp"
  else
    jq \
      --arg signatureAlg "$SIGNATURE_ALG" \
      --arg signature "$SIGNATURE_VALUE" \
      --arg signedBy "$SIGNED_BY" \
      --arg keyId "$KEY_ID" \
      '
      .signedBy = $signedBy
      | .keyId = $keyId
      | .signatureAlg = $signatureAlg
      | .signature = $signature
      | .payload.authority.mode = (if $signatureAlg == "bootstrap-none" then "bootstrap" else "signed" end)
      ' "$out_tmp" >"${out_tmp}.tmp"
    mv "${out_tmp}.tmp" "$out_tmp"
  fi
  rm -f "$unsigned_tmp"
fi

install -d -m 0755 "$(dirname "$OUTPUT_PATH")"
install -m 0640 "$out_tmp" "$OUTPUT_PATH"

entry_count="$(jq -sc 'length' "$entries_tmp")"
echo "host-routing envelope generated"
echo "  output=${OUTPUT_PATH}"
echo "  entries=${entry_count}"
echo "  generatedAt=${generated_at}"
echo "  expiresAt=${expires_at}"
echo "  signer=${SIGNED_BY}"
echo "  envelopeVersion=${ENVELOPE_VERSION}"
if [[ "$ENVELOPE_VERSION" == "v2" ]]; then
  echo "  keyId=${KEY_ID}"
  echo "  sequence=${SEQUENCE}"
fi
echo "  errors=${error_count}"

rm -f "$entries_tmp" "$errors_tmp" "$out_tmp"
