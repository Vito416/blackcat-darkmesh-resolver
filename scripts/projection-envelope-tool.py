#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


class ProjectionToolError(Exception):
    pass


@dataclass
class VerifyResult:
    ok: bool
    reason: str
    envelope_version: str | None = None
    snapshot_id: str | None = None
    sequence: int | None = None
    signer: str | None = None
    key_id: str | None = None
    signature_alg: str | None = None
    payload_hash: str | None = None
    computed_payload_hash: str | None = None

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "ok": self.ok,
            "reason": self.reason,
        }
        if self.envelope_version is not None:
            out["envelopeVersion"] = self.envelope_version
        if self.snapshot_id is not None:
            out["snapshotId"] = self.snapshot_id
        if self.sequence is not None:
            out["sequence"] = self.sequence
        if self.signer is not None:
            out["signer"] = self.signer
        if self.key_id is not None:
            out["keyId"] = self.key_id
        if self.signature_alg is not None:
            out["signatureAlg"] = self.signature_alg
        if self.payload_hash is not None:
            out["payloadHash"] = self.payload_hash
        if self.computed_payload_hash is not None:
            out["computedPayloadHash"] = self.computed_payload_hash
        return out


def load_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def dump_json(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def parse_rfc3339(value: str) -> datetime:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        dt = datetime.fromisoformat(value)
    except ValueError as exc:
        raise ProjectionToolError(f"invalid_rfc3339:{value}") from exc
    if dt.tzinfo is None:
        raise ProjectionToolError(f"invalid_rfc3339_no_tz:{value}")
    return dt.astimezone(timezone.utc)


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def decode_base64_value(value: str) -> bytes:
    raw = value.strip()
    if raw.startswith("base64:"):
        raw = raw[len("base64:") :]
    try:
        return base64.b64decode(raw, validate=True)
    except Exception as exc:
        raise ProjectionToolError("invalid_base64") from exc


def load_public_key(value: str) -> Ed25519PublicKey:
    text = value.strip()
    if text.startswith("-----BEGIN"):
        key = serialization.load_pem_public_key(text.encode("utf-8"))
        if not isinstance(key, Ed25519PublicKey):
            raise ProjectionToolError("unsupported_public_key_type")
        return key
    key_bytes = decode_base64_value(text)
    try:
        return Ed25519PublicKey.from_public_bytes(key_bytes)
    except Exception as exc:
        raise ProjectionToolError("invalid_ed25519_public_key") from exc


def load_private_key_from_file(path: str) -> Ed25519PrivateKey:
    text = read_text(path)
    if text.startswith("-----BEGIN"):
        key = serialization.load_pem_private_key(text.encode("utf-8"), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ProjectionToolError("unsupported_private_key_type")
        return key
    key_bytes = decode_base64_value(text)
    try:
        return Ed25519PrivateKey.from_private_bytes(key_bytes)
    except Exception as exc:
        raise ProjectionToolError("invalid_ed25519_private_key") from exc


def normalize_scalar_for_key(key: str, value: Any) -> Any:
    if isinstance(value, str):
        if key in {"host", "canonicalHost"}:
            return value.lower()
        if key == "pathPrefix":
            return value or "/"
    if key == "hosts" and isinstance(value, list):
        return [item.lower() if isinstance(item, str) else item for item in value]
    return value


def canonicalize_value(value: Any, parent_key: str | None = None) -> Any:
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key in sorted(value.keys()):
            out[key] = canonicalize_value(value[key], key)
        return out
    if isinstance(value, list):
        return [canonicalize_value(item, parent_key) for item in value]
    return normalize_scalar_for_key(parent_key or "", value)


def extract_payload(doc: Any) -> Any:
    if isinstance(doc, dict) and "payload" in doc and isinstance(doc["payload"], dict):
        return doc["payload"]
    if isinstance(doc, dict):
        return doc
    raise ProjectionToolError("payload_not_object")


def canonical_payload_bytes_from_doc(doc: Any) -> bytes:
    payload = extract_payload(doc)
    canonical_payload = canonicalize_value(payload)
    text = json.dumps(canonical_payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return text.encode("utf-8")


def hash_payload_bytes(payload_bytes: bytes) -> str:
    return "sha256:" + hashlib.sha256(payload_bytes).hexdigest()


def ensure_envelope_v2(envelope: Any) -> dict[str, Any]:
    if not isinstance(envelope, dict):
        raise ProjectionToolError("envelope_not_object")
    version = envelope.get("version")
    if version != "dm-hostmap-envelope.v2":
        raise ProjectionToolError(f"unsupported_envelope_version:{version}")
    if not isinstance(envelope.get("payload"), dict):
        raise ProjectionToolError("missing_payload")
    return envelope


def ensure_trust_manifest(manifest: Any) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise ProjectionToolError("trust_manifest_not_object")
    if manifest.get("schemaVersion") != "dm-projection-trust/1":
        raise ProjectionToolError("unsupported_trust_manifest_version")
    return manifest


def verify_envelope(envelope: dict[str, Any], manifest: dict[str, Any]) -> VerifyResult:
    version = envelope.get("version")
    snapshot_id = envelope.get("snapshotId")
    sequence = envelope.get("sequence")
    signer = envelope.get("signedBy")
    key_id = envelope.get("keyId")
    signature_alg = envelope.get("signatureAlg")
    payload_hash = envelope.get("payloadHash")

    result = VerifyResult(
        ok=False,
        reason="unknown",
        envelope_version=version if isinstance(version, str) else None,
        snapshot_id=snapshot_id if isinstance(snapshot_id, str) else None,
        sequence=sequence if isinstance(sequence, int) else None,
        signer=signer if isinstance(signer, str) else None,
        key_id=key_id if isinstance(key_id, str) else None,
        signature_alg=signature_alg if isinstance(signature_alg, str) else None,
        payload_hash=payload_hash if isinstance(payload_hash, str) else None,
    )

    try:
        ensure_envelope_v2(envelope)
        ensure_trust_manifest(manifest)
    except ProjectionToolError as exc:
        result.reason = str(exc)
        return result

    if signer not in manifest.get("allowedSigners", []):
        result.reason = "signer_not_allowed"
        return result

    if not isinstance(sequence, int):
        result.reason = "invalid_sequence"
        return result
    if sequence < int(manifest.get("minSequence", 0)):
        result.reason = "sequence_below_minimum"
        return result

    payload_bytes = canonical_payload_bytes_from_doc(envelope)
    computed_hash = hash_payload_bytes(payload_bytes)
    result.computed_payload_hash = computed_hash
    if payload_hash != computed_hash:
        result.reason = "payload_hash_mismatch"
        return result

    now = datetime.now(timezone.utc)
    max_future_skew = int(manifest.get("maxFutureSkewSec", 0))
    max_past_age = int(manifest.get("maxPastAgeSec", 0))

    generated_at = envelope.get("generatedAt")
    expires_at = envelope.get("expiresAt")
    if not isinstance(generated_at, str):
        result.reason = "generated_at_missing"
        return result
    try:
        generated_dt = parse_rfc3339(generated_at)
    except ProjectionToolError as exc:
        result.reason = str(exc)
        return result

    if generated_dt.timestamp() - now.timestamp() > max_future_skew:
        result.reason = "generated_at_too_far_in_future"
        return result

    if max_past_age > 0 and now.timestamp() - generated_dt.timestamp() > max_past_age:
        result.reason = "generated_at_too_old"
        return result

    require_expiry = bool(manifest.get("requireExpiry", True))
    expires_dt: datetime | None = None
    if expires_at is not None:
        if not isinstance(expires_at, str):
            result.reason = "expires_at_invalid"
            return result
        try:
            expires_dt = parse_rfc3339(expires_at)
        except ProjectionToolError as exc:
            result.reason = str(exc)
            return result
        if expires_dt <= generated_dt:
            result.reason = "expires_before_generated"
            return result
        if now >= expires_dt:
            result.reason = "expired"
            return result
    elif require_expiry:
        result.reason = "expires_at_missing"
        return result

    if signature_alg == "bootstrap-none":
        if not bool(manifest.get("allowBootstrapUnverified", False)):
            result.reason = "bootstrap_unverified_not_allowed"
            return result
        if manifest.get("mode") != "bootstrap":
            result.reason = "bootstrap_unverified_not_allowed_in_mode"
            return result
        result.ok = True
        result.reason = "ok_bootstrap_unverified"
        return result

    if signature_alg != "ed25519":
        result.reason = "unsupported_signature_alg"
        return result

    key_meta = manifest.get("keys", {}).get(key_id)
    if not isinstance(key_meta, dict):
        result.reason = "key_not_found"
        return result
    if key_meta.get("alg") != "ed25519":
        result.reason = "key_alg_mismatch"
        return result
    if key_meta.get("status", "active") != "active":
        result.reason = "key_not_active"
        return result

    if isinstance(key_meta.get("notBefore"), str):
        try:
            if now < parse_rfc3339(key_meta["notBefore"]):
                result.reason = "key_not_yet_valid"
                return result
        except ProjectionToolError as exc:
            result.reason = str(exc)
            return result
    if isinstance(key_meta.get("notAfter"), str):
        try:
            if now >= parse_rfc3339(key_meta["notAfter"]):
                result.reason = "key_expired"
                return result
        except ProjectionToolError as exc:
            result.reason = str(exc)
            return result

    signature_value = envelope.get("signature")
    if not isinstance(signature_value, str):
        result.reason = "signature_missing"
        return result

    try:
        public_key = load_public_key(str(key_meta.get("publicKey", "")))
        signature_bytes = decode_base64_value(signature_value)
        public_key.verify(signature_bytes, payload_bytes)
    except ProjectionToolError as exc:
        result.reason = str(exc)
        return result
    except InvalidSignature:
        result.reason = "invalid_signature"
        return result
    except Exception:
        result.reason = "signature_verification_failed"
        return result

    result.ok = True
    result.reason = "ok"
    return result


def cmd_canonicalize(args: argparse.Namespace) -> int:
    doc = load_json(args.input)
    sys.stdout.buffer.write(canonical_payload_bytes_from_doc(doc))
    if sys.stdout.isatty():
        sys.stdout.write("\n")
    return 0


def cmd_hash(args: argparse.Namespace) -> int:
    doc = load_json(args.input)
    sys.stdout.write(hash_payload_bytes(canonical_payload_bytes_from_doc(doc)) + "\n")
    return 0


def cmd_sign(args: argparse.Namespace) -> int:
    envelope = ensure_envelope_v2(load_json(args.input))
    private_key = load_private_key_from_file(args.private_key_file)
    signed = copy.deepcopy(envelope)
    if isinstance(signed.get("payload"), dict) and isinstance(signed["payload"].get("authority"), dict):
        signed["payload"]["authority"]["mode"] = "signed"
    payload_bytes = canonical_payload_bytes_from_doc(signed)
    signed["signedBy"] = args.signed_by
    signed["keyId"] = args.key_id
    signed["signatureAlg"] = "ed25519"
    signed["payloadHash"] = hash_payload_bytes(payload_bytes)
    signature = private_key.sign(payload_bytes)
    signed["signature"] = "base64:" + base64.b64encode(signature).decode("ascii")
    output = dump_json(signed)
    if args.output:
        Path(args.output).write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    envelope = load_json(args.envelope)
    manifest = load_json(args.trust_manifest)
    result = verify_envelope(envelope, manifest)
    sys.stdout.write(dump_json(result.to_json()))
    return 0 if result.ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="DarkMesh signed projection envelope helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_canonicalize = subparsers.add_parser("canonicalize", help="write canonical payload bytes to stdout")
    p_canonicalize.add_argument("input", help="Envelope JSON file or '-' for stdin")
    p_canonicalize.set_defaults(func=cmd_canonicalize)

    p_hash = subparsers.add_parser("hash", help="hash canonical payload as sha256:<hex>")
    p_hash.add_argument("input", help="Envelope JSON file or '-' for stdin")
    p_hash.set_defaults(func=cmd_hash)

    p_sign = subparsers.add_parser("sign", help="sign a dm-hostmap-envelope.v2 payload with ed25519")
    p_sign.add_argument("input", help="Unsigned envelope JSON file")
    p_sign.add_argument("--private-key-file", required=True, help="PEM or base64 raw ed25519 private key")
    p_sign.add_argument("--signed-by", required=True, help="Signer id to stamp into the envelope")
    p_sign.add_argument("--key-id", required=True, help="Key id to stamp into the envelope")
    p_sign.add_argument("--output", help="Output file path (defaults to stdout)")
    p_sign.set_defaults(func=cmd_sign)

    p_verify = subparsers.add_parser("verify", help="verify a signed envelope against a trust manifest")
    p_verify.add_argument("envelope", help="Signed envelope JSON file")
    p_verify.add_argument("trust_manifest", help="Trust manifest JSON file")
    p_verify.set_defaults(func=cmd_verify)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except ProjectionToolError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
