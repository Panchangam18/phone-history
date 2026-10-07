#!/usr/bin/env python3
"""Convert your own remote developer record; never print its private key."""
import argparse
import os
from pathlib import Path
import plistlib
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def convert(source):
    record = plistlib.loads(source.read_bytes())
    private, public = record.get('private_key'), record.get('public_key')
    identifier = record.get('host_identifier') or record.get('identifier')
    if not isinstance(private, bytes) or len(private) != 32 or not isinstance(public, bytes) or len(public) != 32:
        raise ValueError('Expected a remote developer record with 32-byte Ed25519 keys')
    derived = Ed25519PrivateKey.from_private_bytes(private).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    if (derived != public or not isinstance(identifier, str) or not identifier
            or len(identifier.encode('utf-8')) > 256 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in identifier)):
        raise ValueError('Invalid key pair or missing host identifier')
    result = dict(private_key=private, public_key=public, identifier=identifier)
    alt = record.get('peer_alt_irk') or record.get('alt_irk')
    if alt is not None:
        if not isinstance(alt, bytes) or len(alt) != 16:
            raise ValueError('Expected binary alternate identity key')
        result['alt_irk'] = alt
    return plistlib.dumps(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    payload = convert(args.source)
    # Exclusive creation prevents overwriting an existing trust file; permissions
    # are restrictive from creation, not corrected after sensitive bytes are written.
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(payload)
    print('Validated trust record written with owner-only permissions. Import it on your own phone, then remove this temporary copy.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit('Phone History: ' + str(error))
