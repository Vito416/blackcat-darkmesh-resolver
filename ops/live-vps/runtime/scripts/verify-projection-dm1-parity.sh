#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-projection-dm1-parity.sh --envelope <path> [options]

Rebuild a DM1-derived projection payload from live DNS + AR inputs and compare
its canonical payload hash to the candidate signed envelope.

This is a node-side integrity check:

- signature says who released the artifact
- DM1 parity says the payload still matches canonical DNS/AR-derived inputs

Options:
  --envelope <path>            Candidate envelope JSON (required).
  --output <path>              Write JSON report here. Default: stdout
  --builder-bin <path>         Default: /usr/local/sbin/build-host-routing-envelope-from-dm1.sh
  --projection-tool-bin <path> Default: /usr/local/sbin/projection-envelope-tool.py
  --dns-url <url>              Default: https://dns.google/resolve
  --ar-base <url>              Default: https://arweave.net
  --work-dir <path>            Reuse an existing work directory.
  --strict-builder             Force builder --strict mode (default: on)
  -h|--help                    Show help.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
if REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." 2>/dev/null && pwd)"; then
  :
else
  REPO_ROOT=""
fi

DEFAULT_BUILDER_BIN="/usr/local/sbin/build-host-routing-envelope-from-dm1.sh"
DEFAULT_PROJECTION_TOOL_BIN="/usr/local/sbin/projection-envelope-tool.py"
if [[ ! -x "$DEFAULT_BUILDER_BIN" && -n "$REPO_ROOT" && -x "$REPO_ROOT/ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh" ]]; then
  DEFAULT_BUILDER_BIN="$REPO_ROOT/ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh"
fi
if [[ ! -x "$DEFAULT_PROJECTION_TOOL_BIN" && -n "$REPO_ROOT" && -x "$REPO_ROOT/scripts/projection-envelope-tool.py" ]]; then
  DEFAULT_PROJECTION_TOOL_BIN="$REPO_ROOT/scripts/projection-envelope-tool.py"
fi

ENVELOPE_PATH=""
OUTPUT_PATH=""
BUILDER_BIN="$DEFAULT_BUILDER_BIN"
PROJECTION_TOOL_BIN="$DEFAULT_PROJECTION_TOOL_BIN"
DNS_URL="https://dns.google/resolve"
AR_BASE="https://arweave.net"
WORK_DIR=""
STRICT_BUILDER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --envelope) ENVELOPE_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --builder-bin) BUILDER_BIN="${2:-}"; shift 2 ;;
    --projection-tool-bin) PROJECTION_TOOL_BIN="${2:-}"; shift 2 ;;
    --dns-url) DNS_URL="${2:-}"; shift 2 ;;
    --ar-base) AR_BASE="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --strict-builder) STRICT_BUILDER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$ENVELOPE_PATH" ]] || { echo "--envelope required" >&2; exit 2; }
[[ -f "$ENVELOPE_PATH" ]] || { echo "envelope not found: $ENVELOPE_PATH" >&2; exit 2; }
[[ -x "$BUILDER_BIN" ]] || { echo "builder not executable: $BUILDER_BIN" >&2; exit 2; }
[[ -x "$PROJECTION_TOOL_BIN" ]] || { echo "projection tool not executable: $PROJECTION_TOOL_BIN" >&2; exit 2; }

require_cmd jq
require_cmd mktemp
require_cmd sort
require_cmd comm

cleanup() {
  if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT:-}" && -z "${WORK_DIR:-}" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

if [[ -n "$WORK_DIR" ]]; then
  mkdir -p "$WORK_DIR"
  TMP_ROOT="$WORK_DIR"
else
  TMP_ROOT="$(mktemp -d)"
fi

report_tmp="$TMP_ROOT/parity-report.json"
rebuilt_envelope="$TMP_ROOT/rebuilt-envelope.json"
candidate_flat="$TMP_ROOT/candidate-flat.tsv"
rebuilt_flat="$TMP_ROOT/rebuilt-flat.tsv"
removed_flat="$TMP_ROOT/removed-flat.tsv"
added_flat="$TMP_ROOT/added-flat.tsv"

