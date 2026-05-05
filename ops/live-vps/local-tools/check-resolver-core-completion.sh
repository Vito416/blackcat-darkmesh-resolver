#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-resolver-core-completion.sh [options]

Resolver-core completion gate built on top of
ops/live-vps/local-tools/audit-resolver-runtime-posture.sh.

Profiles:
  production-stable
    - signed projection required
    - sync timer enabled and active
    - projection URL configured

  pre-onboarding-complete
    - everything from production-stable
    - DM1 parity required
    - projection-backed adapter no longer treated as the desired end-state

Options:
  --profile <name>         Completion profile.
                           Default: pre-onboarding-complete
  --audit-json <path>      Reuse an existing audit JSON instead of re-running
                           the audit helper.
  --env-file <path>        Forwarded to audit helper.
  --state-file <path>      Forwarded to audit helper.
  --output <path>          Optional JSON output path.
  --sudo                   Forwarded to audit helper for root-owned node files.
  --skip-systemctl         Forwarded to audit helper.
  -h, --help               Show help.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/audit-resolver-runtime-posture.sh"

PROFILE="pre-onboarding-complete"
AUDIT_JSON=""
ENV_FILE=""
STATE_FILE=""
OUTPUT_PATH=""
USE_SUDO=0
SKIP_SYSTEMCTL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --audit-json) AUDIT_JSON="${2:-}"; shift 2 ;;
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
bash -n "$AUDIT_SCRIPT" >/dev/null

case "$PROFILE" in
  production-stable|pre-onboarding-complete) ;;
  *)
    echo "unsupported profile: $PROFILE" >&2
    exit 2
    ;;
esac

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

audit_path="$AUDIT_JSON"
if [[ -z "$audit_path" ]]; then
  audit_path="$tmp_dir/runtime-posture.json"
  audit_args=(--output "$audit_path")
  [[ -n "$ENV_FILE" ]] && audit_args+=(--env-file "$ENV_FILE")
  [[ -n "$STATE_FILE" ]] && audit_args+=(--state-file "$STATE_FILE")
  (( USE_SUDO == 1 )) && audit_args+=(--sudo)
  (( SKIP_SYSTEMCTL == 1 )) && audit_args+=(--skip-systemctl)
  bash "$AUDIT_SCRIPT" "${audit_args[@]}" >/dev/null
fi

[[ -f "$audit_path" ]] || {
  echo "audit json not found: $audit_path" >&2
  exit 2
}

jq -e '
  type == "object"
  and (.projection? | type == "object")
  and (.services? | type == "object")
  and (.posture? | type == "object")
' "$audit_path" >/dev/null || {
  echo "invalid audit json: $audit_path" >&2
  exit 2
}

readarray -t base_failures < <(
  jq -r '
    [
      (if (.projection.envReadable // false) != true then "projection_env_unreadable" else empty end),
      (if (.state.readable // false) != true then "projection_state_unreadable" else empty end),
      (if (.projection.url // null) == null then "projection_url_missing" else empty end),
      (if (.projection.requireSigned // false) != true then "signed_projection_not_required" else empty end),
      (if ((.state.mode // "") != "active" and (.state.mode // "") != "stale_lkg" and (.state.mode // "") != "lkg") then "runtime_state_not_active" else empty end),
      (if (.services.syncTimer.enabled // "") != "enabled" then "sync_timer_not_enabled" else empty end),
      (if ((.services.syncTimer.active // "") != "active" and (.services.syncTimer.active // "") != "activating") then "sync_timer_not_active" else empty end)
    ] | .[]
  ' "$audit_path"
)

failures=("${base_failures[@]}")
if [[ "$PROFILE" == "pre-onboarding-complete" ]]; then
  while IFS= read -r line; do failures+=("$line"); done < <(
    jq -r '
      [
        (if (.projection.requireDm1Parity // false) != true then "dm1_parity_not_required" else empty end),
        (if (.posture.readPathMode // "") == "projection_adapter" then "projection_adapter_still_in_serving_path" else empty end)
      ] | .[]
    ' "$audit_path"
  )
fi

failures_json='[]'
if (( ${#failures[@]} > 0 )); then
  failures_json="$(printf '%s\n' "${failures[@]}" | awk 'NF && !seen[$0]++' | jq -R . | jq -s .)"
fi

ready_json='true'
(( ${#failures[@]} > 0 )) && ready_json='false'

result="$(jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg profile "$PROFILE" \
  --arg auditPath "$audit_path" \
  --argjson ready "$ready_json" \
  --argjson blockers "$failures_json" \
  --slurpfile audit "$audit_path" \
  '{
    generatedAt: $generatedAt,
    profile: $profile,
    ready: $ready,
    blockers: $blockers,
    auditPath: $auditPath,
    posture: ($audit[0] // null)
  }')"

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  printf '%s\n' "$result" >"$OUTPUT_PATH"
fi

printf '%s\n' "$result"

if [[ "$ready_json" != "true" ]]; then
  echo >&2
  echo "resolver-core completion check: NOT READY ($PROFILE)" >&2
  printf '%s\n' "${failures[@]}" | awk 'NF && !seen[$0]++ { print " - " $0 }' >&2
  exit 1
fi

echo >&2
echo "resolver-core completion check: READY ($PROFILE)" >&2
