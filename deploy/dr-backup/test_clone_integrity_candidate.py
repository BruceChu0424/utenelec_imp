import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest.mock import patch

import clone_integrity_candidate as candidate


class CandidateGuardsTest(unittest.TestCase):
    def setUp(self):
        self.name='uten-drill-123456789abc'
        self.info={'Name':'/'+self.name,'Config':{'User':'999:999'},'Mounts':[],
            'HostConfig':{'NetworkMode':'none','ReadonlyRootfs':True,'CapDrop':['ALL'],
                'Tmpfs':{'/var/lib/postgresql/data':'rw'},'Privileged':False}}
        self.environment={'UTEN_PGP_MASTER_KEY':'test-pgp','UTEN_HMAC_KEY':'current-test-key-'*4,
            'UTEN_JWT_ISSUER':'company-test'}
        self.rows=[{'employee_id':'00000000-0000-0000-0000-000000000001',
            'old_id_hash':'a'*64,'old_phone_hash':None,'new_id_hash':'b'*64,'new_phone_hash':None,
            'cipher_digest':'c'*64,'updated_at':'2026-10-23T01:02:03.000000Z','canonical':True,
            'old_id_legacy_match':True,'old_phone_legacy_match':True}]

    def checked(self,rows=None):
        responses=[rows or self.rows,{'authorizationEpoch':1,'businessResetGeneration':2,
            'database':'drill','systemIdentifier':'123'},
            {'nestedEmployeePhones':0,'visitorAccounts':0},[]]
        def run_sql(_):return json.dumps(responses.pop(0)).encode()
        result=subprocess.CompletedProcess([],0,b'{"rows":[]}',b'')
        with patch.object(candidate.subprocess,'run',return_value=result):
            return candidate.check(run_sql,self.environment,'historical-test',Path('/usr/bin/node'),'d'*64)

    def test_isolation_rejects_network_disks_privileges_and_wrong_identity(self):
        candidate.assert_isolated(self.info,self.name)
        for path,value in [(('HostConfig','NetworkMode'),'bridge'),(('HostConfig','ReadonlyRootfs'),False),
                (('HostConfig','Binds'),['/host:/data']), (('HostConfig','Privileged'),True),
                (('Config','User'),'root'),(('Name',),'/production'),(('Mounts',),[{'Type':'volume'}])]:
            info=copy.deepcopy(self.info);target=info
            for key in path[:-1]:target=target[key]
            target[path[-1]]=value
            with self.subTest(path=path),self.assertRaises(ValueError):candidate.assert_isolated(info,self.name)

    def test_public_plan_contains_no_keys_old_hashes_or_provider_ciphertexts(self):
        plan,proposal=self.checked()
        self.assertTrue(plan['applyAllowedInVerifiedClone'])
        self.assertEqual(1,plan['historicalHashValuesProvenByLegacyKey'])
        self.assertNotIn('historical-test',json.dumps(plan))
        self.assertNotIn('a'*64,json.dumps(plan))
        self.assertEqual('historical-test',proposal['oldHmacKeyRecovery'])

    def test_unproved_or_noncanonical_derived_values_are_blocked(self):
        for key in ['canonical','old_id_legacy_match']:
            rows=copy.deepcopy(self.rows);rows[0][key]=False
            plan,_=self.checked(rows)
            with self.subTest(key=key):self.assertFalse(plan['applyAllowedInVerifiedClone'])

    def test_collision_across_unchanged_and_changed_rows_is_blocked(self):
        rows=copy.deepcopy(self.rows);other=copy.deepcopy(rows[0])
        other['employee_id']='00000000-0000-0000-0000-000000000002';other['old_id_hash']='b'*64
        rows.append(other)
        plan,_=self.checked(rows)
        self.assertEqual(1,plan['blockers']['identityCollisions'])
        self.assertFalse(plan['applyAllowedInVerifiedClone'])

    def test_proposal_tampering_or_missing_encrypted_preimage_is_rejected(self):
        plan,proposal=self.checked()
        with self.assertRaises(ValueError):candidate.apply_sql(proposal,plan,'not-a-digest')
        proposal['rows'][0]['new_id_hash']='e'*64
        with self.assertRaises(ValueError):candidate.apply_sql(proposal,plan,'f'*64)

    def test_candidate_never_calls_write_when_scope_has_a_blocker(self):
        plan,proposal=self.checked();plan['applyAllowedInVerifiedClone']=False
        with patch.object(candidate,'check',return_value=(plan,proposal)):
            result=candidate.exercise(lambda _:self.fail('SQL write attempted'),self.info,self.name,
                self.environment,'historical-test',Path('/usr/bin/node'),'d'*64,
                lambda _:self.fail('Preimage should not be created'))
        self.assertEqual('CLONE_CANDIDATE_BLOCKED',result['state'])


class CipherRewrapTest(unittest.TestCase):
    def test_real_crypto_rebinds_issuer_and_preserves_plaintext_without_exposing_it(self):
        node=shutil.which('node')
        self.assertIsNotNone(node, 'Node runtime is required for the real credential rewrap contract')
        bridge=str(Path(__file__).with_name('credential_rewrap.cjs').resolve())
        script="""const c=require(process.argv[1]);const id='00000000-0000-0000-0000-000000000001';
const old='synthetic-legacy',current='synthetic-current-key-'.repeat(3);const plain=Buffer.from('synthetic-token');
const key=c.derive(old);const stored=c.seal(plain,'old-test',id,key);key.fill(0);
const rows=c.candidate({currentHmac:current,legacyHmac:old,currentIssuer:'company-test',legacyIssuer:'old-test',rows:[{id,secret:stored,version:2}]});
const next=c.candidate({currentHmac:current,legacyHmac:old,currentIssuer:'company-test',legacyIssuer:'old-test',rows:[{id,secret:rows[0].newCipher,version:3}]});
let tamperRejected=false;try{c.candidate({currentHmac:current,legacyHmac:old,currentIssuer:'other',legacyIssuer:'other',rows:[{id,secret:stored,version:2}]});}catch{tamperRejected=true;}
process.stdout.write(JSON.stringify({changed:rows[0].changed,plaintextPreserved:rows[0].plaintextPreserved,secondPassChanged:next[0].changed,tamperRejected}));"""
        value=json.loads(subprocess.check_output([str(node),'-e',script,bridge]))
        self.assertEqual({'changed':True,'plaintextPreserved':True,'secondPassChanged':False,'tamperRejected':True},value)


if __name__=='__main__':unittest.main()