emit_report() {
  local source="$1"
  if [[ -n "$OUTPUT_PATH" ]]; then
    install -m 0644 "$source" "$OUTPUT_PATH"
  else
    cat "$source"
  fi
}

write_failure_report() {
  local reason="$1"
  local note="${2:-}"
  jq -n \
    --arg ok "false" \
    --arg reason "$reason" \
    --arg note "$note" \
    '{
      ok: false,
      reason: $reason
    } + (if $note != "" then {note: $note} else {} end)' >"$report_tmp"
  emit_report "$report_tmp"
}

source_type="$(jq -r '.payload.authority.sourceType // empty' "$ENVELOPE_PATH")"
if [[ "$source_type" != "dm1" ]]; then
  write_failure_report "unsupported_source_type" "expected payload.authority.sourceType=dm1"
  exit 1
fi

candidate_payload_hash="$(jq -r '.payloadHash // empty' "$ENVELOPE_PATH")"
if [[ -z "$candidate_payload_hash" ]]; then
  write_failure_report "candidate_payload_hash_missing"
  exit 1
fi

mapfile -t source_domains < <(jq -r '.payload.source.domains[]? // empty' "$ENVELOPE_PATH")
if [[ ${#source_domains[@]} -eq 0 ]]; then
  write_failure_report "source_domains_missing"
  exit 1
fi

domains_csv="$(printf '%s\n' "${source_domains[@]}" | sort -u | paste -sd, -)"
refresh_cadence_sec="$(jq -r '.payload.cacheHints.refreshCadenceSec // 60' "$ENVELOPE_PATH")"
lkg_max_age_sec="$(jq -r '.payload.cacheHints.lkgMaxAgeSec // 900' "$ENVELOPE_PATH")"
source_description="$(jq -r '.payload.source.description // empty' "$ENVELOPE_PATH")"
issued_by_resolver="$(jq -r '.issuedByResolver // .payload.authority.resolverId // empty' "$ENVELOPE_PATH")"
include_www="0"
if jq -e '[.payload.entries[] | (.host // empty), (.hosts[]?)] | any(type == "string" and test("^www\\."))' "$ENVELOPE_PATH" >/dev/null 2>&1; then
  include_www="1"
fi

builder_args=(
  --domains "$domains_csv"
  --output "$rebuilt_envelope"
  --dns-url "$DNS_URL"
  --ar-base "$AR_BASE"
  --envelope-version v2
  --signed-by parity-check
  --key-id parity-check
  --signature-alg ed25519
  --signature base64:PARITY-CHECK
  --projection-tool-bin "$PROJECTION_TOOL_BIN"
  --refresh-cadence-sec "$refresh_cadence_sec"
  --lkg-max-age-sec "$lkg_max_age_sec"
)
if [[ -n "$source_description" ]]; then
  builder_args+=(--source-description "$source_description")
fi
if [[ -n "$issued_by_resolver" ]]; then
  builder_args+=(--issued-by-resolver "$issued_by_resolver")
fi
if [[ "$include_www" == "1" ]]; then
  builder_args+=(--include-www)
fi
if [[ "$STRICT_BUILDER" == "1" ]]; then
  builder_args+=(--strict)
fi

builder_stderr="$TMP_ROOT/builder.stderr.log"
if ! "$BUILDER_BIN" "${builder_args[@]}" > /dev/null 2>"$builder_stderr"; then
  write_failure_report "dm1_rebuild_failed" "$(tr '\n' ' ' < "$builder_stderr" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^ //; s/ $//')"
  exit 1
fi

rebuilt_payload_hash="$(python3 "$PROJECTION_TOOL_BIN" hash "$rebuilt_envelope")"

emit_flat_entries() {
  local source="$1"
  local target="$2"
  jq -r '
    .payload.entries
    | map(
        if (.hosts | type) == "array" then
          .hosts[] as $h
          | {
              host: $h,
              canonicalHost: (.canonicalHost // .host // $h),
              cfgTx: (.cfgTx // ""),
              targetType: (.targetType // ""),
              targetId: (.targetPid // .targetTx // ""),
              pathPrefix: (.pathPrefix // "/")
            }
        else
          {
            host: (.host // ""),
            canonicalHost: (.canonicalHost // .host // ""),
            cfgTx: (.cfgTx // ""),
            targetType: (.targetType // ""),
            targetId: (.targetPid // .targetTx // ""),
            pathPrefix: (.pathPrefix // "/")
          }
        end
      )
    | .[]
    | [.host, .canonicalHost, .cfgTx, .targetType, .targetId, .pathPrefix]
    | @tsv
  ' "$source" | sort >"$target"
}

emit_flat_entries "$ENVELOPE_PATH" "$candidate_flat"
emit_flat_entries "$rebuilt_envelope" "$rebuilt_flat"

comm -23 "$candidate_flat" "$rebuilt_flat" >"$removed_flat" || true
comm -13 "$candidate_flat" "$rebuilt_flat" >"$added_flat" || true

removed_count="$(wc -l < "$removed_flat" | tr -d '[:space:]')"
added_count="$(wc -l < "$added_flat" | tr -d '[:space:]')"
candidate_entry_count="$(wc -l < "$candidate_flat" | tr -d '[:space:]')"
rebuilt_entry_count="$(wc -l < "$rebuilt_flat" | tr -d '[:space:]')"

if [[ "$candidate_payload_hash" != "$rebuilt_payload_hash" ]]; then
  jq -n \
    --arg reason "payload_hash_mismatch" \
    --arg candidatePayloadHash "$candidate_payload_hash" \
    --arg rebuiltPayloadHash "$rebuilt_payload_hash" \
    --arg sourceType "$source_type" \
    --arg sourceDomainsCsv "$domains_csv" \
    --argjson inferredIncludeWww "$([[ "$include_www" == "1" ]] && echo true || echo false)" \
    --argjson candidateEntryCount "$candidate_entry_count" \
    --argjson rebuiltEntryCount "$rebuilt_entry_count" \
    --argjson removedCount "$removed_count" \
    --argjson addedCount "$added_count" \
    --argjson removedSample "$(jq -Rsc 'split("\n") | map(select(length > 0)) | .[:10]' < "$removed_flat")" \
    --argjson addedSample "$(jq -Rsc 'split("\n") | map(select(length > 0)) | .[:10]' < "$added_flat")" \
    '{
      ok: false,
      reason: $reason,
      sourceType: $sourceType,
      sourceDomainsCsv: $sourceDomainsCsv,
      inferredIncludeWww: $inferredIncludeWww,
      candidatePayloadHash: $candidatePayloadHash,
      rebuiltPayloadHash: $rebuiltPayloadHash,
      candidateEntryCount: $candidateEntryCount,
      rebuiltEntryCount: $rebuiltEntryCount,
      removedCount: $removedCount,
      addedCount: $addedCount,
      removedSample: $removedSample,
      addedSample: $addedSample
    }' >"$report_tmp"
  emit_report "$report_tmp"
  exit 1
fi

jq -n \
  --arg candidatePayloadHash "$candidate_payload_hash" \
  --arg rebuiltPayloadHash "$rebuilt_payload_hash" \
  --arg sourceType "$source_type" \
  --arg sourceDomainsCsv "$domains_csv" \
  --argjson inferredIncludeWww "$([[ "$include_www" == "1" ]] && echo true || echo false)" \
  --argjson sourceDomainCount "${#source_domains[@]}" \
  --argjson candidateEntryCount "$candidate_entry_count" \
  --argjson rebuiltEntryCount "$rebuilt_entry_count" \
  '{
    ok: true,
    reason: "ok_dm1_payload_parity",
    sourceType: $sourceType,
    sourceDomainsCsv: $sourceDomainsCsv,
    sourceDomainCount: $sourceDomainCount,
    inferredIncludeWww: $inferredIncludeWww,
    candidatePayloadHash: $candidatePayloadHash,
    rebuiltPayloadHash: $rebuiltPayloadHash,
    candidateEntryCount: $candidateEntryCount,
    rebuiltEntryCount: $rebuiltEntryCount
  }' >"$report_tmp"

emit_report "$report_tmp"
