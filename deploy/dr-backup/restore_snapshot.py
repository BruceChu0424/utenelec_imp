#!/usr/bin/python3
"""Verify source signatures and restore v1 chunks through a private disk spool."""
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
import shutil
from contextlib import contextmanager

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


MEMORY_COMPAT_BYTES = 64 * 1024**2
SPOOL_RESERVE_BYTES = 1024**3


def plain_limit():
    return getattr(chunks, 'MAX_SNAPSHOT_PLAIN_BYTES', 2 * 1024**3)


def bundle_limit():
    return getattr(chunks, 'MAX_BUNDLE_BYTES', plain_limit() + chunks.MAX_REFERENCES * 64 * 1024
                   + 2 * chunks.MAX_MANIFEST_BYTES + 16 * 1024**2)


def relative_name(name):
    if not isinstance(name, str):raise ValueError('Invalid recovery path')
    path = PurePosixPath(name)
    if (path.is_absolute() or str(path) != name or not path.parts or '\\' in name or ':' in name
            or len(name.encode('utf-8')) > 4096 or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or any(part in ('', '.', '..') or part.endswith(('.', ' ')) or len(part.encode('utf-8')) > 255
                   or re.fullmatch(r'(?i)(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part)
                   for part in path.parts)):
        raise ValueError('Invalid recovery path')
    return path


def private_empty_directory(path):
    path = base.private_path(Path(path), directory=True)
    if any(path.iterdir()):raise ValueError('Recovery output directory must be new and empty')
    return path


def destination(root, name, created_directories):
    parts = relative_name(name).parts
    parent = root
    for part in parts[:-1]:
        parent = parent / part
        if not parent.exists():
            parent.mkdir(mode=0o700);created_directories.append(parent)
        base.private_path(parent, directory=True)
    result = parent / parts[-1]
    if result.exists() or result.is_symlink():raise ValueError('Recovery output collision')
    return result


@contextmanager
def private_workspace(parent, *, required_bytes=0):
    with restore_drill.recovery_workspace(parent,required_bytes=required_bytes) as root:
        yield root


def reconstruct(manifest, references, read_plain, receipt):
    """Small compatibility API; production recovery uses reconstruct_to_directory."""
    return _reconstruct(manifest, references, read_plain, receipt)


def reconstruct_to_directory(manifest, references, read_plain, receipt, directory, *, deadline=None):
    return _reconstruct(manifest, references, read_plain, receipt, private_empty_directory(directory),deadline=deadline)


def _reconstruct(manifest, references, read_plain, receipt, directory=None, *, deadline=None):
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
    chunks.reference_list(references, base)
    available={row['opaqueId'] for row in references};used=set();contents={};total=0
    maximum = plain_limit() if directory is not None else MEMORY_COMPAT_BYTES
    prefix='paired/'+manifest['sourceSetId']+'/'
    allowed_recovery={'recovery/'+name for name in (
        'etc/uten-imp/server.env','etc/uten-imp/migrator.env','etc/uten-imp/paired-internal-backup.json',
        'etc/pgbackrest.conf','etc/pgbackrest/conf.d/20-uten-imp-repo2.conf')}
    allowed_tools={'restore-tools/'+name for name in (
        'paired_internal_backup.py','market_state_backup.py','client_release_state_backup.py')}
    if not isinstance(manifest['files'],list) or not 1<=len(manifest['files'])<=200000:
        raise ValueError("Snapshot file inventory is invalid")
    created_files, created_directories = [], []
    try:
      for row in manifest['files']:
        restore_drill.remaining_budget(deadline)
        if not isinstance(row,dict) or set(row)!={'path','size','sha256','chunks'}:raise ValueError("Invalid snapshot file")
        name=row['path'];relative_name(name)
        if (not (name.startswith(prefix) or name in allowed_recovery or name in allowed_tools
                    or name.startswith('recovery/') and remote_catalog.allowed(name[9:]))
                or name in contents or type(row['size']) is not int or not 0<=row['size']<=maximum
                or not base.HASH.fullmatch(row['sha256']) or not isinstance(row['chunks'],list)):
            raise ValueError("Unreviewed snapshot file path or identity")
        if total+row['size']>maximum or len(row['chunks'])>chunks.MAX_REFERENCES:
            raise ValueError("Reconstructed snapshot plaintext budget exceeded")
        value = destination(directory, name, created_directories) if directory is not None else None
        if value is None:stream = io.BytesIO()
        else:
            descriptor = os.open(value, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            created_files.append(value);stream = os.fdopen(descriptor, 'wb')
        digest, size = hashlib.sha256(), 0
        with stream:
          for part in row['chunks']:
            restore_drill.remaining_budget(deadline)
            if (not isinstance(part,dict) or set(part)!={'opaqueId','size','sha256'}
                    or part['opaqueId'] not in available or type(part['size']) is not int
                    or not 0<part['size']<=chunks.CHUNK_BYTES or not base.HASH.fullmatch(part['sha256'])):
                raise ValueError("Invalid ordered chunk reference")
            opaque=part['opaqueId'];used.add(opaque)
            raw=read_plain(opaque)
            if not isinstance(raw, bytes):raise ValueError('Invalid decrypted chunk representation')
            if (len(raw)!=part['size'] or hashlib.sha256(raw).hexdigest()!=part['sha256']
                    or not hmac.compare_digest(chunks.identity(secret,raw),opaque)):
                raise ValueError("Decrypted chunk content/identity/order differs")
            size += len(raw)
            if size > row['size']:raise ValueError('Reconstructed file exceeds its declared size')
            stream.write(raw);digest.update(raw)
          if value is None:value = stream.getvalue()
          else:stream.flush();os.fsync(stream.fileno())
        total += size
        if size != row['size'] or digest.hexdigest() != row['sha256']:
            raise ValueError('Reconstructed file digest or size failed')
        contents[name]=value
      if used!=available:raise ValueError("Unbound or missing snapshot dependency")
      remote=manifest['scope'].get('remoteGatewayRecovery')
      if remote is None and any(name.startswith('recovery/') and remote_catalog.allowed(name[9:]) for name in contents):
        raise ValueError('Remote recovery files lack their complete catalog')
      if remote is not None:remote_catalog.validate_metadata(remote,set(contents))
      if ('recovery/etc/uten-imp/server.env' not in contents or prefix+'database.dump' not in contents
            or restore_drill.content_identity(contents[prefix+'manifest.json'],deadline=deadline)[1]!=receipt['sourceManifestSha256']):
        raise ValueError("Required paired/crypto manifest binding failed")
      return contents
    except BaseException:
        for path in reversed(created_files):path.unlink(missing_ok=True)
        for path in reversed(created_directories):path.rmdir()
        raise


class SnapshotTarInfo(tarfile.TarInfo):
    # The v1 ciphertext bundle has only fixed short ASCII names. Extended
    # headers are unnecessary and must not allocate attacker-sized metadata.
    def _proc_pax(self, archive):
        raise ValueError('Extended ciphertext tar headers are forbidden')

    def _proc_gnulong(self, archive):
        raise ValueError('Extended ciphertext tar names are forbidden')


def read_bundle(path, directory=None, *, deadline=None):
    result={};total=0
    if directory is not None:directory = private_empty_directory(directory)
    maximum = bundle_limit() if directory is not None else MEMORY_COMPAT_BYTES
    created_files, created_directories = [], []
    fixed={'manifest.gpg','references.json','target-receipt.json','source-receipt.json','source-signature.sshsig'}
    try:
      with tarfile.open(path,mode='r|',tarinfo=SnapshotTarInfo) as archive:
        for member in archive:
            restore_drill.remaining_budget(deadline)
            if (member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or member.name in result or member.size<0
                    or not (member.name in fixed or re.fullmatch(r'objects/[a-f0-9]{64}\.gpg',member.name))):
                raise ValueError("Invalid ciphertext bundle member")
            member_limit = (chunks.MAX_CIPHER_BYTES if member.name.startswith('objects/') else
                            chunks.MAX_MANIFEST_BYTES if member.name == 'manifest.gpg' else base.HEADER_LIMIT)
            if member.size > member_limit or len(result) >= chunks.MAX_REFERENCES + len(fixed):
                raise ValueError('Ciphertext bundle member budget exceeded')
            total+=member.size
            if total>maximum:raise ValueError("Ciphertext bundle exceeds its bounded budget")
            value = destination(directory, member.name, created_directories) if directory is not None else None
            if value is None:stream = io.BytesIO()
            else:
                fd = os.open(value, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                created_files.append(value);stream = os.fdopen(fd, 'wb')
            size = 0
            with archive.extractfile(member) as source, stream:
                while block := source.read(chunks.CHUNK_BYTES):
                    restore_drill.remaining_budget(deadline)
                    size += len(block)
                    if size > member.size:raise ValueError('Ciphertext member grew during read')
                    stream.write(block)
                if value is None:value = stream.getvalue()
                else:stream.flush();os.fsync(stream.fileno())
            if size != member.size:raise ValueError('Ciphertext bundle member is truncated')
            result[member.name]=value
      if not fixed.issubset(result):raise ValueError("Ciphertext bundle metadata is incomplete")
      return result
    except BaseException:
        for file in reversed(created_files):file.unlink(missing_ok=True)
        for folder in reversed(created_directories):folder.rmdir()
        raise


def restore_bundle(args, secret, candidate_options=None):
    budget = getattr(args,'budget_seconds',3600)
    if type(budget) is not int or not 60 <= budget <= 3600:raise ValueError('Recovery budget must be 60..3600 seconds')
    # Reserve the last thirty seconds for container and private-spool cleanup.
    deadline = restore_drill.time.monotonic() + budget - 30
    if args.bundle.stat().st_size > bundle_limit() + 16 * 1024**2:
        raise ValueError('Ciphertext tar exceeds its total storage budget')
    with private_workspace(args.spool_directory, required_bytes=args.bundle.stat().st_size) as workspace:
        cipher_root, plain_root, cache_root = (workspace / name for name in ('cipher', 'plain', 'cache'))
        for directory in (cipher_root, plain_root, cache_root):directory.mkdir(mode=0o700)
        data=read_bundle(args.bundle, cipher_root,deadline=deadline)
        receipt=base.decode_json(restore_drill.content_bytes(data['source-receipt.json'], base.HEADER_LIMIT))
        target=base.decode_json(restore_drill.content_bytes(data['target-receipt.json'], base.HEADER_LIMIT))
        if (receipt.get('sourceSetId')!=args.expected_source_set_id or receipt.get('sourceManifestSha256')!=args.expected_manifest_sha
                or any(target.get(key)!=value for key,value in receipt.items())
                or target.get('state')!='SNAPSHOT_CIPHERTEXT_COMPLETE'):
            raise ValueError('Requested recovery point differs from signed receipt')
        if restore_drill.remaining_budget(deadline) < 15:raise TimeoutError('Insufficient signature verification budget')
        chunks.verify_source_signature(receipt,data['source-signature.sshsig'],args.allowed_signers,base)
        references=chunks.reference_list(base.decode_json(
            restore_drill.content_bytes(data['references.json'],base.HEADER_LIMIT)),base)
        expected_files={'manifest.gpg','references.json','target-receipt.json','source-receipt.json','source-signature.sshsig'}|{
            'objects/'+row['opaqueId']+'.gpg' for row in references}
        if set(data)!=expected_files:raise ValueError('Ciphertext bundle dependency closure differs')
        manifest_size, manifest_digest = restore_drill.content_identity(data['manifest.gpg'],deadline=deadline)
        if (manifest_digest!=receipt['manifestCipherSha256'] or manifest_size!=receipt['manifestCipherBytes']
                or hashlib.sha256(chunks.canonical(references)).hexdigest()!=receipt['referenceListSha256']):
            raise ValueError('Signed manifest ciphertext binding failed')

        def decrypt(path,maximum):
            fd=os.memfd_create('uten-drill-private-key-passphrase',os.MFD_CLOEXEC)
            try:
                os.write(fd,secret+b'\n');os.lseek(fd,0,os.SEEK_SET)
                with path.open('rb') as source:
                    result=subprocess.run(['/usr/bin/gpg','--no-options','--batch','--no-tty','--homedir',str(args.gpg_home),
                        '--pinentry-mode','loopback','--passphrase-fd',str(fd),'--max-output',str(maximum),'--decrypt'],
                        stdin=source,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,pass_fds=(fd,),
                        timeout=restore_drill.phase_timeout(deadline,60))
                if result.returncode or len(result.stdout)>maximum:raise ValueError('Authenticated chunk decryption failed')
                return result.stdout
            finally:os.close(fd)
        for row in references:
            size, digest = restore_drill.content_identity(data['objects/'+row['opaqueId']+'.gpg'],deadline=deadline)
            if size!=row['cipherBytes'] or digest!=row['cipherSha256']:
                raise ValueError('Ciphertext chunk digest differs')
        manifest=base.decode_json(decrypt(data['manifest.gpg'],chunks.MAX_MANIFEST_BYTES))
        total = 0
        for row in manifest.get('files', []):
            size = row.get('size') if isinstance(row,dict) else None
            if type(size) is not int or not 0 <= size <= plain_limit():raise ValueError('Invalid plaintext size budget')
            total += size
        if total > plain_limit() or shutil.disk_usage(workspace).free < 2 * total + SPOOL_RESERVE_BYTES:
            raise ValueError('Recovery plaintext spool budget would be crossed')
        def read_plain(opaque):
            path = cache_root / opaque
            if not path.exists():
                raw = decrypt(data['objects/'+opaque+'.gpg'],chunks.CHUNK_BYTES)
                fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
                with os.fdopen(fd,'wb') as output:output.write(raw)
            return restore_drill.content_bytes(path,chunks.CHUNK_BYTES)
        contents=reconstruct_to_directory(manifest,references,read_plain,receipt,plain_root,deadline=deadline)
        report=restore_drill.restore_contents(contents,receipt['sourceSetId'],args.docker,candidate_options,
                                            spool_directory=workspace,deadline=deadline)
        report.update(snapshotId=receipt['snapshotId'],sourceSignatureVerified=True,chunksVerified=len(references),
            manifestCipherSha256=receipt['manifestCipherSha256'],referenceListSha256=receipt['referenceListSha256'],
            arbitraryPitrOriginalHistoryProtected=False,restoreInputMode='PRIVATE_DISK',
            plaintextPayloadLimitBytes=plain_limit(),chunkWorkingSetBytes=chunks.CHUNK_BYTES,
            recoveryBudgetSeconds=budget,cleanupReservedSeconds=30)
        return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('bundle','allowed-signers','gpg-home','docker','report'):
        parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--expected-source-set-id',required=True)
    parser.add_argument('--expected-manifest-sha',required=True)
    parser.add_argument('--spool-directory',required=True,type=Path,
        help='Existing private directory on the trusted recovery workstation; never a production path')
    parser.add_argument('--budget-seconds',type=int,default=3600,
        help='One total 60..3600 second recovery budget, including a 30-second cleanup reserve')
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
    report=restore_bundle(args,secret,candidate_options)
    with args.report.open('x',encoding='utf-8') as stream:json.dump(report,stream,indent=2);stream.write('\n')
    print(json.dumps(report))


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(json.dumps({'state':'SNAPSHOT_DRILL_FAILED','errorType':type(error).__name__,
                          'phase':restore_drill.PHASE,'counts':restore_drill.SAFE_COUNTS}),file=sys.stderr)
        raise SystemExit(1)
