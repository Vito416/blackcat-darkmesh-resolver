#!/usr/bin/env bash
set -euo pipefail

PID_FILE_PRIMARY="${PID_FILE_PRIMARY:-/srv/darkmesh/hb/data/rolling/darkmesh-resolver.pid}"
PID_FILE_FALLBACK="${PID_FILE_FALLBACK:-/srv/darkmesh/hb/data/darkmesh-resolver.pid}"
SNIPPET_PATH="${SNIPPET_PATH:-/etc/nginx/snippets/darkmesh-resolver-pid.conf}"
DO_RELOAD="${DO_RELOAD:-0}"

pid=""
for f in "$PID_FILE_PRIMARY" "$PID_FILE_FALLBACK"; do
  if [[ -s "$f" ]]; then
    pid="$(tr -d '\r\n' < "$f")"
    break
  fi
done

if [[ ! "$pid" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
  echo "resolver pid not found or invalid in: $PID_FILE_PRIMARY / $PID_FILE_FALLBACK" >&2
  exit 1
fi

tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Managed by sync-nginx-resolver-pid.sh. Do not edit manually.
set \$dm_resolver_pid "$pid";
EOF

install -d -m 0755 "$(dirname "$SNIPPET_PATH")"
changed=1
if [[ -f "$SNIPPET_PATH" ]] && cmp -s "$tmp" "$SNIPPET_PATH"; then
  changed=0
else
  install -m 0644 "$tmp" "$SNIPPET_PATH"
fi
rm -f "$tmp"

nginx -t
if [[ "$DO_RELOAD" == "1" && "$changed" == "1" ]]; then
  systemctl reload nginx
fi

echo "resolver_pid=$pid"
echo "snippet=$SNIPPET_PATH"
echo "changed=$changed"
if [[ "$DO_RELOAD" == "1" && "$changed" == "1" ]]; then
  echo "nginx_reloaded=1"
else
  echo "nginx_reloaded=0"
fi
