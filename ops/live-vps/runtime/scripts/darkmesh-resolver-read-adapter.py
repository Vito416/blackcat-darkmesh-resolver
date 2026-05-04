#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


BIND_HOST = os.environ.get("DARKMESH_RESOLVER_ADAPTER_BIND", "127.0.0.1")
PORT = int(os.environ.get("DARKMESH_RESOLVER_ADAPTER_PORT", "8760"))
STATE_DIR = os.environ.get("DARKMESH_HOST_ROUTING_STATE_DIR", "/var/lib/darkmesh/host-routing")
STATE_FILE = os.environ.get("DARKMESH_HOST_ROUTING_STATE_FILE", os.path.join(STATE_DIR, "state.json"))
ENVELOPE_FILE = os.environ.get(
    "DARKMESH_HOST_ROUTING_ENVELOPE_FILE", os.path.join(STATE_DIR, "last-envelope.json")
)
ACTIVE_PROJECTION_MODES = {"active", "stale_lkg", "lkg"}


def load_json_file(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return fallback


def normalize_host(raw_host):
    if not isinstance(raw_host, str):
        return None
    host = raw_host.strip().lower().rstrip(".")
    if ":" in host:
        name, port = host.rsplit(":", 1)
        if port.isdigit():
            host = name
    if not host or ".." in host:
        return None
    if any(ch in host for ch in "/?#@[] "):
        return None
    for ch in host:
        if not (ch.isalnum() or ch in ".-"):
            return None
    for label in host.split("."):
        if not label or len(label) > 63 or label[0] == "-" or label[-1] == "-":
            return None
    return host


def normalize_path(raw_path):
    if not isinstance(raw_path, str):
        return None
    path = raw_path.strip()
    if not path.startswith("/"):
        return None
    if len(path) > 2048:
        return None
    return path


def normalize_method(raw_method):
    if not isinstance(raw_method, str):
        return None
    method = raw_method.strip().upper()
    if not method or len(method) > 16:
        return None
    for ch in method:
        if not ("A" <= ch <= "Z"):
            return None
    return method


def host_lookup_candidates(host):
    if not host:
        return []
    candidates = [host]
    if host.startswith("www.") and len(host) > 4:
        candidates.append(host[4:])
    return candidates


def default_site_id_from_host(host):
    token = "".join(ch if ch.isalnum() else "-" for ch in (host or "").lower())
    while "--" in token:
        token = token.replace("--", "-")
    token = token.strip("-")[:96] or "host"
    return f"site-{token}"


def infer_action_hint(path, method):
    if method in {"GET", "HEAD"}:
        for prefix in ("/~process@1.0/", "/~scheduler@1.0/", "/~meta@1.0/", "/~relay@1.0/"):
            if path.startswith(prefix):
                return "control_plane"
        return "read"
    if method == "OPTIONS":
        return "preflight"
    return "write"


def with_result_envelope(payload):
    decision = payload.get("decision", "deny")
    reason = payload.get("reasonCode", "UNKNOWN")
    payload["result"] = {
        "decision": decision,
        "reasonCode": reason,
        "status": "DENY" if decision == "deny" else "ALLOW",
    }
    payload["reason"] = reason
    payload["policy"] = {
        "mode": payload.get("mode", "projection"),
        "failOpen": False,
        "enforceMode": True,
        "denyReady": reason.startswith("DENY_"),
    }
    return payload


def load_projection():
    state = load_json_file(STATE_FILE, {})
    envelope = load_json_file(ENVELOPE_FILE, {})
    entries = (((envelope or {}).get("payload") or {}).get("entries") or [])
    host_map = {}
    tx_targets = 0
    process_targets = 0

    for raw_entry in entries:
        if not isinstance(raw_entry, dict):
            continue
        if raw_entry.get("enabled", True) is False:
            continue
        raw_hosts = []
        if isinstance(raw_entry.get("hosts"), list):
            raw_hosts.extend(raw_entry.get("hosts") or [])
        if raw_entry.get("host") is not None:
            raw_hosts.append(raw_entry.get("host"))
        hosts = []
        for raw_host in raw_hosts:
            host = normalize_host(raw_host)
            if host and host not in hosts:
                hosts.append(host)
        if not hosts:
            continue
        target_type = str(raw_entry.get("targetType") or "").lower()
        path_prefix = raw_entry.get("pathPrefix") or "/"
        if target_type == "process" and raw_entry.get("targetPid"):
            process_targets += 1
        elif target_type == "tx" and raw_entry.get("targetTx"):
            tx_targets += 1
        canonical_host = normalize_host(raw_entry.get("canonicalHost")) or hosts[0]
        entry_payload = {
            "targetType": target_type,
            "targetPid": raw_entry.get("targetPid"),
            "targetTx": raw_entry.get("targetTx"),
            "pathPrefix": path_prefix,
            "cfgTx": raw_entry.get("cfgTx"),
            "txt": raw_entry.get("txt"),
            "siteId": raw_entry.get("siteId"),
            "canonicalHost": canonical_host,
        }
        for host in hosts:
            if host in host_map:
                continue
            host_map[host] = {"host": host, **entry_payload}

    return {
        "mode": state.get("mode") or "unknown",
        "reason": state.get("reason") or "",
        "updatedAt": state.get("updatedAt"),
        "signer": envelope.get("signedBy"),
        "keyId": state.get("lastKeyId") or envelope.get("keyId"),
        "sequence": state.get("lastSequence") or envelope.get("sequence"),
        "generatedAt": envelope.get("generatedAt"),
        "expiresAt": envelope.get("expiresAt"),
        "payloadHash": state.get("lastPayloadHash") or envelope.get("payloadHash"),
        "signatureAlg": envelope.get("signatureAlg"),
        "envelopeVersion": state.get("lastEnvelopeVersion") or envelope.get("version"),
        "snapshotHash": state.get("lastSnapshotHash"),
        "verifiedAt": state.get("lastVerifiedAt"),
        "verificationReason": state.get("lastVerificationReason"),
        "entries": host_map,
        "counts": {
            "entriesTotal": len(host_map),
            "hostPolicies": len(host_map),
            "txTargets": tx_targets,
            "processTargets": process_targets,
        },
    }


def lookup_entry(entries, host):
    for candidate in host_lookup_candidates(host):
        entry = entries.get(candidate)
        if entry is not None:
            return entry, candidate
    return None, None


def parse_body_json(handler):
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return None


def build_target_payload(entry):
    target = {
        "targetType": entry["targetType"],
        "pathPrefix": entry.get("pathPrefix") or "/",
    }
    if entry["targetType"] == "process":
        target["targetPid"] = entry.get("targetPid")
    elif entry["targetType"] == "tx":
        target["targetTx"] = entry.get("targetTx")
    if entry.get("cfgTx"):
        target["cfgTx"] = entry.get("cfgTx")
    return target


def build_site_payload(host, matched_host, entry):
    return {
        "siteId": entry.get("siteId") or default_site_id_from_host(matched_host or host),
        "host": host,
        "canonicalHost": entry.get("canonicalHost") or matched_host or host,
        "status": "active",
        "targetType": entry["targetType"],
    }


def build_process_payload(entry):
    if entry["targetType"] != "process":
        return None
    return {
        "processId": entry.get("targetPid"),
        "routePrefix": entry.get("pathPrefix") or "/",
    }


def projection_denied_payload(host, reason_code, extra=None):
    payload = {
        "schemaVersion": "1.0",
        "decision": "deny",
        "reasonCode": reason_code,
        "mode": "projection",
        "host": host,
        "cache": {
            "surface": "projection",
            "state": "miss",
        },
    }
    if extra:
        payload.update(extra)
    return with_result_envelope(payload)


def projection_cache_state(projection):
    mode = projection.get("mode")
    if mode == "active":
        return "active"
    if mode in {"stale_lkg", "lkg"}:
        return "stale_lkg"
    return "miss"


def projection_inactive_reason_code(projection):
    reason = str(projection.get("reason") or "")
    reason_map = {
        "invalid_signature": "DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE",
        "signature_verification_failed": "DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE",
        "payload_hash_mismatch": "DENY_FAIL_CLOSED_PROJECTION_INVALID_SIGNATURE",
        "signer_not_allowed": "DENY_FAIL_CLOSED_PROJECTION_SIGNER_NOT_ALLOWED",
        "expired": "DENY_FAIL_CLOSED_PROJECTION_EXPIRED",
        "expires_at_missing": "DENY_FAIL_CLOSED_PROJECTION_EXPIRED",
        "expires_at_invalid": "DENY_FAIL_CLOSED_PROJECTION_EXPIRED",
        "generated_at_invalid": "DENY_FAIL_CLOSED_PROJECTION_INVALID_TIME",
        "generated_at_too_far_in_future": "DENY_FAIL_CLOSED_PROJECTION_INVALID_TIME",
        "generated_at_too_old": "DENY_FAIL_CLOSED_PROJECTION_STALE",
        "rollback_rejected": "DENY_FAIL_CLOSED_PROJECTION_ROLLBACK_REJECTED",
        "sequence_below_minimum": "DENY_FAIL_CLOSED_PROJECTION_ROLLBACK_REJECTED",
        "signed_required_legacy_v1_rejected": "DENY_FAIL_CLOSED_PROJECTION_SIGNED_REQUIRED",
        "trust_manifest_missing": "DENY_FAIL_CLOSED_PROJECTION_TRUST_MISSING",
        "trust_manifest_not_found": "DENY_FAIL_CLOSED_PROJECTION_TRUST_MISSING",
        "verify_bin_not_executable": "DENY_FAIL_CLOSED_PROJECTION_VERIFY_UNAVAILABLE",
        "unsupported_envelope_version": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "unexpected_envelope_version": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "unexpected_payload_version": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "unsupported_payload_shape": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "projection_validation_failed": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "invalid_json": "DENY_FAIL_CLOSED_PROJECTION_INVALID_STATE",
        "bootstrap_unverified_not_allowed": "DENY_FAIL_CLOSED_PROJECTION_BOOTSTRAP_UNVERIFIED",
        "bootstrap_unverified_not_allowed_in_mode": "DENY_FAIL_CLOSED_PROJECTION_BOOTSTRAP_UNVERIFIED",
    }
    return reason_map.get(reason, "DENY_FAIL_CLOSED_PROJECTION_INACTIVE")


def projection_meta(projection, matched_host=None):
    payload = {
        "mode": projection.get("mode"),
        "reason": projection.get("reason"),
        "updatedAt": projection.get("updatedAt"),
        "signer": projection.get("signer"),
        "keyId": projection.get("keyId"),
        "sequence": projection.get("sequence"),
        "generatedAt": projection.get("generatedAt"),
        "expiresAt": projection.get("expiresAt"),
        "payloadHash": projection.get("payloadHash"),
        "signatureAlg": projection.get("signatureAlg"),
        "envelopeVersion": projection.get("envelopeVersion"),
        "snapshotHash": projection.get("snapshotHash"),
        "verifiedAt": projection.get("verifiedAt"),
        "verificationReason": projection.get("verificationReason"),
        "source": "nginx_host_routing_projection",
    }
    if matched_host:
        payload["matchedHost"] = matched_host
    return payload


def build_host_resolution(host, node_id=None):
    projection = load_projection()
    if projection["mode"] not in ACTIVE_PROJECTION_MODES:
        return projection_denied_payload(
            host,
            projection_inactive_reason_code(projection),
            {
                "projection": projection_meta(projection),
                "cache": {"surface": "projection", "state": projection_cache_state(projection)},
            },
        )
    entry, matched_host = lookup_entry(projection["entries"], host)
    if entry is None:
        return projection_denied_payload(
            host,
            "DENY_READY_HOST_UNMAPPED",
            {
                "projection": projection_meta(projection),
                "cache": {"surface": "projection", "state": projection_cache_state(projection)},
            },
        )

    payload = {
        "schemaVersion": "1.0",
        "decision": "allow",
        "reasonCode": "ALLOW_HOST_BOUND",
        "mode": "projection",
        "host": host,
        "nodeId": node_id,
        "target": build_target_payload(entry),
        "site": build_site_payload(host, matched_host, entry),
        "cache": {
            "surface": "projection",
            "state": projection_cache_state(projection),
            "hostKnown": True,
        },
        "projection": projection_meta(projection, matched_host or host),
    }
    process = build_process_payload(entry)
    if process is not None:
        payload["process"] = process
    return with_result_envelope(payload)


def build_route_resolution(host, path, method, node_id=None):
    projection = load_projection()
    if projection["mode"] not in ACTIVE_PROJECTION_MODES:
        return projection_denied_payload(
            host,
            projection_inactive_reason_code(projection),
            {
                "path": path,
                "method": method,
                "projection": projection_meta(projection),
                "cache": {"surface": "projection", "state": projection_cache_state(projection)},
            },
        )
    entry, matched_host = lookup_entry(projection["entries"], host)
    if entry is None:
        return projection_denied_payload(
            host,
            "DENY_READY_ROUTE_HOST_UNMAPPED",
            {
                "path": path,
                "method": method,
                "projection": projection_meta(projection),
                "cache": {"surface": "projection", "state": projection_cache_state(projection)},
            },
        )

    payload = {
        "schemaVersion": "1.0",
        "decision": "allow",
        "reasonCode": "ALLOW_ROUTE_HOST_BOUND",
        "mode": "projection",
        "host": host,
        "path": path,
        "method": method,
        "nodeId": node_id,
        "target": build_target_payload(entry),
        "site": build_site_payload(host, matched_host, entry),
        "routeHint": {
            "actionHint": infer_action_hint(path, method),
            "source": "projection",
        },
        "cache": {
            "surface": "projection",
            "state": projection_cache_state(projection),
            "hostKnown": True,
        },
        "projection": projection_meta(projection, matched_host or host),
    }
    process = build_process_payload(entry)
    if process is not None:
        payload["process"] = process
    return with_result_envelope(payload)


def build_state_payload():
    projection = load_projection()
    return {
        "schemaVersion": "1.0",
        "policyMode": "projection",
        "failOpen": False,
        "authority": "nginx_host_routing_projection",
        "counts": projection["counts"],
        "autoDns": {
            "enabled": False,
        },
        "projection": {
            "mode": projection["mode"],
            "reason": projection["reason"],
            "updatedAt": projection["updatedAt"],
            "signer": projection["signer"],
            "keyId": projection["keyId"],
            "sequence": projection["sequence"],
            "generatedAt": projection["generatedAt"],
            "expiresAt": projection["expiresAt"],
            "payloadHash": projection["payloadHash"],
            "signatureAlg": projection["signatureAlg"],
            "envelopeVersion": projection["envelopeVersion"],
            "snapshotHash": projection["snapshotHash"],
            "verifiedAt": projection["verifiedAt"],
            "verificationReason": projection["verificationReason"],
        },
        "aliases": {
            "wwwFallbackEnabled": True,
        },
    }


def build_dns_state_payload():
    projection = load_projection()
    return {
        "schemaVersion": "1.0",
        "source": "projection-only",
        "counts": {
            "trackedHosts": projection["counts"]["entriesTotal"],
            "withPendingRequest": 0,
        },
        "autoDns": {
            "enabled": False,
        },
        "projection": {
            "mode": projection["mode"],
            "reason": projection["reason"],
            "updatedAt": projection["updatedAt"],
            "generatedAt": projection["generatedAt"],
            "expiresAt": projection["expiresAt"],
        },
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "DarkmeshResolverReadAdapter/1.0"

    def _send_json(self, status, payload):
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.end_headers()
        self.wfile.write(encoded)

    def _bad_request(self, message, field=None):
        payload = {
            "status": "ERROR",
            "code": "INVALID_INPUT",
            "message": message,
        }
        if field:
            payload["field"] = field
        self._send_json(400, payload)

    def _dispatch(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = {k: v[-1] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
        body_json = {}
        if self.command in {"POST", "PUT"}:
            body_json = parse_body_json(self)
            if body_json is None:
                self._bad_request("Body must be valid JSON")
                return

        if path in ("/~darkmesh-resolver@1.0", "/~darkmesh-resolver@1.0/", "/GetResolverState", "/state", "/health"):
            self._send_json(200, build_state_payload())
            return

        if path in ("/~darkmesh-resolver@1.0/GetResolverState",):
            self._send_json(200, build_state_payload())
            return

        if path in ("/~darkmesh-resolver@1.0/GetDnsRefreshState", "/GetDnsRefreshState"):
            self._send_json(200, build_dns_state_payload())
            return

        if path in ("/~darkmesh-resolver@1.0/resolve", "/resolve", "/~darkmesh-resolver@1.0/ResolveRouteForHost", "/ResolveRouteForHost"):
            host = normalize_host(body_json.get("Host") or query.get("host") or query.get("Host"))
            route_path = normalize_path(body_json.get("Path") or query.get("path") or query.get("Path") or "/")
            method = normalize_method(body_json.get("Method") or query.get("method") or query.get("Method") or "GET")
            node_id = body_json.get("Node-Id") or body_json.get("nodeId") or query.get("Node-Id")
            if not host:
                self._bad_request("invalid_format:Host", "Host")
                return
            if not route_path:
                self._bad_request("invalid_format:Path", "Path")
                return
            if not method:
                self._bad_request("invalid_format:Method", "Method")
                return
            self._send_json(200, build_route_resolution(host, route_path, method, node_id=node_id))
            return

        if path in ("/~darkmesh-resolver@1.0/ResolveHostForNode", "/ResolveHostForNode"):
            host = normalize_host(body_json.get("Host") or query.get("host") or query.get("Host"))
            node_id = body_json.get("Node-Id") or body_json.get("nodeId") or query.get("Node-Id")
            if not host:
                self._bad_request("invalid_format:Host", "Host")
                return
            self._send_json(200, build_host_resolution(host, node_id=node_id))
            return

        self._send_json(404, {"status": "ERROR", "code": "NOT_FOUND", "message": "Not Found"})

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        return


def main():
    server = ThreadingHTTPServer((BIND_HOST, PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
