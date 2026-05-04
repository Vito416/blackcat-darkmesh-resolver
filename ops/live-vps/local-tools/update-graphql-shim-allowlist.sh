#!/usr/bin/env bash
set -euo pipefail

ALLOWLIST_FILE=""
REMOTE_TARGET=""
REMOTE_PATH="/etc/darkmesh/graphql-shim-allowlist.txt"
REMOTE_SSH_KEY=""
REMOTE_WITH_SUDO=1
DRY_RUN=0
OUTPUT_JSON=""

TX_IDS=()
MODULE_JSONS=()
CANDIDATE_REPORTS=()

usage() {
  cat <<'USAGE'
Update the optional DarkMesh GraphQL shim allowlist.

Usage:
  update-graphql-shim-allowlist.sh [options]

Tx sources (repeatable):
  --tx <id>                     Add this 43-char tx id.
  --module-json <path>          Read `.tx` from a publish_wasm_module JSON report.
  --candidate-report <path>     Read `.module.tx` from a fresh candidate summary report.

Targets:
  --allowlist-file <path>       Update a local allowlist file.
  --remote-target <user@host>   Update a remote allowlist over ssh.
  --remote-path <path>          Remote allowlist path.
                                Default: /etc/darkmesh/graphql-shim-allowlist.txt
  --remote-ssh-key <path>       SSH key for the remote target.
  --remote-with-sudo <0|1>      Use sudo for the remote write.
                                Default: 1

Other:
  --dry-run                     Show what would change without writing.
  --output-json <path>          Write a machine-readable summary JSON.
  -h, --help                    Show help.

Notes:
  - At least one tx source is required.
  - At least one target (--allowlist-file or --remote-target) is required.
USAGE
}

extract_json_field() {
  local path="$1"
  local expr="$2"
  python3 - "$path" "$expr" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expr = sys.argv[2]
obj = json.loads(path.read_text(encoding='utf-8'))
parts = [p for p in expr.split('.') if p]
cur = obj
for part in parts:
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if isinstance(cur, str) and cur.strip():
    print(cur.strip())
PY
}

normalize_txs() {
  python3 - "$@" <<'PY'
import re
import sys
seen = []
pattern = re.compile(r'^[A-Za-z0-9_-]{43}$')
for value in sys.argv[1:]:
    value = value.strip()
    if not value:
        continue
    if not pattern.match(value):
        print(f'invalid tx id: {value}', file=sys.stderr)
        raise SystemExit(2)
    if value not in seen:
        seen.append(value)
for value in seen:
    print(value)
PY
}

update_local_file() {
  local path="$1"
  shift
  python3 - "$path" "$DRY_RUN" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dry_run = sys.argv[2] == '1'
ids = list(sys.argv[3:])
existing_lines = []
existing_ids = []
if path.exists():
    existing_lines = path.read_text(encoding='utf-8').splitlines()
    for line in existing_lines:
        raw = line.split('#', 1)[0].strip()
        if raw:
            existing_ids.append(raw)
added = [tx for tx in ids if tx not in existing_ids]
if not dry_run and added:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = existing_lines[:]
    if lines and lines[-1].strip() != '':
        lines.append('')
    lines.extend(added)
    text = '\n'.join(lines).rstrip('\n') + '\n'
    path.write_text(text, encoding='utf-8')
print(json.dumps({'path': str(path), 'added': added, 'existingCount': len(existing_ids), 'finalCount': len(existing_ids) + len(added)}))
PY
}

