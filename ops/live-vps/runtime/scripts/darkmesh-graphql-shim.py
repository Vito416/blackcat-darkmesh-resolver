#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import pathlib
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_BIND_HOST = os.environ.get("DARKMESH_GRAPHQL_SHIM_BIND_HOST", "127.0.0.1")
DEFAULT_BIND_PORT = int(os.environ.get("DARKMESH_GRAPHQL_SHIM_BIND_PORT", "18777"))
ALLOWLIST_FILE = pathlib.Path(os.environ.get("DARKMESH_GRAPHQL_SHIM_ALLOWLIST_FILE", "/etc/darkmesh/graphql-shim-allowlist.txt"))
CACHE_DIR = pathlib.Path(os.environ.get("DARKMESH_GRAPHQL_SHIM_CACHE_DIR", "/var/cache/darkmesh-graphql-shim"))
UPSTREAM_GRAPHQL_URL = os.environ.get("DARKMESH_GRAPHQL_SHIM_UPSTREAM_GRAPHQL_URL", "https://arweave.net/graphql")
TX_BASE_URL = os.environ.get("DARKMESH_GRAPHQL_SHIM_TX_BASE_URL", "https://arweave.net")
PROXY_MISSES = os.environ.get("DARKMESH_GRAPHQL_SHIM_PROXY_MISSES", "0").strip().lower() in {"1", "true", "yes", "on"}
PROXY_UNSUPPORTED = os.environ.get("DARKMESH_GRAPHQL_SHIM_PROXY_UNSUPPORTED", "1").strip().lower() in {"1", "true", "yes", "on"}
CACHE_TTL_SEC = int(os.environ.get("DARKMESH_GRAPHQL_SHIM_CACHE_TTL_SEC", "86400"))
REQUEST_TIMEOUT_SEC = float(os.environ.get("DARKMESH_GRAPHQL_SHIM_REQUEST_TIMEOUT_SEC", "15"))
USER_AGENT = os.environ.get("DARKMESH_GRAPHQL_SHIM_USER_AGENT", "darkmesh-graphql-shim/1.0")

GET_PROCESSES_QUERY = """
query GetProcesses (
  $processIds: [ID!]!
  $skipTags: Boolean!
  $skipSignature: Boolean!
  $skipAnchor: Boolean!
) {
  transactions(ids: $processIds) {
    edges {
      node {
        id
        signature @skip (if: $skipSignature)
        anchor @skip (if: $skipAnchor)
        owner {
          address
          key
        }
        tags @skip (if: $skipTags) {
          name
          value
        }
        recipient
      }
    }
  }
}
""".strip()


def json_response(handler, status, payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def load_allowlist():
    if not ALLOWLIST_FILE.exists():
        return set()
    ids = set()
    for raw_line in ALLOWLIST_FILE.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        ids.add(line)
    return ids


def b64url_decode(value):
    if value is None:
        return b""
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode((value + padding).encode("ascii"))


def b64url_encode(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def decode_tag_value(value):
    if value is None:
        return ""
    try:
        decoded = b64url_decode(value)
        return decoded.decode("utf-8")
    except Exception:
        return value


def owner_address_from_key(owner_key):
    try:
        digest = hashlib.sha256(b64url_decode(owner_key)).digest()
        return b64url_encode(digest)
    except Exception:
        return ""


def cache_path_for(txid):
    return CACHE_DIR / f"{txid}.json"


def load_cached_tx(txid):
    path = cache_path_for(txid)
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    fetched_at = float(payload.get("fetchedAt", 0))
    if CACHE_TTL_SEC > 0 and time.time() - fetched_at > CACHE_TTL_SEC:
        return None
    return payload.get("tx")


def store_cached_tx(txid, tx):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {"fetchedAt": time.time(), "tx": tx}
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(CACHE_DIR), delete=False) as tmp:
        json.dump(payload, tmp, separators=(",", ":"))
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp_path = pathlib.Path(tmp.name)
    tmp_path.replace(cache_path_for(txid))


def tx_url(txid):
    return urllib.parse.urljoin(TX_BASE_URL.rstrip("/") + "/", f"tx/{txid}")


def fetch_json(url, payload=None):
    data = None
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    method = "GET"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SEC) as res:
        return json.loads(res.read().decode("utf-8"))


def fetch_tx(txid):
    cached = load_cached_tx(txid)
    if cached is not None:
        return cached
    try:
        tx = fetch_json(tx_url(txid))
        if isinstance(tx, dict) and tx.get("id") == txid:
            store_cached_tx(txid, tx)
            return tx
    except Exception:
        pass
    path = cache_path_for(txid)
    if path.exists():
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            return payload.get("tx")
        except Exception:
            return None
    return None


def tx_to_graphql_node(tx, *, skip_tags=False, skip_signature=False, skip_anchor=False):
    owner_key = tx.get("owner", "")
    node = {
        "id": tx.get("id", ""),
        "owner": {
            "address": owner_address_from_key(owner_key),
            "key": owner_key,
        },
        "recipient": tx.get("target", "") or "",
    }
    if not skip_signature:
        node["signature"] = tx.get("signature", "")
    if not skip_anchor:
        node["anchor"] = tx.get("last_tx", "")
    if not skip_tags:
        node["tags"] = [
            {
                "name": decode_tag_value(tag.get("name")),
                "value": decode_tag_value(tag.get("value")),
            }
            for tag in tx.get("tags", [])
        ]
    return node


