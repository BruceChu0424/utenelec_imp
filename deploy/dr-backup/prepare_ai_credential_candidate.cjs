'use strict';
// READ ONLY production collection. This program has no database write path.
// stdin: local DPAPI-unwrapped legacy key JSON. stdout: sensitive candidate;
// its trusted caller must DPAPI/GPG protect stdout, never print or persist it raw.
const fs=require('node:fs'),cp=require('node:child_process'),crypto=require('node:crypto');
const bridge=require('./credential_rewrap.cjs');
const sha=value=>crypto.createHash('sha256').update(value).digest('hex');
try {
  const legacy=JSON.parse(fs.readFileSync(0,'utf8'));
  if(typeof legacy.legacyHmac!=='string'||!legacy.legacyHmac)throw new Error('INPUT');
  const remote=String.raw`import json,subprocess,shlex,hashlib,pathlib
try:
 raw=pathlib.Path('/etc/uten-imp/server.env').read_bytes();env={}
 for line in raw.decode().splitlines():
  if not line.strip() or line.lstrip().startswith('#'):continue
  parts=shlex.split(line,comments=False)
  if len(parts)!=1:raise ValueError('syntax')
  key,value=parts[0].split('=',1);env[key]=value
 if env.get('UTEN_SECRET_CIPHER_KEY'):raise ValueError('dedicated-key-path')
 query="""SET log_statement='none';SET log_min_error_statement='panic';BEGIN READ ONLY;
 SELECT json_build_object('rows',(SELECT coalesce(json_agg(json_build_object('id',p.id,'secret',p.secret,'version',p.version,
 'last4',p.api_key_last4,'rowDigest',encode(digest(to_jsonb(p)::text,'sha256'),'hex')) ORDER BY p.id),'[]'::json) FROM ai_providers p WHERE secret IS NOT NULL),
 'epochs',(SELECT json_build_object('authorizationEpoch',epoch,'businessResetGeneration',business_reset_generation,'systemIdentifier',(pg_control_system()).system_identifier::text) FROM authorization_state WHERE singleton_id=1));COMMIT;"""
 result=subprocess.run(['sudo','-n','-u','postgres','psql','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-d','uten_imp'],input=query.encode(),capture_output=True,timeout=60)
 if result.returncode:raise ValueError('read-only-query')
 data=json.loads(result.stdout);data.update(currentHmac=env['UTEN_HMAC_KEY'],currentIssuer=env['UTEN_JWT_ISSUER'],configSha256=hashlib.sha256(raw).hexdigest());print(json.dumps(data))
except Exception:raise SystemExit(1)
`;
  const result=cp.spawnSync('ssh',['-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
    '-o','ForwardAgent=no','-o','ConnectTimeout=15','-i','C:/Users/bruce/.ssh/uten_imp_admin_ed25519',
    'uten-imp-server','sudo','-n','python3','-'],{input:remote,encoding:'utf8',timeout:90000,maxBuffer:1024*1024,windowsHide:true});
  if(result.status!==0)throw new Error('COLLECTION');
  const data=JSON.parse(result.stdout);
  const candidates=bridge.candidate({...data,legacyHmac:legacy.legacyHmac,legacyIssuer:'uten-imp-dev'});
  if(data.rows.length!==2||candidates.length!==2||candidates.some(x=>!x.changed||!x.notKnownPlaceholder||!x.last4Matches))
    throw new Error('EXPECTED_TWO_REVIEWED_HISTORICAL_CREDENTIALS');
  const plan={format:'uten-ai-credential-candidate-v1',scope:'AI_PROVIDERS_SECRET_ONLY',operationId:crypto.randomUUID(),
    observedAt:new Date().toISOString(),configSha256:data.configSha256,currentIssuerSha256:sha(data.currentIssuer),
    epochs:data.epochs,providerRowsetSha256:sha(JSON.stringify(data.rows)),oldProviders:data.rows,
    candidates,productionApplyImplemented:false,piiIndexesChanged:false,companyHmacChanged:false,
    externalAiCalled:false};
  plan.candidateSha256=sha(JSON.stringify(plan));
  process.stdout.write(JSON.stringify(plan));
} catch { process.stderr.write('{"state":"READ_ONLY_AI_CANDIDATE_FAILED"}\n');process.exitCode=1; }
