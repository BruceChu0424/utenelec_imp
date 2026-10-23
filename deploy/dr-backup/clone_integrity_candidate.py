"""Read-only plan and explicit isolated-clone exercise for historical HMAC/AI repair.

No production connection, DSN, socket or apply mode is implemented here. The
caller supplies an already isolated Docker drill. All secrets stay in RAM,
stdin pipes and recipient-encrypted preimages; public reports contain counts.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def digest(value):return hashlib.sha256(canonical(value)).hexdigest()
def literal(value):return "'"+str(value).replace("'","''")+"'"


def assert_isolated(info, name):
    if (not re.fullmatch(r'uten-drill-[a-f0-9]{12}',name)
            or info.get('Name')!='/'+name
            or info.get('HostConfig',{}).get('NetworkMode')!='none'
            or info.get('HostConfig',{}).get('ReadonlyRootfs') is not True
            or info.get('Config',{}).get('User')!='999:999'
            or '/var/lib/postgresql/data' not in info.get('HostConfig',{}).get('Tmpfs',{})
            or info.get('HostConfig',{}).get('Binds')
            or info.get('HostConfig',{}).get('Mounts') or info.get('HostConfig',{}).get('VolumesFrom')
            or info.get('HostConfig',{}).get('Devices') or info.get('HostConfig',{}).get('PidMode')=='host'
            or 'ALL' not in info.get('HostConfig',{}).get('CapDrop',[])
            or any(item.get('Type')!='tmpfs' for item in info.get('Mounts',[]))
            or info.get('HostConfig',{}).get('Privileged')):
        raise ValueError('Only an isolated memory-only recovery clone is accepted')


def environment_keys(environment):
    version=environment.get('UTEN_PGP_KEY_VERSION','1')
    ring={match.group(1):value for key,value in environment.items()
          if (match:=re.fullmatch(r'UTEN_CRYPTO_PGPLEGACYKEYS_([A-Za-z0-9_.-]+)',key))}
    ring[version]=environment['UTEN_PGP_MASTER_KEY']
    return ring,environment['UTEN_HMAC_KEY'],environment.get('UTEN_PGP_UNVERSIONED_KEY_VERSION','1')


def analysis_sql(environment,legacy_hmac):
    ring,current,unversioned=environment_keys(environment)
    keyring=literal(json.dumps(ring))+'::jsonb'
    def decrypt(column):
        ver="CASE WHEN "+column+" ~ '^[A-Za-z0-9_.-]+:' THEN split_part("+column+",':',1) ELSE "+literal(unversioned)+" END"
        body="CASE WHEN "+column+" ~ '^[A-Za-z0-9_.-]+:' THEN substr("+column+",strpos("+column+",':')+1) ELSE "+column+" END"
        return "CASE WHEN "+column+" IS NULL THEN NULL ELSE pgp_sym_decrypt(decode("+body+",'base64'),("+keyring+")->>("+ver+")) END"
    equivalence_key=os.urandom(32).hex()
    return """
