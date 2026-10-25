#!/usr/bin/python3
"""Measure retention on an entirely synthetic, disposable shared-chunk archive."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time
import resource
from unittest.mock import patch

import continuous_backup as base
import snapshot_chunks as chunks


def benchmark(snapshot_count=256, chunk_count=2048):
    if (not 1 <= snapshot_count <= 500 or not 1 <= chunk_count <= 4096
            or snapshot_count * chunk_count > 600_000):
        raise ValueError('Synthetic benchmark exceeds its bounded input budget')
    with tempfile.TemporaryDirectory(prefix='uten-dr-retention-benchmark-') as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        storage = root / 'storage'
        storage.mkdir(mode=0o700)
        objects = storage / 'objects'
        points = storage / 'snapshots'
        objects.mkdir(mode=0o700)
        points.mkdir(mode=0o700)
        timestamp = base.now().isoformat()
        stamp = base.now().strftime('%Y%m%dT%H%M%SZ')
        cipher = b'SYNTHETIC-CIPHERTEXT-BENCHMARK-ONLY' * 4
        checksum = hashlib.sha256(cipher).hexdigest()
        references = []
        for index in range(chunk_count):
            name = f'{index:064x}'
            directory = objects / name
            directory.mkdir(mode=0o700)
            (directory / 'cipher.gpg').write_bytes(cipher)
            (directory / 'cipher.gpg').chmod(0o600)
            value = {'format': chunks.FORMAT, 'opaqueId': name, 'cipherSha256': checksum,
                     'cipherBytes': len(cipher), 'receivedAt': timestamp}
            base.atomic_json(directory / 'receipt.json', value)
            references.append({key: value[key] for key in ('opaqueId', 'cipherSha256', 'cipherBytes')})
        reference_bytes = chunks.canonical(references)
        reference_digest = hashlib.sha256(reference_bytes).hexdigest()
        for index in range(snapshot_count):
            identity = f'{stamp}-{index:012x}'
            name = 'snapshot-' + identity
            directory = points / name
            directory.mkdir(mode=0o700)
            for filename, raw in (('manifest.gpg', cipher), ('references.json', reference_bytes)):
                path = directory / filename
                path.write_bytes(raw)
                path.chmod(0o600)
            receipt = {'format': chunks.FORMAT, 'state': 'SNAPSHOT_CIPHERTEXT_COMPLETE',
                'snapshotId': name, 'sourceSetId': identity, 'sourceSnapshotAt': timestamp,
                'sourceManifestSha256': checksum, 'manifestCipherSha256': checksum,
                'manifestCipherBytes': len(cipher), 'referenceListSha256': reference_digest,
                'receivedAt': timestamp}
            base.atomic_json(directory / 'target-receipt.json', receipt)
        config = {'storage_root': str(storage), 'status_file': str(root / 'status.json'),
            'recipient_fingerprint': 'A' * 40, 'max_archive_bytes': 1024**3,
            'max_storage_bytes': 1024**4, 'min_free_bytes': 0,
            'hourly_retention_days': 7, 'daily_retention_days': 30, 'minimum_complete_sets': 3}
        with patch.object(base, 'chunks_module', return_value=chunks), \
                patch.object(chunks, 'object_record', wraps=chunks.object_record) as records:
            started = time.monotonic()
            result = base.retain(config)
            elapsed = time.monotonic() - started
        if result['completedSnapshots'] != snapshot_count or records.call_count != chunk_count:
            raise AssertionError('Synthetic retention failed shared closure validation')
        if len(result['snapshotRecoveryPoints']) != min(snapshot_count, chunks.CATALOG_WINDOW):
            raise AssertionError('Catalog output escaped its fixed metadata window')
        return {'state': 'SYNTHETIC_RETENTION_BENCHMARK_PASSED', 'snapshots': snapshot_count,
            'totalReferences': snapshot_count * chunk_count, 'uniqueChunks': chunk_count,
            'objectMetadataReads': records.call_count, 'elapsedSeconds': round(elapsed, 3),
            'returnedRecoveryPoints': len(result['snapshotRecoveryPoints']),
            'deletedSnapshots': result['lastRetention']['deletedSnapshots'],
            'deletedUnreferencedChunks': result['lastRetention']['deletedUnreferencedChunks'],
            'productionPathsAccepted': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshots', type=int, default=256)
    parser.add_argument('--chunks', type=int, default=2048)
    parser.add_argument('--memory-limit-mib', type=int)
    args = parser.parse_args()
    if args.memory_limit_mib is not None:
        if not 96 <= args.memory_limit_mib <= 4096:
            raise ValueError('Invalid isolated benchmark address-space limit')
        ceiling = args.memory_limit_mib * 1024**2
        resource.setrlimit(resource.RLIMIT_AS, (ceiling, ceiling))
    print(json.dumps(benchmark(args.snapshots, args.chunks)))
