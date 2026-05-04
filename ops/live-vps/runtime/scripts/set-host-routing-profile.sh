#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  set-host-routing-profile.sh <test|prod> [--dry-run] [--no-restart]

Profiles:
  test  -> interval 60s,  jitter 5s,  LKG 900s
  prod  -> interval 600s, jitter 30s, LKG 7200s

Options:
  --dry-run     Print planned changes only.
  --no-restart  Do not reload/restart systemd timer/service.
  -h, --help    Show this help.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

PROFILE="$1"
shift || true

DRY_RUN=0
NO_RESTART=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

case "$PROFILE" in
  test)
    INTERVAL_SEC=60
    JITTER_SEC=5
    LKG_SEC=900
    ;;
  prod)
    INTERVAL_SEC=600
    JITTER_SEC=30
    LKG_SEC=7200
    ;;
  *)
    echo "Profile must be test or prod (got: $PROFILE)" >&2
    exit 2
    ;;
esac

ENV_FILE="${DARKMESH_HOST_ROUTING_ENV_FILE:-/etc/darkmesh/resolver-projection.env}"
ENV_EXAMPLE="${DARKMESH_HOST_ROUTING_ENV_EXAMPLE:-/etc/darkmesh/resolver-projection.env.example}"
OVERRIDE_DIR="${DARKMESH_HOST_ROUTING_TIMER_OVERRIDE_DIR:-/etc/systemd/system/darkmesh-host-routing-sync.timer.d}"
OVERRIDE_FILE="${OVERRIDE_DIR}/10-profile.conf"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

upsert_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    run sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] append ${key}=${value} to ${file}"
    else
      printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
  fi
}

if [[ "$DRY_RUN" != "1" && "$(id -u)" -ne 0 ]]; then
  echo "Run as root (or use sudo)." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    run install -m 0640 "$ENV_EXAMPLE" "$ENV_FILE"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] create ${ENV_FILE} (minimal template)"
    else
      cat >"$ENV_FILE" <<'EOF'
DARKMESH_PROJECTION_URL=
DARKMESH_PROJECTION_SIGNER_ALLOWLIST=
DARKMESH_HOST_ROUTING_LKG_MAX_AGE_SEC=900
DARKMESH_PROJECTION_FETCH_TIMEOUT_SEC=10
DARKMESH_HOST_ROUTING_MAP_PATH=/etc/nginx/conf.d/darkmesh-host-routing-map.conf
DARKMESH_HOST_ROUTING_STATE_DIR=/var/lib/darkmesh/host-routing
DARKMESH_HOST_ROUTING_RELOAD_ON_CHANGE=1
DARKMESH_PROJECTION_TRUST_MANIFEST=/etc/darkmesh/projection-trust.json
DARKMESH_PROJECTION_REQUIRE_SIGNED=0
DARKMESH_PROJECTION_VERIFY_BIN=/usr/local/sbin/projection-envelope-tool.py
EOF
      chmod 0640 "$ENV_FILE"
    fi
  fi
fi

upsert_env "$ENV_FILE" "DARKMESH_HOST_ROUTING_LKG_MAX_AGE_SEC" "$LKG_SEC"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] write ${OVERRIDE_FILE}"
else
  install -d -m 0755 "$OVERRIDE_DIR"
  cat >"$OVERRIDE_FILE" <<EOF
[Timer]
OnBootSec=30s
OnUnitActiveSec=${INTERVAL_SEC}s
RandomizedDelaySec=${JITTER_SEC}s
EOF
fi

if [[ "$NO_RESTART" == "0" ]]; then
  run systemctl daemon-reload
  run systemctl restart darkmesh-host-routing-sync.timer
  run systemctl start darkmesh-host-routing-sync.service
fi

echo "host-routing profile applied"
echo "  profile=${PROFILE}"
echo "  interval_sec=${INTERVAL_SEC}"
echo "  jitter_sec=${JITTER_SEC}"
echo "  lkg_sec=${LKG_SEC}"
echo "  env_file=${ENV_FILE}"
echo "  timer_override=${OVERRIDE_FILE}"