WITH decoded AS (
 SELECT s.employee_id,s.id_card_hash AS old_id_hash,s.phone_hash AS old_phone_hash,
  encode(digest(coalesce(s.id_card_enc,'')||E'\\n'||coalesce(s.phone_enc,''),'sha256'),'hex') AS cipher_digest,
  ID_DECRYPT AS identity_plain,PHONE_DECRYPT AS phone_plain,e.id_type,
  to_char(s.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at
 FROM employee_sensitive s JOIN employees e ON e.id=s.employee_id
), cleaned AS (
 SELECT *,CASE WHEN id_type='身份证' THEN upper(normalize(btrim(identity_plain),NFKC)) ELSE btrim(identity_plain) END AS identity_normal,
  regexp_replace(normalize(btrim(phone_plain),NFKC),'[()[:space:]-]','','g') AS phone_clean FROM decoded
), normalized AS (
 SELECT *,CASE WHEN phone_clean LIKE '+86%' THEN substr(phone_clean,4)
  WHEN phone_clean LIKE '0086%' THEN substr(phone_clean,5)
  WHEN phone_clean LIKE '86%' AND length(phone_clean)=13 THEN substr(phone_clean,3) ELSE phone_clean END AS phone_normal
 FROM cleaned
), proposed AS (
 SELECT employee_id,old_id_hash,old_phone_hash,cipher_digest,updated_at,
  CASE WHEN identity_plain IS NULL THEN NULL ELSE encode(hmac(identity_plain,EQUIVALENCE_KEY,'sha256'),'hex') END AS identity_equivalence,
  CASE WHEN phone_plain IS NULL THEN NULL ELSE encode(hmac(phone_plain,EQUIVALENCE_KEY,'sha256'),'hex') END AS phone_equivalence,
  CASE WHEN old_id_hash IS NULL THEN NULL ELSE encode(hmac(identity_plain,CURRENT_KEY,'sha256'),'hex') END AS new_id_hash,
  CASE WHEN old_phone_hash IS NULL THEN NULL ELSE encode(hmac(phone_plain,CURRENT_KEY,'sha256'),'hex') END AS new_phone_hash,
  identity_plain IS NOT DISTINCT FROM identity_normal AND phone_plain IS NOT DISTINCT FROM phone_normal
   AND (identity_plain IS NULL OR length(identity_plain)>0)
   AND (phone_plain IS NULL OR phone_plain ~ '^1[3-9][0-9]{9}$') AS canonical,
  (old_id_hash IS NULL AND identity_plain IS NULL OR old_id_hash=encode(hmac(identity_plain,LEGACY_KEY,'sha256'),'hex')) AS old_id_legacy_match,
  (old_phone_hash IS NULL AND phone_plain IS NULL OR old_phone_hash=encode(hmac(phone_plain,LEGACY_KEY,'sha256'),'hex')) AS old_phone_legacy_match
 FROM normalized
)
SELECT coalesce(json_agg(row_to_json(p) ORDER BY employee_id),'[]'::json) FROM proposed p;
""".replace('ID_DECRYPT',decrypt('s.id_card_enc')).replace('PHONE_DECRYPT',decrypt('s.phone_enc')) \
       .replace('CURRENT_KEY',literal(current)).replace('LEGACY_KEY',literal(legacy_hmac)).replace('EQUIVALENCE_KEY',literal(equivalence_key))


def check(run_sql,environment,legacy_hmac,node,config_digest):
    rows=json.loads(run_sql(analysis_sql(environment,legacy_hmac)).decode().strip().splitlines()[-1])
    epochs=json.loads(run_sql("SELECT json_build_object('authorizationEpoch',epoch,'businessResetGeneration',business_reset_generation," \
        "'database',current_database(),'systemIdentifier',(pg_control_system()).system_identifier::text) FROM authorization_state WHERE singleton_id=1;").decode().strip())
    dependencies=json.loads(run_sql("SELECT json_build_object('nestedEmployeePhones',(SELECT count(*) FROM employee_phones)," \
        "'visitorAccounts',(SELECT count(*) FROM visitor_accounts));").decode().strip())
    providers=json.loads(run_sql("SELECT coalesce(json_agg(json_build_object('id',p.id,'secret',p.secret,'version',p.version,'last4',p.api_key_last4," \
        "'rowDigest',encode(digest(to_jsonb(p)::text,'sha256'),'hex')) ORDER BY p.id),'[]'::json) FROM ai_providers p WHERE secret IS NOT NULL;").decode().strip())
    bridge=Path(__file__).with_name('credential_rewrap.cjs')
    if os.name=='posix' and str(node).lower().endswith('.exe'):
        bridge=subprocess.check_output(['wslpath','-w',str(bridge)],timeout=5).decode().strip()
    if environment.get('UTEN_SECRET_CIPHER_KEY'):
        raise ValueError('Dedicated SecretCipher key requires its reviewed migration path')
    payload={'currentHmac':environment['UTEN_HMAC_KEY'],'legacyHmac':legacy_hmac,
             'currentIssuer':environment['UTEN_JWT_ISSUER'],'legacyIssuer':'uten-imp-dev','rows':providers}
    result=subprocess.run([str(node),str(bridge)],input=canonical(payload),capture_output=True,timeout=30)
    if result.returncode:raise ValueError('Candidate credential rewrap verification failed')
    ai=json.loads(result.stdout)['rows']
    if {row['id'] for row in ai}!={row['id'] for row in providers}:raise ValueError('AI candidate scope differs')
    old_ai={row['id']:row for row in providers}
    for row in ai:
        if row['oldCipherSha256']!=hashlib.sha256(old_ai[row['id']]['secret'].encode()).hexdigest():
            raise ValueError('AI candidate input binding differs')
        if (row.get('plaintextPreserved') is not True or row.get('currentIssuerVerified') is not True
                or row.get('version')!=old_ai[row['id']]['version'] or not row.get('newCipher','').startswith('gh1:')):
            raise ValueError('AI candidate roundtrip evidence differs')
    changed_i=[row for row in rows if row['old_id_hash']!=row['new_id_hash']]
    changed_p=[row for row in rows if row['old_phone_hash']!=row['new_phone_hash']]
    def duplicates(key):
        values=[row[key] for row in rows if row[key] is not None]
        return len(values)-len(set(values))
    phone_groups={};identity_plain_groups={};phone_plain_groups={}
    for row in rows:
        if row['new_phone_hash'] is not None:phone_groups.setdefault(row['new_phone_hash'],set()).add(row['old_phone_hash'])
        for key,field,groups in [('new_id_hash','identity_equivalence',identity_plain_groups),
                                 ('new_phone_hash','phone_equivalence',phone_plain_groups)]:
            if row[key] is not None:groups.setdefault(row[key],set()).add(row.get(field))
    blockers={'identityCollisions':duplicates('new_id_hash'),
        'newPhoneEquivalenceCollisions':sum(len(values)>1 for values in phone_groups.values()),
        'differentIdentityPlaintextsWithSameDerivedHash':sum(len(values)>1 for values in identity_plain_groups.values()),
        'differentPhonePlaintextsWithSameDerivedHash':sum(len(values)>1 for values in phone_plain_groups.values()),
        'noncanonicalRows':sum(not row['canonical'] for row in rows),
        'unknownHistoricalHashValues':sum(not row['old_id_legacy_match'] for row in changed_i)+
                                     sum(not row['old_phone_legacy_match'] for row in changed_p),
        'unreviewedRelatedPhoneRows':dependencies['nestedEmployeePhones']+dependencies['visitorAccounts']}
    blockers['providerPlaceholderOrLast4Mismatch']=sum(row.get('notKnownPlaceholder') is not True or row.get('last4Matches') is not True for row in ai)
    proposal={'format':'uten-clone-integrity-candidate-v1','operationId':str(uuid.uuid4()),'configSha256':config_digest,
        'epochs':epochs,'rowsetSha256':digest(rows),'rows':rows,'oldProviders':providers,'providerCandidates':ai,
        'providerRowsetSha256':digest(providers),'oldHmacKeyRecovery':legacy_hmac,'oldIssuer':'uten-imp-dev'}
    plan={'format':proposal['format'],'operationId':proposal['operationId'],'configSha256':config_digest,
        'epochs':epochs,'rowsetSha256':proposal['rowsetSha256'],'providerRowsetSha256':proposal['providerRowsetSha256'],
        'identityHashChanges':len(changed_i),'phoneHashChanges':len(changed_p),
        'historicalHashValuesProvenByLegacyKey':sum(row['old_id_legacy_match'] is True for row in changed_i)+
                                               sum(row['old_phone_legacy_match'] is True for row in changed_p),
        'aiCredentialsToRewrap':sum(row['changed'] for row in ai),'blockers':blockers,
        'aiNonPlaceholderCredentials':sum(row.get('notKnownPlaceholder') is True for row in ai),
        'aiStoredLast4Matches':sum(row.get('last4Matches') is True for row in ai),
        'preexistingSharedPhoneHashRows':duplicates('new_phone_hash'),
        'existingUnindexedIdentityRowsPreserved':sum(row['old_id_hash'] is None for row in rows),
        'productionApplyImplemented':False,'applyAllowedInVerifiedClone':not any(blockers.values())}
    plan['proposalDigest']=digest(proposal)
    return plan,proposal


def apply_sql(proposal,expected_plan,encrypted_preimage_sha):
    if (expected_plan.get('proposalDigest')!=digest(proposal) or not expected_plan.get('applyAllowedInVerifiedClone')
            or not re.fullmatch(r'[a-f0-9]{64}',encrypted_preimage_sha)):
        raise ValueError('Clone maintenance evidence does not match its checked proposal')
    rows_json=literal(json.dumps(proposal['rows']))+'::jsonb'
    provider_rows=[]
    old={row['id']:row for row in proposal['oldProviders']}
    for row in proposal['providerCandidates']:
        if row['changed']:provider_rows.append({'id':row['id'],'old_secret':old[row['id']]['secret'],
            'old_version':old[row['id']]['version'],'new_secret':row['newCipher']})
    providers_json=literal(json.dumps(provider_rows))+'::jsonb'
    providers_before_json=literal(json.dumps(proposal['oldProviders']))+'::jsonb'
    epoch=proposal['epochs'];expected_changes=sum(row['old_id_hash']!=row['new_id_hash'] or row['old_phone_hash']!=row['new_phone_hash'] for row in proposal['rows'])
    return """
BEGIN;
SET LOCAL lock_timeout='5s';SET LOCAL statement_timeout='30s';
DO $guard$ BEGIN
 IF current_database()<>'drill' THEN RAISE EXCEPTION 'Clone database guard'; END IF;
 IF NOT pg_try_advisory_xact_lock(hashtextextended('uten-clone-hmac-integrity',0)) THEN RAISE EXCEPTION 'Maintenance busy'; END IF;
END $guard$;
LOCK TABLE employee_sensitive,ai_providers,authorization_state IN SHARE ROW EXCLUSIVE MODE;
DO $guard$ BEGIN
 IF (SELECT epoch FROM authorization_state WHERE singleton_id=1)<>AUTH_EPOCH
  OR (SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1)<>RESET_GENERATION
  OR (pg_control_system()).system_identifier::text<>SYSTEM_IDENTIFIER THEN RAISE EXCEPTION 'Epoch or database identity changed'; END IF;
END $guard$;
CREATE TEMP TABLE dr_hmac_candidate AS SELECT * FROM jsonb_to_recordset(ROWS_JSON) AS x(
 employee_id uuid,old_id_hash text,old_phone_hash text,new_id_hash text,new_phone_hash text,cipher_digest text,updated_at text);
CREATE TEMP TABLE dr_ai_candidate AS SELECT * FROM jsonb_to_recordset(PROVIDERS_JSON) AS x(
 id uuid,old_secret text,old_version bigint,new_secret text);
CREATE TEMP TABLE dr_ai_before AS SELECT * FROM jsonb_to_recordset(PROVIDERS_BEFORE_JSON) AS x(
 id uuid,secret text,version bigint,"rowDigest" text);
DO $guard$ BEGIN
 IF (SELECT count(*) FROM employee_sensitive)<>(SELECT count(*) FROM dr_hmac_candidate)
  OR EXISTS(SELECT 1 FROM dr_hmac_candidate c LEFT JOIN employee_sensitive s USING(employee_id) WHERE s.employee_id IS NULL)
  OR EXISTS(SELECT 1 FROM employee_sensitive s JOIN dr_hmac_candidate c USING(employee_id)
   WHERE s.id_card_hash IS DISTINCT FROM c.old_id_hash OR s.phone_hash IS DISTINCT FROM c.old_phone_hash
    OR encode(digest(coalesce(s.id_card_enc,'')||E'\\n'||coalesce(s.phone_enc,''),'sha256'),'hex')<>c.cipher_digest
    OR to_char(s.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')<>c.updated_at)
  OR EXISTS(SELECT 1 FROM dr_ai_candidate c LEFT JOIN ai_providers p USING(id)
    WHERE p.id IS NULL OR p.secret IS DISTINCT FROM c.old_secret OR p.version<>c.old_version)
  OR (SELECT count(*) FROM ai_providers WHERE secret IS NOT NULL)<>(SELECT count(*) FROM dr_ai_before)
  OR EXISTS(SELECT 1 FROM dr_ai_before c LEFT JOIN ai_providers p USING(id)
    WHERE p.id IS NULL OR encode(digest(to_jsonb(p)::text,'sha256'),'hex')<>c."rowDigest")
 THEN RAISE EXCEPTION 'Checked rowset changed'; END IF;
END $guard$;
CREATE TABLE IF NOT EXISTS public.dr_clone_integrity_audit(
 operation_id uuid PRIMARY KEY,plan_sha256 text NOT NULL,encrypted_preimage_sha256 text NOT NULL,
 actor_context text NOT NULL,hash_rows_changed bigint NOT NULL,provider_rows_changed bigint NOT NULL,
 authorization_epoch bigint NOT NULL,business_reset_generation bigint NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
WITH changed AS (UPDATE employee_sensitive s SET id_card_hash=c.new_id_hash,phone_hash=c.new_phone_hash
 FROM dr_hmac_candidate c WHERE s.employee_id=c.employee_id
 AND (s.id_card_hash IS DISTINCT FROM c.new_id_hash OR s.phone_hash IS DISTINCT FROM c.new_phone_hash) RETURNING 1)
SELECT set_config('dr.integrity.changed_hash_rows',(SELECT count(*)::text FROM changed),true);
WITH changed AS (UPDATE ai_providers p SET secret=c.new_secret,version=p.version+1,updated_at=now()
 FROM dr_ai_candidate c WHERE p.id=c.id AND p.secret=c.old_secret AND p.version=c.old_version RETURNING 1)
SELECT set_config('dr.integrity.changed_provider_rows',(SELECT count(*)::text FROM changed),true);
DO $guard$ BEGIN
 IF current_setting('dr.integrity.changed_hash_rows')::bigint<>EXPECTED_HASH_ROWS
  OR current_setting('dr.integrity.changed_provider_rows')::bigint<>EXPECTED_PROVIDER_ROWS THEN RAISE EXCEPTION 'Changed row count differs'; END IF;
END $guard$;
INSERT INTO public.dr_clone_integrity_audit VALUES(OPERATION_ID,PLAN_SHA,PREIMAGE_SHA,'ISOLATED_CLONE_REHEARSAL',
 current_setting('dr.integrity.changed_hash_rows')::bigint,current_setting('dr.integrity.changed_provider_rows')::bigint,
 AUTH_EPOCH,RESET_GENERATION,now());
COMMIT;
SELECT json_build_object('updatedEmployeeRows',(SELECT hash_rows_changed FROM dr_clone_integrity_audit WHERE operation_id=OPERATION_ID),
 'rewrappedAiRows',(SELECT provider_rows_changed FROM dr_clone_integrity_audit WHERE operation_id=OPERATION_ID),
 'auditRows',(SELECT count(*) FROM dr_clone_integrity_audit WHERE operation_id=OPERATION_ID));
""".replace('ROWS_JSON',rows_json).replace('PROVIDERS_BEFORE_JSON',providers_before_json).replace('PROVIDERS_JSON',providers_json) \
       .replace('AUTH_EPOCH',str(epoch['authorizationEpoch'])).replace('RESET_GENERATION',str(epoch['businessResetGeneration'])) \
       .replace('SYSTEM_IDENTIFIER',literal(epoch['systemIdentifier'])).replace('EXPECTED_HASH_ROWS',str(expected_changes)) \
       .replace('EXPECTED_PROVIDER_ROWS',str(len(provider_rows))).replace('OPERATION_ID',literal(proposal['operationId'])+'::uuid') \
       .replace('PLAN_SHA',literal(digest(expected_plan))).replace('PREIMAGE_SHA',literal(encrypted_preimage_sha))


def exercise(run_sql,inspect_info,container,environment,legacy_hmac,node,config_digest,seal_proposal,*,ai_only=False):
    assert_isolated(inspect_info,container)
    plan,proposal=check(run_sql,environment,legacy_hmac,node,config_digest)
    original_plan=plan
    if ai_only:
        # This is a separately declared credential operation, never an override of
        # the full PII plan. Its SQL/CAS scope proves no PII derivative is changed.
        proposal={**proposal,'scope':'AI_CREDENTIALS_ONLY','rows':[
            {**row,'new_id_hash':row['old_id_hash'],'new_phone_hash':row['old_phone_hash']} for row in proposal['rows']]}
        ai_blockers={'providerPlaceholderOrLast4Mismatch':original_plan['blockers']['providerPlaceholderOrLast4Mismatch']}
        plan={**plan,'scope':'AI_CREDENTIALS_ONLY','blockedPiiPlan':original_plan,
            'identityHashChanges':0,'phoneHashChanges':0,'blockers':ai_blockers,'applyAllowedInVerifiedClone':not any(ai_blockers.values())}
        plan['proposalDigest']=digest(proposal)
    if not plan['applyAllowedInVerifiedClone']:return {'state':'CLONE_CANDIDATE_BLOCKED','plan':plan}
    preimage_sha=seal_proposal(canonical({'plan':plan,'proposal':proposal}))
    applied=json.loads(run_sql(apply_sql(proposal,plan,preimage_sha)).decode().strip().splitlines()[-1])
    after,after_proposal=check(run_sql,environment,legacy_hmac,node,config_digest)
    if ai_only:
        projection=lambda rows:[{key:row[key] for key in ('employee_id','old_id_hash','old_phone_hash','cipher_digest','updated_at')} for row in rows]
        if projection(proposal['rows'])!=projection(after_proposal['rows']):
            raise ValueError('AI-only exercise changed a PII row')
        if after['aiCredentialsToRewrap']:raise ValueError('AI-only post-validation failed')
    elif any(after['blockers'].values()) or after['identityHashChanges'] or after['phoneHashChanges'] or after['aiCredentialsToRewrap']:
        raise ValueError('Post-repair clone validation failed')
    return {'state':'ISOLATED_CLONE_INTEGRITY_CANDIDATE_VERIFIED','plan':plan,'applied':applied,
        'after':after,'encryptedPreimageSha256':preimage_sha,'productionMutated':False,
        'companyHmacChanged':False,'piiCiphertextChanged':False,'piiIndexesChanged':not ai_only,
        'aiPlaintextPreserved':True,'aiCurrentCompanyIssuerVerified':True}