update_remote_file() {
  local target="$1"
  local path="$2"
  shift 2
  local ssh_cmd=(ssh)
  if [[ -n "$REMOTE_SSH_KEY" ]]; then
    ssh_cmd+=(-i "$REMOTE_SSH_KEY")
  fi
  local remote_prefix=""
  if [[ "$REMOTE_WITH_SUDO" == "1" ]]; then
    remote_prefix="sudo "
  fi
  "${ssh_cmd[@]}" "$target" "${remote_prefix}python3 - '$path' '$DRY_RUN' '$@'" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
dry_run = sys.argv[2] == '1'
ids = list(sys.argv[3:])
existing_lines = []
existing_ids = []
if path.exists():
    existing_lines = path.read_text(encoding='utf-8').splitlines()
    for line in existing_lines:
        raw = line.split('#', 1)[0].strip()
        if raw:
            existing_ids.append(raw)
added = [tx for tx in ids if tx not in existing_ids]
if not dry_run and added:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = existing_lines[:]
    if lines and lines[-1].strip() != '':
        lines.append('')
    lines.extend(added)
    text = '\n'.join(lines).rstrip('\n') + '\n'
    path.write_text(text, encoding='utf-8')
print(json.dumps({'path': str(path), 'added': added, 'existingCount': len(existing_ids), 'finalCount': len(existing_ids) + len(added)}))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tx) TX_IDS+=("${2:-}"); shift 2 ;;
    --module-json) MODULE_JSONS+=("${2:-}"); shift 2 ;;
    --candidate-report) CANDIDATE_REPORTS+=("${2:-}"); shift 2 ;;
    --allowlist-file) ALLOWLIST_FILE="${2:-}"; shift 2 ;;
    --remote-target) REMOTE_TARGET="${2:-}"; shift 2 ;;
    --remote-path) REMOTE_PATH="${2:-}"; shift 2 ;;
    --remote-ssh-key) REMOTE_SSH_KEY="${2:-}"; shift 2 ;;
    --remote-with-sudo) REMOTE_WITH_SUDO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --output-json) OUTPUT_JSON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "${REMOTE_WITH_SUDO}" != "0" && "${REMOTE_WITH_SUDO}" != "1" ]]; then
  echo "--remote-with-sudo must be 0 or 1" >&2
  exit 2
fi

collected=()
for tx in "${TX_IDS[@]}"; do
  collected+=("$tx")
done
for path in "${MODULE_JSONS[@]}"; do
  [[ -f "$path" ]] || { echo "module json not found: $path" >&2; exit 2; }
  value="$(extract_json_field "$path" 'tx')"
  [[ -n "$value" ]] || { echo "module json missing .tx: $path" >&2; exit 2; }
  collected+=("$value")
done
for path in "${CANDIDATE_REPORTS[@]}"; do
  [[ -f "$path" ]] || { echo "candidate report not found: $path" >&2; exit 2; }
  value="$(extract_json_field "$path" 'module.tx')"
  [[ -n "$value" ]] || { echo "candidate report missing .module.tx: $path" >&2; exit 2; }
  collected+=("$value")
done

if [[ ${#collected[@]} -eq 0 ]]; then
  echo "At least one tx source is required" >&2
  exit 2
fi
if [[ -z "$ALLOWLIST_FILE" && -z "$REMOTE_TARGET" ]]; then
  echo "At least one target (--allowlist-file or --remote-target) is required" >&2
  exit 2
fi

mapfile -t NORMALIZED_TXS < <(normalize_txs "${collected[@]}")

local_result='null'
remote_result='null'
if [[ -n "$ALLOWLIST_FILE" ]]; then
  local_result="$(update_local_file "$ALLOWLIST_FILE" "${NORMALIZED_TXS[@]}")"
fi
if [[ -n "$REMOTE_TARGET" ]]; then
  remote_result="$(update_remote_file "$REMOTE_TARGET" "$REMOTE_PATH" "${NORMALIZED_TXS[@]}")"
fi

summary="$(jq -cn \
  --argjson txs "$(printf '%s\n' "${NORMALIZED_TXS[@]}" | jq -R . | jq -s .)" \
  --argjson local "$local_result" \
  --argjson remote "$remote_result" \
  --argjson dryRun "$DRY_RUN" \
  '{txs:$txs,dryRun:($dryRun==1),local:$local,remote:$remote}')"

if [[ -n "$OUTPUT_JSON" ]]; then
  printf '%s\n' "$summary" > "$OUTPUT_JSON"
fi
printf '%s\n' "$summary"
