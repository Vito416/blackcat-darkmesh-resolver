#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def dump_json(data: object) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description='Generate off-node DarkMesh projection signing material')
    parser.add_argument('--output-dir', required=True, help='Directory for generated key + trust files')
    parser.add_argument('--signed-by', required=True, help='Signer id, e.g. darkmesh-resolver-mainnet')
    parser.add_argument('--key-id', required=True, help='Key id, e.g. darkmesh-projection-key-2026-q2')
    parser.add_argument('--not-before', required=True, help='RFC3339 UTC timestamp')
    parser.add_argument('--not-after', required=True, help='RFC3339 UTC timestamp')
    parser.add_argument('--mode', default='production', choices=['production', 'bootstrap'])
    parser.add_argument('--max-future-skew-sec', type=int, default=120)
    parser.add_argument('--max-past-age-sec', type=int, default=900)
    parser.add_argument('--min-sequence', type=int, default=0)
    parser.add_argument('--allow-bootstrap-unverified', action='store_true')
    args = parser.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()

    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    public_b64 = base64.b64encode(public_bytes).decode('ascii')

    trust_manifest = {
        'schemaVersion': 'dm-projection-trust/1',
        'mode': args.mode,
        'allowedSigners': [args.signed_by],
        'keys': {
            args.key_id: {
                'alg': 'ed25519',
                'publicKey': f'base64:{public_b64}',
                'status': 'active',
                'notBefore': args.not_before,
                'notAfter': args.not_after,
            }
        },
        'requireExpiry': True,
        'maxFutureSkewSec': args.max_future_skew_sec,
        'maxPastAgeSec': args.max_past_age_sec,
        'allowRollback': False,
        'minSequence': args.min_sequence,
        'allowBootstrapUnverified': bool(args.allow_bootstrap_unverified),
        'notes': 'Generated off-node for async-worker resolver projection signing.',
    }

    env_snippet = (
        f'RESOLVER_SIGNER_SIGNED_BY={args.signed_by}\n'
        f'RESOLVER_SIGNER_KEY_ID={args.key_id}\n'
    )

    private_key_path = out_dir / 'projection-signing-key.pem'
    public_key_path = out_dir / 'projection-signing-key.public.base64.txt'
    trust_manifest_path = out_dir / 'projection-trust.json'
    env_snippet_path = out_dir / 'async-worker-vars.env'

    private_key_path.write_bytes(private_pem)
    public_key_path.write_text(f'base64:{public_b64}\n', encoding='utf-8')
    trust_manifest_path.write_text(dump_json(trust_manifest), encoding='utf-8')
    env_snippet_path.write_text(env_snippet, encoding='utf-8')

    print(f'generated: {private_key_path}')
    print(f'generated: {public_key_path}')
    print(f'generated: {trust_manifest_path}')
    print(f'generated: {env_snippet_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
