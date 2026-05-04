#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DEST_ROOT="/"
ENABLE_SERVICES=0
INSTALL_NGINX_LOOPBACKS=0
FORCE_EXAMPLES=0

usage() {
  cat <<'EOF'
Usage:
  install-stock-hb-companion.sh [options]

Options:
  --root <path>               Install into an alternate filesystem root.
  --enable-services           Run systemctl daemon-reload and enable/start resolver units.
  --install-nginx-loopbacks   Install live loopback server blocks into sites-available/.
  --force-examples            Overwrite existing env/example targets.
  -h, --help                  Show this help.

Notes:
  - default target paths match the stock companion layout used by the resolver docs
  - without --install-nginx-loopbacks, nginx server blocks are installed as *.example
  - without --enable-services, the script only stages files and prints next steps
EOF
}

log() {
  printf '[resolver-companion-install] %s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || fail "--root requires a path"
      DEST_ROOT="$2"
      shift 2
      ;;
    --enable-services)
      ENABLE_SERVICES=1
      shift
      ;;
    --install-nginx-loopbacks)
      INSTALL_NGINX_LOOPBACKS=1
      shift
      ;;
    --force-examples)
      FORCE_EXAMPLES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_cmd install
require_cmd cp

mkdir -p "$DEST_ROOT"
[[ -d "$DEST_ROOT" ]] || fail "destination root is not a directory: $DEST_ROOT"

dest_path() {
  local rel="$1"
  if [[ "$DEST_ROOT" == "/" ]]; then
    printf '/%s' "${rel#/}"
  else
    printf '%s/%s' "${DEST_ROOT%/}" "${rel#/}"
  fi
}

install_file() {
  local src="$1"
  local dest_rel="$2"
  local mode="$3"
  local dest
  dest="$(dest_path "$dest_rel")"
  install -d -m 0755 "$(dirname "$dest")"
  install -m "$mode" "$src" "$dest"
  log "installed $(realpath --relative-to="$REPO_ROOT" "$src" 2>/dev/null || printf '%s' "$src") -> $dest_rel"
}

install_if_missing_or_forced() {
  local src="$1"
  local dest_rel="$2"
  local mode="$3"
  local dest
  dest="$(dest_path "$dest_rel")"
  if [[ -e "$dest" && "$FORCE_EXAMPLES" != "1" ]]; then
    log "kept existing $dest_rel"
    return 0
  fi
  install_file "$src" "$dest_rel" "$mode"
}

SYSTEMD_UNITS=(
  darkmesh-host-routing-sync.service
  darkmesh-host-routing-sync.timer
  darkmesh-resolver-pid-sync.service
  darkmesh-resolver-pid-sync.timer
  darkmesh-resolver-read-adapter.service
  darkmesh-graphql-shim.service
)

HELPER_BINS=(
  "scripts/projection-envelope-tool.py:/usr/local/sbin/projection-envelope-tool.py:0755"
  "ops/live-vps/runtime/scripts/build-host-routing-envelope-from-dm1.sh:/usr/local/sbin/build-host-routing-envelope-from-dm1.sh:0755"
  "ops/live-vps/runtime/scripts/darkmesh-resolver-read-adapter.py:/usr/local/sbin/darkmesh-resolver-read-adapter.py:0755"
  "ops/live-vps/runtime/scripts/darkmesh-graphql-shim.py:/usr/local/sbin/darkmesh-graphql-shim.py:0755"
  "ops/live-vps/runtime/scripts/set-host-routing-profile.sh:/usr/local/sbin/set-host-routing-profile.sh:0755"
  "ops/live-vps/runtime/scripts/sync-nginx-host-routing.sh:/usr/local/sbin/sync-nginx-host-routing.sh:0755"
  "ops/live-vps/runtime/scripts/sync-nginx-resolver-pid.sh:/usr/local/sbin/sync-nginx-resolver-pid.sh:0755"
  "ops/live-vps/runtime/scripts/verify-projection-dm1-parity.sh:/usr/local/sbin/verify-projection-dm1-parity.sh:0755"
)

ENV_EXAMPLES=(
  "ops/live-vps/runtime/etc/darkmesh/resolver-projection.env.example:/etc/darkmesh/resolver-projection.env:0644"
  "ops/live-vps/runtime/etc/darkmesh/resolver-adapter.env.example:/etc/darkmesh/resolver-adapter.env:0644"
  "ops/live-vps/runtime/etc/darkmesh/projection-domains.txt.example:/etc/darkmesh/projection-domains.txt:0644"
  "ops/live-vps/runtime/etc/darkmesh/projection-trust.example.json:/etc/darkmesh/projection-trust.json:0644"
  "ops/live-vps/runtime/etc/darkmesh/graphql-shim.env.example:/etc/darkmesh/graphql-shim.env:0644"
  "ops/live-vps/runtime/etc/darkmesh/graphql-shim-allowlist.txt.example:/etc/darkmesh/graphql-shim-allowlist.txt:0644"
)

