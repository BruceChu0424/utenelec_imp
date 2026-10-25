"""Synthetic recovery files only: no PostgreSQL, production files or servers."""
import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contextlib import contextmanager, ExitStack

import restore_snapshot as restore
import restore_drill
import test_restore_snapshot as fixtures


@contextmanager
def gpg_workspace():
    with tempfile.TemporaryDirectory(prefix='uten-v1-crypto-') as temporary:
        root=Path(temporary);root.chmod(0o700);home=root/'gpg';home.mkdir(mode=0o700)
        try:yield root,home
        finally:subprocess.run(['/usr/bin/gpgconf','--homedir',str(home),'--kill','gpg-agent'],
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)


class DiskReconstructionTest(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.ReconstructSnapshotTest()
        fixture.setUp()
        for name in ('secret','set_id','prefix','plain','blocks','refs','receipt','manifest'):
            setattr(self,name,getattr(fixture,name))
    def test_disk_reconstruction_preserves_v1_bytes_and_cleans_partial_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary);root.chmod(0o700)
            result = restore.reconstruct_to_directory(self.manifest,self.refs,self.blocks.__getitem__,self.receipt,root)
            self.assertEqual(self.plain,{name:path.read_bytes() for name,path in result.items()})
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);root.chmod(0o700)
            bad=copy.deepcopy(self.manifest);bad['files'][-1]['sha256']='0'*64
            with self.assertRaises(ValueError):
                restore.reconstruct_to_directory(bad,self.refs,self.blocks.__getitem__,self.receipt,root)
            self.assertEqual([],list(root.iterdir()))

    def test_disk_target_rejects_existing_files_links_and_unsafe_path_components(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);root.chmod(0o700);(root/'keep').write_bytes(b'keep')
            with self.assertRaises(ValueError):
                restore.reconstruct_to_directory(self.manifest,self.refs,self.blocks.__getitem__,self.receipt,root)
            self.assertEqual(b'keep',(root/'keep').read_bytes())
        for name in ('paired/a/../b','paired/a\\b','paired/a:stream','paired/con','/absolute'):
            with self.subTest(name=name),self.assertRaises(ValueError):restore.relative_name(name)

    def test_shared_deadline_aborts_reconstruction_and_cleans_its_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);root.chmod(0o700)
            def delayed(opaque):
                time.sleep(.03)
                return self.blocks[opaque]
            with self.assertRaises(TimeoutError):
                restore.reconstruct_to_directory(self.manifest,self.refs,delayed,self.receipt,root,
                                                 deadline=time.monotonic()+.01)
            self.assertEqual([],list(root.iterdir()))


