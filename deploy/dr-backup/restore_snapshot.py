#!/usr/bin/python3
"""Verify source signature, reconstruct opaque encrypted chunks in RAM, and drill restore."""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import io
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile

def sibling(name):
    spec=importlib.util.spec_from_file_location('uten_recovery_'+name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
    return module


base=sibling('continuous_backup')
chunks=sibling('snapshot_chunks')
restore_drill=sibling('restore_drill')
remote_spec=importlib.util.spec_from_file_location('uten_remote_recovery_catalog',
    Path(__file__).resolve().parents[1]/'postgres/backup/remote_recovery_catalog.py')
remote_catalog=importlib.util.module_from_spec(remote_spec);remote_spec.loader.exec_module(remote_catalog)


def reconstruct(manifest, references, read_plain, receipt):
    expected = {"format", "snapshotId", "nonce", "sourceSetId", "sourceSnapshotAt", "sourceManifestSha256",
        "recipientFingerprint", "referenceListSha256", "chunkBytes", "dedupIdentityKeyRecovery", "files", "scope"}
    if not isinstance(manifest,dict) or set(manifest)!=expected or manifest["format"]!=chunks.FORMAT:
        raise ValueError("Invalid decrypted snapshot manifest")
    for key in ("snapshotId","nonce","sourceSetId","sourceSnapshotAt","sourceManifestSha256",
                "recipientFingerprint","referenceListSha256"):
        if manifest[key]!=receipt[key]:raise ValueError("Snapshot nonce/identity binding differs")
    if hashlib.sha256(chunks.canonical(references)).hexdigest()!=manifest["referenceListSha256"]:
        raise ValueError("Snapshot reference closure differs")
    secret=base64.b64decode(manifest['dedupIdentityKeyRecovery'],validate=True)
    if len(secret)!=32 or manifest['chunkBytes']!=chunks.CHUNK_BYTES:raise ValueError("Invalid chunk identity recovery")
    if manifest['scope'].get('cryptoRecoveryIncluded') is not True:raise ValueError("Missing crypto recovery scope")
    available={row['opaqueId'] for row in references};used=set();cache={};contents={};total=0
    prefix='paired/'+manifest['sourceSetId']+'/'
    allowed_recovery={'recovery/'+name for name in (
        'etc/uten-imp/server.env','etc/uten-imp/migrator.env','etc/uten-imp/paired-internal-backup.json',
        'etc/pgbackrest.conf','etc/pgbackrest/conf.d/20-uten-imp-repo2.conf')}
    allowed_tools={'restore-tools/'+name for name in (
        'paired_internal_backup.py','market_state_backup.py','client_release_state_backup.py')}
    if not isinstance(manifest['files'],list) or not 1<=len(manifest['files'])<=200000:
        raise ValueError("Snapshot file inventory is invalid")
    for row in manifest['files']:
        if not isinstance(row,dict) or set(row)!={'path','size','sha256','chunks'}:raise ValueError("Invalid snapshot file")
        name=row['path'];path=PurePosixPath(name)
        if (not isinstance(name,str) or path.is_absolute() or str(path)!=name or '..' in path.parts
                or not (name.startswith(prefix) or name in allowed_recovery or name in allowed_tools
                    or name.startswith('recovery/') and remote_catalog.allowed(name[9:]))
                or name in contents or type(row['size']) is not int or not 0<=row['size']<=512*1024**2
                or not base.HASH.fullmatch(row['sha256']) or not isinstance(row['chunks'],list)):
            raise ValueError("Unreviewed snapshot file path or identity")
        if total+row['size']>512*1024**2 or len(row['chunks'])>1024:
            raise ValueError("Reconstructed snapshot memory budget exceeded")
        parts=[]
        for part in row['chunks']:
            if (not isinstance(part,dict) or set(part)!={'opaqueId','size','sha256'}
                    or part['opaqueId'] not in available or type(part['size']) is not int
                    or not 0<part['size']<=chunks.CHUNK_BYTES or not base.HASH.fullmatch(part['sha256'])):
                raise ValueError("Invalid ordered chunk reference")
            opaque=part['opaqueId'];used.add(opaque)
            if opaque not in cache:cache[opaque]=read_plain(opaque)
            raw=cache[opaque]
            if (len(raw)!=part['size'] or hashlib.sha256(raw).hexdigest()!=part['sha256']
                    or not hmac.compare_digest(chunks.identity(secret,raw),opaque)):
                raise ValueError("Decrypted chunk content/identity/order differs")
            parts.append(raw)
        value=b''.join(parts);total+=len(value)
        if (len(value)!=row['size'] or hashlib.sha256(value).hexdigest()!=row['sha256']
                or total>512*1024**2):raise ValueError("Reconstructed file or memory budget failed")
        contents[name]=value
    if used!=available:raise ValueError("Unbound or missing snapshot dependency")
    remote=manifest['scope'].get('remoteGatewayRecovery')
    if remote is None and any(name.startswith('recovery/') and remote_catalog.allowed(name[9:]) for name in contents):
        raise ValueError('Remote recovery files lack their complete catalog')
    if remote is not None:remote_catalog.validate_metadata(remote,set(contents))
    if ('recovery/etc/uten-imp/server.env' not in contents or prefix+'database.dump' not in contents
            or hashlib.sha256(contents[prefix+'manifest.json']).hexdigest()!=receipt['sourceManifestSha256']):
        raise ValueError("Required paired/crypto manifest binding failed")
    return contents


def read_bundle(path):
    result={};total=0
    fixed={'manifest.gpg','references.json','target-receipt.json','source-receipt.json','source-signature.sshsig'}
    with tarfile.open(path,mode='r|') as archive:
        for member in archive:
            if (not member.isfile() or member.name in result or member.size<0
                    or not (member.name in fixed or re.fullmatch(r'objects/[a-f0-9]{64}\.gpg',member.name))):
                raise ValueError("Invalid ciphertext bundle member")
            total+=member.size
            if total>512*1024**2:raise ValueError("Ciphertext bundle exceeds memory budget")
            result[member.name]=archive.extractfile(member).read()
    if not fixed.issubset(result):raise ValueError("Ciphertext bundle metadata is incomplete")
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('bundle','allowed-signers','gpg-home','docker','report'):
        parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--expected-source-set-id',required=True)
    parser.add_argument('--expected-manifest-sha',required=True)
    parser.add_argument('--exercise-historical-integrity-candidate',action='store_true',
        help='Only mutate the already isolated disposable clone; reads protected credentials as stdin JSON')
    parser.add_argument('--candidate-node',type=Path)
    parser.add_argument('--candidate-encrypted-preimage',type=Path)
    parser.add_argument('--candidate-ai-only',action='store_true',
        help='Exercise only the separate AI credential operation; report deferred PII conflicts without changing indexes')
    args=parser.parse_args();os.umask(0o077)
    protected_input=sys.stdin.buffer.read(16385)
    if len(protected_input)>16384:raise ValueError('Protected recovery input is oversized')
    candidate_options=None
    if args.exercise_historical_integrity_candidate:
        if not args.candidate_node or not args.candidate_encrypted_preimage:
            raise ValueError('Clone candidate requires its local runtime and encrypted audit destination')
        payload=json.loads(protected_input)
        if set(payload)!={'gpgPassphrase','legacyHmac','recipientFingerprint'}:
            raise ValueError('Unexpected protected recovery input')
        if not re.fullmatch(r'[A-F0-9]{40}|[A-F0-9]{64}',payload['recipientFingerprint']):
            raise ValueError('Invalid pinned encryption recipient')
        secret=payload['gpgPassphrase'].encode()
        candidate_options={'legacy_hmac':payload['legacyHmac'],'recipient':payload['recipientFingerprint'],
            'node':args.candidate_node,'preimage':args.candidate_encrypted_preimage,'gpg_home':args.gpg_home,
            'ai_only':args.candidate_ai_only}
    else:secret=protected_input.strip()
    data=read_bundle(args.bundle)
    receipt=base.decode_json(data['source-receipt.json']);target=base.decode_json(data['target-receipt.json'])
    if (receipt.get('sourceSetId')!=args.expected_source_set_id or receipt.get('sourceManifestSha256')!=args.expected_manifest_sha
            or any(target.get(key)!=value for key,value in receipt.items())
            or target.get('state')!='SNAPSHOT_CIPHERTEXT_COMPLETE'):
        raise ValueError("Requested recovery point differs from signed receipt")
    with tempfile.TemporaryDirectory(prefix='uten-dr-signature-') as temporary:
        signature=Path(temporary)/'source-signature.sshsig';signature.write_bytes(data['source-signature.sshsig']);signature.chmod(0o600)
        chunks.verify_source_signature(receipt,signature,args.allowed_signers,base)
    references=chunks.reference_list(base.decode_json(data['references.json']),base)
    expected_files={'manifest.gpg','references.json','target-receipt.json','source-receipt.json','source-signature.sshsig'}|{
        'objects/'+row['opaqueId']+'.gpg' for row in references}
    if set(data)!=expected_files:raise ValueError("Ciphertext bundle dependency closure differs")
    if (hashlib.sha256(data['manifest.gpg']).hexdigest()!=receipt['manifestCipherSha256']
            or len(data['manifest.gpg'])!=receipt['manifestCipherBytes']
            or hashlib.sha256(chunks.canonical(references)).hexdigest()!=receipt['referenceListSha256']):
        raise ValueError("Signed manifest ciphertext binding failed")
    def decrypt(raw,maximum):
        fd=os.memfd_create('uten-drill-private-key-passphrase',os.MFD_CLOEXEC)
        try:
            os.write(fd,secret+b'\n');os.lseek(fd,0,os.SEEK_SET)
            result=subprocess.run(['/usr/bin/gpg','--no-options','--batch','--no-tty','--homedir',str(args.gpg_home),
                '--pinentry-mode','loopback','--passphrase-fd',str(fd),'--max-output',str(maximum),'--decrypt'],input=raw,capture_output=True,
                pass_fds=(fd,),timeout=60)
            if result.returncode or len(result.stdout)>maximum:raise ValueError("Authenticated chunk decryption failed")
            return result.stdout
        finally:os.close(fd)
    for row in references:
        raw=data['objects/'+row['opaqueId']+'.gpg']
        if len(raw)!=row['cipherBytes'] or hashlib.sha256(raw).hexdigest()!=row['cipherSha256']:
            raise ValueError("Ciphertext chunk digest differs")
    manifest=base.decode_json(decrypt(data['manifest.gpg'],chunks.MAX_MANIFEST_BYTES))
    contents=reconstruct(manifest,references,lambda opaque:decrypt(data['objects/'+opaque+'.gpg'],chunks.CHUNK_BYTES),receipt)
    report=restore_drill.restore_contents(contents,receipt['sourceSetId'],args.docker,candidate_options)
    report.update(snapshotId=receipt['snapshotId'],sourceSignatureVerified=True,chunksVerified=len(references),
        manifestCipherSha256=receipt['manifestCipherSha256'],referenceListSha256=receipt['referenceListSha256'],
        arbitraryPitrOriginalHistoryProtected=False)
    with args.report.open('x',encoding='utf-8') as stream:json.dump(report,stream,indent=2);stream.write('\n')
    print(json.dumps(report))


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(json.dumps({'state':'SNAPSHOT_DRILL_FAILED','errorType':type(error).__name__,
                          'phase':restore_drill.PHASE,'counts':restore_drill.SAFE_COUNTS}),file=sys.stderr)
        raise SystemExit(1)