for triple in "${HELPER_BINS[@]}"; do
  IFS=':' read -r src_rel dest_rel mode <<<"$triple"
  install_file "$REPO_ROOT/$src_rel" "$dest_rel" "$mode"
done

for unit in "${SYSTEMD_UNITS[@]}"; do
  install_file \
    "$REPO_ROOT/ops/live-vps/runtime/systemd/$unit" \
    "/etc/systemd/system/$unit" \
    0644
done

for triple in "${ENV_EXAMPLES[@]}"; do
  IFS=':' read -r src_rel dest_rel mode <<<"$triple"
  install_if_missing_or_forced "$REPO_ROOT/$src_rel" "$dest_rel" "$mode"
done

install_if_missing_or_forced \
  "$REPO_ROOT/ops/live-vps/runtime/nginx/conf.d/darkmesh-host-routing-map.conf.example" \
  "/etc/nginx/conf.d/darkmesh-host-routing-map.conf" \
  0644

install_if_missing_or_forced \
  "$REPO_ROOT/ops/live-vps/runtime/nginx/snippets/darkmesh-resolver-pid.conf.example" \
  "/etc/nginx/snippets/darkmesh-resolver-pid.conf" \
  0644

if [[ "$INSTALL_NGINX_LOOPBACKS" == "1" ]]; then
  install_file \
    "$REPO_ROOT/ops/live-vps/runtime/nginx/hyperbeam-loopback.conf" \
    "/etc/nginx/sites-available/darkmesh-hyperbeam-loopback.conf" \
    0644
  install_file \
    "$REPO_ROOT/ops/live-vps/runtime/nginx/write-loopback.conf" \
    "/etc/nginx/sites-available/darkmesh-write-loopback.conf" \
    0644
else
  install_if_missing_or_forced \
    "$REPO_ROOT/ops/live-vps/runtime/nginx/hyperbeam-loopback.conf" \
    "/etc/nginx/sites-available/darkmesh-hyperbeam-loopback.conf.example" \
    0644
  install_if_missing_or_forced \
    "$REPO_ROOT/ops/live-vps/runtime/nginx/write-loopback.conf" \
    "/etc/nginx/sites-available/darkmesh-write-loopback.conf.example" \
    0644
fi

if [[ "$ENABLE_SERVICES" == "1" ]]; then
  [[ "$DEST_ROOT" == "/" ]] || fail "--enable-services can only be used with --root /"
  require_cmd systemctl
  systemctl daemon-reload
  systemctl enable --now darkmesh-resolver-read-adapter.service
  systemctl enable --now darkmesh-host-routing-sync.timer
  log "enabled resolver adapter service and host-routing sync timer"
else
  log "services not enabled automatically"
fi

hyperbeam_loopback_path="/etc/nginx/sites-available/darkmesh-hyperbeam-loopback.conf.example"
write_loopback_path="/etc/nginx/sites-available/darkmesh-write-loopback.conf.example"
if [[ "$INSTALL_NGINX_LOOPBACKS" == "1" ]]; then
  hyperbeam_loopback_path="/etc/nginx/sites-available/darkmesh-hyperbeam-loopback.conf"
  write_loopback_path="/etc/nginx/sites-available/darkmesh-write-loopback.conf"
fi

cat <<EOF

Stock-HB companion pack staged successfully.

Installed runtime root: ${DEST_ROOT}

Next steps:
1. Edit:
   - /etc/darkmesh/resolver-projection.env
   - /etc/darkmesh/resolver-adapter.env
   - /etc/darkmesh/projection-trust.json
2. Install or merge nginx loopback config:
   - ${hyperbeam_loopback_path}
   - ${write_loopback_path}
3. Ensure nginx loads:
   - /etc/nginx/conf.d/darkmesh-host-routing-map.conf
   - /etc/nginx/snippets/darkmesh-resolver-pid.conf
4. Optional GraphQL shim (DarkMesh-only metadata cache):
   - /etc/darkmesh/graphql-shim.env
   - /etc/darkmesh/graphql-shim-allowlist.txt
   - systemctl enable --now darkmesh-graphql-shim.service
   - set HB GRAPHQL_URL / GRAPHQL_URLS to the shim URL only if you want to use it
5. Run:
   - systemctl daemon-reload
   - systemctl enable --now darkmesh-resolver-read-adapter.service
   - systemctl enable --now darkmesh-host-routing-sync.timer
6. Validate with:
   - docs/RESOLVER_SIGNED_PROJECTION_ACTIVATION_CHECKLIST_2026-04-30.md

EOF