class StreamedRecoveryResourcesTest(unittest.TestCase):
    def test_more_than_512mib_reconstructs_under_160mib_address_space(self):
        module_root=str(Path(__file__).parent.resolve())
        code=r'''
import base64,hashlib,json,resource,tempfile,sys
from pathlib import Path
import restore_snapshot as r
resource.setrlimit(resource.RLIMIT_AS,(160*1024**2,160*1024**2))
secret=b'x'*32;set_id='20261025T000000Z-123456789abc';prefix='paired/'+set_id+'/'
parts=[];lookups={};whole=hashlib.sha256();count=1200
for index in range(count):
 raw=hashlib.shake_256(str(index).encode()).digest(r.chunks.CHUNK_BYTES)
 opaque=r.chunks.identity(secret,raw);lookups[opaque]=index;whole.update(raw)
 parts.append({'opaqueId':opaque,'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
small={prefix+'manifest.json':b'{}','recovery/etc/uten-imp/server.env':b'SYNTHETIC=1'}
files=[{'path':prefix+'database.dump','size':count*r.chunks.CHUNK_BYTES,'sha256':whole.hexdigest(),'chunks':parts}]
for name,raw in small.items():
 opaque=r.chunks.identity(secret,raw);lookups[opaque]=raw
 files.append({'path':name,'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'chunks':[{'opaqueId':opaque,'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}]})
refs=[{'opaqueId':key,'cipherSha256':'a'*64,'cipherBytes':100} for key in sorted(lookups)]
receipt={'format':r.chunks.FORMAT,'snapshotId':'snapshot-'+set_id,'nonce':'a'*32,'sourceSetId':set_id,'sourceSnapshotAt':'2026-10-25T00:00:00Z','sourceManifestSha256':hashlib.sha256(b'{}').hexdigest(),'recipientFingerprint':'A'*40,'referenceListSha256':hashlib.sha256(r.chunks.canonical(refs)).hexdigest()}
manifest={**receipt,'chunkBytes':r.chunks.CHUNK_BYTES,'dedupIdentityKeyRecovery':base64.b64encode(secret).decode(),'files':files,'scope':{'cryptoRecoveryIncluded':True}}
def reader(opaque):
 value=lookups[opaque]
 return value if isinstance(value,bytes) else hashlib.shake_256(str(value).encode()).digest(r.chunks.CHUNK_BYTES)
with tempfile.TemporaryDirectory(prefix='uten-large-reconstruct-') as temporary:
 root=Path(temporary);root.chmod(0o700)
 result=r.reconstruct_to_directory(manifest,refs,reader,receipt,root)
 size,digest=r.restore_drill.content_identity(result[prefix+'database.dump'])
 assert size==count*r.chunks.CHUNK_BYTES and digest==whole.hexdigest()
 consumer='import hashlib,json,sys;h=hashlib.sha256();n=0\nwhile b:=sys.stdin.buffer.read(1048576):h.update(b);n+=len(b)\nprint(json.dumps({"bytes":n,"sha256":h.hexdigest()}))'
 streamed=json.loads(r.restore_drill.run_isolated_command([sys.executable,'-I','-c',consumer],result[prefix+'database.dump'],spool_directory=root))
 assert streamed=={'bytes':size,'sha256':digest}
 print(json.dumps({'bytes':size,'maxRssKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'verified':True,'streamedConsumerVerified':True}))
'''
        bootstrap='import sys;sys.path.insert(0,'+repr(module_root)+');exec('+repr(code)+')'
        result=subprocess.run([sys.executable,'-I','-B','-c',bootstrap],capture_output=True,text=True,timeout=120)
        self.assertEqual(0,result.returncode,result.stderr[-2000:])
        evidence=json.loads(result.stdout)
        self.assertTrue(evidence['verified']);self.assertGreater(evidence['bytes'],512*1024**2)
        self.assertLess(evidence['maxRssKiB'],128*1024)
        self.resource_evidence=evidence

    def test_cipher_tar_more_than_512mib_spools_under_160mib_address_space(self):
        module_root=str(Path(__file__).parent.resolve())
        code=r'''
import io,json,resource,tarfile,tempfile
from pathlib import Path
import restore_snapshot as r
resource.setrlimit(resource.RLIMIT_AS,(160*1024**2,160*1024**2))
with tempfile.TemporaryDirectory(prefix='uten-large-cipher-') as temporary:
 root=Path(temporary);root.chmod(0o700);source=root/'cipher.tar'
 with tarfile.open(source,'w|',format=tarfile.USTAR_FORMAT) as tar:
  for index in range(1200):
   raw=bytes([index%251])*r.chunks.CHUNK_BYTES;info=tarfile.TarInfo('objects/'+f'{index:064x}'+'.gpg');info.size=len(raw);tar.addfile(info,io.BytesIO(raw))
  for name in ('manifest.gpg','references.json','target-receipt.json','source-receipt.json','source-signature.sshsig'):
   info=tarfile.TarInfo(name);info.size=2;tar.addfile(info,io.BytesIO(b'{}'))
 target=root/'spool';target.mkdir(mode=0o700);mapped=r.read_bundle(source,target)
 total=sum(path.stat().st_size for path in mapped.values());assert total>512*1024**2
 print(json.dumps({'bytes':total,'members':len(mapped),'maxRssKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}))
'''
        bootstrap='import sys;sys.path.insert(0,'+repr(module_root)+');exec('+repr(code)+')'
        result=subprocess.run([sys.executable,'-I','-B','-c',bootstrap],capture_output=True,text=True,timeout=120)
        self.assertEqual(0,result.returncode,result.stderr[-2000:]);evidence=json.loads(result.stdout)
        self.assertEqual(1205,evidence['members']);self.assertLess(evidence['maxRssKiB'],128*1024)
        self.resource_evidence=evidence

    def test_streamed_tar_rejects_duplicate_link_truncation_and_cleans_target(self):
        for problem in ('duplicate','link','truncated'):
            with self.subTest(problem=problem),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);root.chmod(0o700);source=root/'cipher.tar'
                with tarfile.open(source,'w') as tar:
                    info=tarfile.TarInfo('manifest.gpg');info.size=3;tar.addfile(info,io.BytesIO(b'abc'))
                    if problem=='duplicate':tar.addfile(info,io.BytesIO(b'abc'))
                    elif problem=='link':
                        info=tarfile.TarInfo('source-receipt.json');info.type=tarfile.SYMTYPE;info.linkname='/etc/shadow';tar.addfile(info)
                if problem=='truncated':source.write_bytes(source.read_bytes()[:513])
                target=root/'target';target.mkdir(mode=0o700)
                with self.assertRaises((ValueError,tarfile.TarError,EOFError)):restore.read_bundle(source,target)
                self.assertEqual([],list(target.iterdir()))

    def test_real_v1_signature_and_gpg_bundle_uses_disk_inputs_and_cleans_all_spools(self):
        fixture=fixtures.ReconstructSnapshotTest();fixture.setUp()
        with gpg_workspace() as (root,home):
            def command(args,raw=None):
                value=subprocess.run(args,input=raw,capture_output=True,timeout=30)
                self.assertEqual(0,value.returncode,value.stderr[-1000:]);return value.stdout
            command(['/usr/bin/gpg','--homedir',str(home),'--batch','--pinentry-mode','loopback','--passphrase','',
                     '--quick-generate-key','Synthetic DR restore fixture','rsa2048','encr','0'])
            listing=command(['/usr/bin/gpg','--homedir',str(home),'--with-colons','--list-keys']).decode()
            fingerprint=next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
            def encrypt(raw):
                return command(['/usr/bin/gpg','--homedir',str(home),'--batch','--trust-model','always',
                                '--recipient',fingerprint,'--compress-algo','zlib','--encrypt'],raw)
            ciphertext={opaque:encrypt(raw) for opaque,raw in fixture.blocks.items()}
            refs=[{'opaqueId':opaque,'cipherSha256':hashlib.sha256(raw).hexdigest(),'cipherBytes':len(raw)}
                  for opaque,raw in sorted(ciphertext.items())]
            manifest=copy.deepcopy(fixture.manifest)
            manifest['referenceListSha256']=hashlib.sha256(restore.chunks.canonical(refs)).hexdigest()
            manifest['recipientFingerprint']=fingerprint
            encoded=encrypt(restore.chunks.canonical(manifest))
            receipt={key:manifest[key] for key in ('format','snapshotId','nonce','sourceSetId','sourceSnapshotAt',
                'sourceManifestSha256','recipientFingerprint','referenceListSha256')}
            receipt.update(manifestCipherSha256=hashlib.sha256(encoded).hexdigest(),manifestCipherBytes=len(encoded),
                           marketStateIncluded=False,clientReleaseStateIncluded=False)
            signing=root/'signing';command(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(signing)])
            allowed=root/'allowed_signers'
            allowed.write_text('uten-backup-source namespaces="'+restore.chunks.SIGNING_NAMESPACE+'" '+
                               signing.with_suffix('.pub').read_text());allowed.chmod(0o600)
            signature=restore.chunks.sign_receipt(receipt,signing,restore.base).encode()
            members={'manifest.gpg':encoded,'references.json':restore.chunks.canonical(refs),
                'source-receipt.json':restore.chunks.canonical(receipt),
                'target-receipt.json':restore.chunks.canonical({**receipt,'state':'SNAPSHOT_CIPHERTEXT_COMPLETE'}),
                'source-signature.sshsig':signature,**{'objects/'+key+'.gpg':value for key,value in ciphertext.items()}}
            bundle=root/'bundle.tar'
            with tarfile.open(bundle,'w',format=tarfile.USTAR_FORMAT) as tar:
                for name,raw in members.items():
                    info=tarfile.TarInfo(name);info.size=len(raw);tar.addfile(info,io.BytesIO(raw))
            spool=root/'spool';spool.mkdir(mode=0o700)
            args=SimpleNamespace(bundle=bundle,spool_directory=spool,gpg_home=home,allowed_signers=allowed,
                docker=root/'unused-docker',expected_source_set_id=fixture.set_id,
                expected_manifest_sha=fixture.receipt['sourceManifestSha256'])
            def consume(contents,*args,**kwargs):
                self.assertTrue(all(isinstance(value,Path) for value in contents.values()))
                self.assertEqual(fixture.plain,{name:value.read_bytes() for name,value in contents.items()})
                return {'state':'SYNTHETIC_INPUTS_VERIFIED','databaseRestored':False}
            with patch.object(restore.restore_drill,'restore_contents',side_effect=consume):
                report=restore.restore_bundle(args,b'')
            self.assertTrue(report['sourceSignatureVerified']);self.assertEqual('PRIVATE_DISK',report['restoreInputMode'])
            self.assertFalse(report['databaseRestored']);self.assertEqual([],list(spool.iterdir()))
            # A correctly formatted archive with a changed ciphertext still fails
            # before any drill callback and removes its owned workspace.
            members['manifest.gpg']=b'TAMPERED'+encoded[8:]
            with tarfile.open(bundle,'w',format=tarfile.USTAR_FORMAT) as tar:
                for name,raw in members.items():
                    info=tarfile.TarInfo(name);info.size=len(raw);tar.addfile(info,io.BytesIO(raw))
            with patch.object(restore.restore_drill,'restore_contents',side_effect=AssertionError('Drill must not run')):
                with self.assertRaises(ValueError):restore.restore_bundle(args,b'')
            self.assertEqual([],list(spool.iterdir()))

    def test_sealed_full_v1_cli_decrypts_and_verifies_on_disk_without_a_database(self):
        fixture=fixtures.ReconstructSnapshotTest();fixture.setUp()
        with gpg_workspace() as (root,home):
            def command(args,raw=None):
                value=subprocess.run(args,input=raw,capture_output=True,timeout=30)
                self.assertEqual(0,value.returncode,value.stderr[-1000:]);return value.stdout
            command(['/usr/bin/gpg','--homedir',str(home),'--batch','--pinentry-mode','loopback','--passphrase','',
                     '--quick-generate-key','Synthetic sealed restore fixture','rsa2048','encr','0'])
            listing=command(['/usr/bin/gpg','--homedir',str(home),'--with-colons','--list-keys']).decode()
            fingerprint=next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
            inventory={'format':'uten-sealed-paired-v1','sourceSetId':fixture.set_id,
                'sourceManifestSha256':fixture.receipt['sourceManifestSha256'],'recipientFingerprint':fingerprint,
                'cryptoRecoveryIncluded':True,'files':[{'path':name,'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
                    for name,raw in fixture.plain.items()]}
            plaintext=io.BytesIO()
            with tarfile.open(fileobj=plaintext,mode='w',format=tarfile.USTAR_FORMAT) as tar:
                for name,raw in {'export-manifest.json':json.dumps(inventory).encode(),**fixture.plain}.items():
                    info=tarfile.TarInfo(name);info.size=len(raw);tar.addfile(info,io.BytesIO(raw))
            cipher=command(['/usr/bin/gpg','--homedir',str(home),'--batch','--trust-model','always',
                '--recipient',fingerprint,'--compress-algo','zlib','--encrypt'],plaintext.getvalue())
            source=root/'archive.gpg';source.write_bytes(cipher)
            receipt=root/'receipt.json';receipt.write_text(json.dumps({**inventory,
                'ciphertextSha256':hashlib.sha256(cipher).hexdigest(),'ciphertextBytes':len(cipher)}))
            spool=root/'spool';spool.mkdir(mode=0o700);report=root/'report.json'
            def consume(contents,*args,**kwargs):
                self.assertTrue(all(isinstance(value,Path) for value in contents.values()))
                self.assertEqual(fixture.plain,{name:contents[name].read_bytes() for name in fixture.plain})
                return {'state':'SYNTHETIC_INPUTS_VERIFIED','databaseRestored':False}
            arguments=['restore_drill.py','--archive',str(source),'--source-receipt',str(receipt),
                '--gpg-home',str(home),'--docker',str(root/'unused-docker'),'--report',str(report),
                '--spool-directory',str(spool),'--budget-seconds','60']
            with patch.object(sys,'argv',arguments),patch.object(sys,'stdin',SimpleNamespace(buffer=io.BytesIO(b''))), \
                    patch.object(restore_drill,'restore_contents',side_effect=consume),patch('builtins.print'):
                restore_drill.main()
            value=json.loads(report.read_text())
            self.assertEqual('PRIVATE_DISK',value['restoreInputMode'])
            self.assertFalse(value['databaseRestored']);self.assertEqual([],list(spool.iterdir()))

    def test_source_and_restore_resource_limits_match(self):
        self.assertEqual(restore.chunks.MAX_SNAPSHOT_PLAIN_BYTES,restore_drill.MAX_PLAIN_BYTES)
        self.assertEqual(restore.chunks.MAX_ARCHIVE_CIPHER_BYTES,restore_drill.MAX_ARCHIVE_CIPHER_BYTES)

    def test_private_workspace_cleans_when_recovery_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            with self.assertRaises(ValueError):
                with restore.private_workspace(parent) as root:
                    (root/'private-data').write_bytes(b'SYNTHETIC');raise ValueError('failed')
            self.assertEqual([],list(parent.iterdir()))

    def test_crashed_owned_spool_is_reaped_but_live_and_unknown_leases_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            unknown=parent/'.uten-recovery-unknown';unknown.mkdir(mode=0o700)
            module_root=str(Path(__file__).parent.resolve())
            code=('import sys;from pathlib import Path;sys.path.insert(0,'+repr(module_root)+');import restore_drill as r\n'
                  f'with r.recovery_workspace(Path({str(parent)!r})) as p:\n'
                  ' (p/"private").write_bytes(b"SYNTHETIC")\n print(p.name,flush=True)\n sys.stdin.buffer.read()')
            child=subprocess.Popen([sys.executable,'-I','-B','-c',code],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
            try:
                abandoned=parent/child.stdout.readline().decode().strip()
                restore_drill.remove_abandoned_recovery_spools(parent)
                self.assertTrue(abandoned.exists(),'Live PID/start lease must remain')
                child.kill();child.wait(timeout=5)
                with restore.private_workspace(parent):
                    self.assertFalse(abandoned.exists())
                    self.assertTrue(unknown.exists())
                self.assertEqual([unknown],list(parent.iterdir()))
            finally:
                if child.poll() is None:child.kill();child.wait(timeout=5)
                child.stdin.close();child.stdout.close()

    def test_isolated_consumer_output_cannot_fill_the_spool(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            with self.assertRaises((ValueError,RuntimeError)):
                restore_drill.run_isolated_command([sys.executable,'-I','-c',
                    'import sys;sys.stdout.buffer.write(b"x"*(4*1024**2))'],spool_directory=parent)
            self.assertEqual([],list(parent.iterdir()))

    def test_unknown_nonempty_spool_blocks_retries_without_creating_more_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            unknown=parent/'.uten-recovery-unknown';unknown.mkdir(mode=0o700)
            payload=unknown/'keep';payload.write_bytes(b'SYNTHETIC-UNKNOWN-PREIMAGE')
            before=set(parent.iterdir())
            for _ in range(5):
                with self.assertRaisesRegex(ValueError,'Unknown nonempty'):
                    with restore.private_workspace(parent):self.fail('Unknown spool was bypassed')
                self.assertEqual(before,set(parent.iterdir()))
                self.assertEqual(b'SYNTHETIC-UNKNOWN-PREIMAGE',payload.read_bytes())

    def test_active_workspace_limit_preserves_live_leases_and_bounds_new_allocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            with ExitStack() as contexts:
                active=[contexts.enter_context(restore.private_workspace(parent)) for _ in range(4)]
                for _ in range(3):
                    with self.assertRaisesRegex(ValueError,'concurrency limit'):
                        with restore.private_workspace(parent):self.fail('Workspace limit was bypassed')
                    self.assertEqual(set(active),set(parent.iterdir()))
                    self.assertTrue(all(path.is_dir() for path in active))
            self.assertEqual([],list(parent.iterdir()))

    def test_foreign_allocator_lock_fails_closed_without_waiting_or_creating_a_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);parent.chmod(0o700)
            code=('import fcntl,os,sys;fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY);'
                  'fcntl.flock(fd,fcntl.LOCK_EX);print("locked",flush=True);sys.stdin.buffer.read()')
            child=subprocess.Popen([sys.executable,'-I','-B','-c',code,str(parent)],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE)
            try:
                self.assertEqual(b'locked\n',child.stdout.readline())
                with self.assertRaisesRegex(ValueError,'allocation is already in progress'):
                    with restore.private_workspace(parent):self.fail('Concurrent allocator was admitted')
                self.assertEqual([],list(parent.iterdir()))
                self.assertIsNone(child.poll())
            finally:
                child.kill();child.wait(timeout=5);child.stdin.close();child.stdout.close()


if __name__=='__main__':unittest.main()