def empty_transactions_response():
    return {"data": {"transactions": {"edges": []}}}


def extract_process_ids(body):
    variables = body.get("variables") or {}
    ids = variables.get("processIds")
    if isinstance(ids, list):
        return ids, "processIds"
    ids = variables.get("ids")
    if isinstance(ids, list):
        return ids, "ids"
    return None, None


def upstream_query(body, ids_key=None, ids=None):
    upstream_body = body
    if ids_key is not None and ids is not None:
        upstream_body = dict(body)
        upstream_variables = dict(body.get("variables") or {})
        upstream_variables[ids_key] = ids
        upstream_body["variables"] = upstream_variables
    return fetch_json(UPSTREAM_GRAPHQL_URL, upstream_body)


def merge_edges(requested_ids, local_edges, upstream_edges):
    local_by_id = {edge.get("node", {}).get("id"): edge for edge in local_edges if edge.get("node", {}).get("id")}
    upstream_by_id = {edge.get("node", {}).get("id"): edge for edge in upstream_edges if edge.get("node", {}).get("id")}
    edges = []
    for txid in requested_ids:
        edge = local_by_id.get(txid) or upstream_by_id.get(txid)
        if edge is not None:
            edges.append(edge)
    return edges


class GraphQLShimHandler(BaseHTTPRequestHandler):
    server_version = "DarkMeshGraphQLShim/1.0"

    def do_GET(self):
        if self.path in {"/health", "/healthz"}:
            json_response(self, HTTPStatus.OK, {
                "ok": True,
                "service": "darkmesh-graphql-shim",
                "bind": f"{DEFAULT_BIND_HOST}:{DEFAULT_BIND_PORT}",
                "allowlistFile": str(ALLOWLIST_FILE),
                "upstreamGraphqlUrl": UPSTREAM_GRAPHQL_URL,
                "txBaseUrl": TX_BASE_URL,
                "proxyMisses": PROXY_MISSES,
                "proxyUnsupported": PROXY_UNSUPPORTED,
            })
            return
        if self.path == "/allowlist":
            json_response(self, HTTPStatus.OK, {"ids": sorted(load_allowlist())})
            return
        json_response(self, HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/graphql":
            json_response(self, HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        try:
            raw = self.rfile.read(length) if length > 0 else b"{}"
            body = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            json_response(self, HTTPStatus.BAD_REQUEST, {"error": "invalid_json", "detail": str(exc)})
            return

        requested_ids, ids_key = extract_process_ids(body)
        allowlist = load_allowlist()
        if requested_ids is None:
            if PROXY_UNSUPPORTED:
                try:
                    payload = upstream_query(body)
                except urllib.error.HTTPError as exc:
                    detail = exc.read().decode("utf-8", errors="replace")
                    json_response(self, exc.code, {"error": "upstream_error", "detail": detail})
                    return
                except Exception as exc:
                    json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "upstream_error", "detail": str(exc)})
                    return
                json_response(self, HTTPStatus.OK, payload)
                return
            json_response(self, HTTPStatus.OK, empty_transactions_response())
            return

        skip_tags = bool((body.get("variables") or {}).get("skipTags", False))
        skip_signature = bool((body.get("variables") or {}).get("skipSignature", False))
        skip_anchor = bool((body.get("variables") or {}).get("skipAnchor", False))

        local_edges = []
        missing_ids = []
        for txid in requested_ids:
            if txid in allowlist:
                tx = fetch_tx(txid)
                if tx is not None:
                    local_edges.append({"node": tx_to_graphql_node(tx, skip_tags=skip_tags, skip_signature=skip_signature, skip_anchor=skip_anchor)})
                    continue
            missing_ids.append(txid)

        upstream_edges = []
        if missing_ids and PROXY_MISSES:
            try:
                upstream_payload = upstream_query(body, ids_key=ids_key, ids=missing_ids)
                upstream_edges = (((upstream_payload or {}).get("data") or {}).get("transactions") or {}).get("edges") or []
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")
                json_response(self, exc.code, {"error": "upstream_error", "detail": detail})
                return
            except Exception as exc:
                json_response(self, HTTPStatus.BAD_GATEWAY, {"error": "upstream_error", "detail": str(exc)})
                return

        edges = merge_edges(requested_ids, local_edges, upstream_edges)
        json_response(self, HTTPStatus.OK, {"data": {"transactions": {"edges": edges}}})

    def log_message(self, fmt, *args):
        syslog = os.environ.get("DARKMESH_GRAPHQL_SHIM_STDERR", "1").strip().lower() in {"1", "true", "yes", "on"}
        if syslog:
            super().log_message(fmt, *args)


def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((DEFAULT_BIND_HOST, DEFAULT_BIND_PORT), GraphQLShimHandler)
    print(json.dumps({
        "service": "darkmesh-graphql-shim",
        "bind": f"{DEFAULT_BIND_HOST}:{DEFAULT_BIND_PORT}",
        "allowlistFile": str(ALLOWLIST_FILE),
        "upstreamGraphqlUrl": UPSTREAM_GRAPHQL_URL,
        "txBaseUrl": TX_BASE_URL,
        "proxyMisses": PROXY_MISSES,
        "proxyUnsupported": PROXY_UNSUPPORTED,
    }))
    server.serve_forever()


if __name__ == "__main__":
    main()
