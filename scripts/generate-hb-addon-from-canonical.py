#!/usr/bin/env python3
from __future__ import annotations

import argparse
import difflib
from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_SOURCE = REPO_ROOT / "ao" / "resolver" / "process.lua"
ADDON_TARGET = (
    REPO_ROOT / "ops" / "live-vps" / "runtime" / "hb" / "addons" / "darkmesh-resolver@1.0.lua"
)
OVERLAY_SOURCE = (
    REPO_ROOT
    / "ops"
    / "live-vps"
    / "runtime"
    / "hb"
    / "addons"
    / "patches"
    / "www-host-alias-overlay.lua"
)

OVERLAY_ANCHOR = "local normalize_path\n"

REPLACEMENTS = [
    (
        "  local route_policy = state.routePolicies[host]\n",
        "  local route_policy = lookup_host_scoped_entry(state.routePolicies, host)\n",
    ),
    (
        "  local deny_entry = deny_hosts[host]\n",
        "  local deny_entry = lookup_host_scoped_entry(deny_hosts, host)\n",
    ),
    (
        "  if admission.allowlistEnabled == true then\n"
        "    local allow_hosts = admission.allowHosts or {}\n"
        "    if allow_hosts[host] == nil then\n",
        "  if admission.allowlistEnabled == true then\n"
        "    local allow_hosts = admission.allowHosts or {}\n"
        "    local allow_entry = lookup_host_scoped_entry(allow_hosts, host)\n"
        "    if allow_entry == nil then\n",
    ),
    (
        "  local host_policy = state.hostPolicies[host]\n"
        "  local host_known = host_policy ~= nil\n"
        "  local proof_payload = build_proof_payload(host)\n",
        "  local host_policy = lookup_host_scoped_entry(state.hostPolicies, host)\n"
        "  local host_known = host_policy ~= nil\n"
        "  local proof_payload = build_proof_payload(host)\n",
    ),
    (
        "  local host_policy = state.hostPolicies[host]\n"
        "  local host_known = host_policy ~= nil\n"
        "  local site_obj, process_obj = infer_site_process(host, host_policy)\n",
        "  local host_policy = lookup_host_scoped_entry(state.hostPolicies, host)\n"
        "  local host_known = host_policy ~= nil\n"
        "  local site_obj, process_obj = infer_site_process(host, host_policy)\n",
    ),
]


def apply_once(source: str, old: str, new: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"expected exactly 1 occurrence for patch block, found {count}: {old.splitlines()[0]!r}"
        )
    return source.replace(old, new, 1)


def generate() -> str:
    canonical = CANONICAL_SOURCE.read_text(encoding="utf-8")
    overlay = OVERLAY_SOURCE.read_text(encoding="utf-8").rstrip() + "\n"

    if OVERLAY_ANCHOR not in canonical:
        raise RuntimeError(f"overlay anchor not found: {OVERLAY_ANCHOR!r}")

    generated = canonical.replace(OVERLAY_ANCHOR, OVERLAY_ANCHOR + "\n" + overlay, 1)
    for old, new in REPLACEMENTS:
        generated = apply_once(generated, old, new)
    return generated


def write_output(content: str, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")


def run_check(content: str, existing: str, existing_path: Path) -> int:
    if content == existing:
        print(f"OK addon matches canonical source + overlay: {existing_path}")
        return 0

    diff = difflib.unified_diff(
        existing.splitlines(keepends=True),
        content.splitlines(keepends=True),
        fromfile=str(existing_path),
        tofile="generated://darkmesh-resolver-addon",
    )
    sys.stdout.writelines(diff)
    print("\nFAIL addon drift detected", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate or verify the HB resolver addon from the canonical AO resolver source."
    )
    parser.add_argument("--output", type=Path, default=ADDON_TARGET)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    content = generate()

    if args.check:
        existing = args.output.read_text(encoding="utf-8")
        return run_check(content, existing, args.output)

    write_output(content, args.output)
    print(f"Wrote generated addon: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
