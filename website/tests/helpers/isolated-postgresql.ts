import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PrismaClient as PostgresqlClient } from '../../generated/postgresql';

const websiteRoot=path.resolve(fileURLToPath(new URL('../..',import.meta.url)));
const workspaceRoot=path.dirname(websiteRoot);
const prefix='uten_website_cms_test_';
const namePattern=/^uten_website_cms_test_[a-z0-9_]{1,38}$/;
const host='127.0.0.1',port='55439';
export const postgresqlTestsEnabled=()=>process.env.UTEN_TEST_POSTGRESQL==='1';

type Evidence={databaseName:string;host:string;port:number;created:boolean;migrationsApplied:boolean;
  dropped:boolean;createdAt:string;disposedAt?:string;label:string};

/** Opt-in local PostgreSQL only. Never reads, migrates or drops the running site database. */
export async function createIsolatedPostgresqlDatabase(label:string) {
  if(!postgresqlTestsEnabled())throw new Error('PostgreSQL tests require UTEN_TEST_POSTGRESQL=1');
  if(!/^[a-z0-9_]{1,12}$/.test(label))throw new Error('Invalid isolated test label');
  let config:Record<string,unknown>;
  try {config=JSON.parse(await readFile(path.join(workspaceRoot,'.local-artifacts/website-imp/local-config.json'),'utf8')) as Record<string,unknown>;}
  catch {throw new Error('The local PostgreSQL test credentials could not be loaded');}
  if(typeof config.databaseUser!=='string'||!config.databaseUser||typeof config.databasePassword!=='string'||!config.databasePassword)
    throw new Error('Local PostgreSQL test credentials are incomplete');
  const redact=(input:string)=>{
    let value=input.replace(/postgres(?:ql)?:\/\/[^\s"'<>]+/gi,'postgresql://[redacted]');
    for(const [key,secret]of Object.entries(config)) {
      if(typeof secret!=='string'||!secret)continue;
      if(key==='databaseUser') {
        const escaped=secret.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
        value=value.replace(new RegExp(`(?<![A-Za-z0-9_])${escaped}(?![A-Za-z0-9_])`,'g'),'[redacted-user]');
      } else value=value.replaceAll(secret,'[redacted]').replaceAll(encodeURIComponent(secret),'[redacted]');
    }
    return value;
  };
  const databaseName=`${prefix}${label}_${Date.now().toString(36)}_${randomBytes(4).toString('hex')}`;
  if(!namePattern.test(databaseName)||databaseName.length>63)throw new Error('Unsafe generated test database name');
  const adminUrl=new URL(`postgresql://${host}:${port}/postgres`);
  adminUrl.username=config.databaseUser;adminUrl.password=config.databasePassword;
  adminUrl.searchParams.set('connection_limit','1');
  const targetUrl=new URL(adminUrl);targetUrl.pathname=`/${databaseName}`;targetUrl.searchParams.set('connection_limit','4');
  const databaseUrl=targetUrl.toString();
  const admin=new PostgresqlClient({datasources:{db:{url:adminUrl.toString()}},log:[]});
  const client=new PostgresqlClient({datasources:{db:{url:databaseUrl}},log:[]});
  const evidence:Evidence={databaseName,host,port:Number(port),created:false,migrationsApplied:false,dropped:false,
    createdAt:new Date().toISOString(),label};
  const evidenceDir=path.join(workspaceRoot,'.local-artifacts/website-imp/postgresql-tests');
  const saveEvidence=async()=>{await mkdir(evidenceDir,{recursive:true});await writeFile(path.join(evidenceDir,`${databaseName}.json`),JSON.stringify(evidence,null,2)+'\n','utf8');};
  let disposed=false;
  const ownedDatabase=async()=>{
    const rows=await admin.$queryRawUnsafe<{datname:string;owner:string}[]>(
      'SELECT datname, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname=$1',databaseName);
    if(rows.length!==1||rows[0].datname!==databaseName||rows[0].owner!==config.databaseUser)
      throw new Error('Isolated test database ownership could not be verified');
  };
  const dispose=async()=>{
    if(disposed)return;
    await client.$disconnect();
    try {
      if(evidence.created) {
        if(!namePattern.test(databaseName)||targetUrl.hostname!==host||targetUrl.port!==port||targetUrl.pathname!==`/${databaseName}`)
          throw new Error('Refusing unsafe test database cleanup');
        await ownedDatabase();
        // FORCE terminates only sessions connected to this uniquely generated test database.
        await admin.$executeRawUnsafe(`DROP DATABASE "${databaseName}" WITH (FORCE)`);
        const remaining=await admin.$queryRawUnsafe<{datname:string}[]>('SELECT datname FROM pg_database WHERE datname=$1',databaseName);
        if(remaining.length)throw new Error('Isolated test database cleanup did not complete');
        evidence.dropped=true;
      }
      disposed=true;evidence.disposedAt=new Date().toISOString();
      await saveEvidence();
    } catch(error) {
      await saveEvidence();
      throw new Error(redact(error instanceof Error?error.message:String(error)));
    } finally {await admin.$disconnect();}
  };
  const runNode=(script:string,args:string[],environment:Record<string,string|undefined>={})=>{
    const outcome=spawnSync(process.execPath,[script,...args],{cwd:websiteRoot,encoding:'utf8',windowsHide:true,
      timeout:180_000,maxBuffer:16*1024*1024,env:{...process.env,...environment,DATABASE_URL:databaseUrl}});
    return {status:outcome.status,stdout:redact(outcome.stdout||''),stderr:redact((outcome.stderr||'')+(outcome.error?'\n'+String(outcome.error):''))};
  };
  try {
    const connected=await admin.$queryRawUnsafe<{name:string}[]>('SELECT current_database() AS name');
    if(connected[0]?.name!=='postgres')throw new Error('The test administrator connection is not the management database');
    const collision=await admin.$queryRawUnsafe<{datname:string}[]>('SELECT datname FROM pg_database WHERE datname=$1',databaseName);
    if(collision.length)throw new Error('Generated test database name already exists');
    await admin.$executeRawUnsafe(`CREATE DATABASE "${databaseName}"`);
    evidence.created=true;await ownedDatabase();await saveEvidence();
    const migration=runNode(path.join(websiteRoot,'node_modules/prisma/build/index.js'),
      ['migrate','deploy','--schema','prisma/postgresql/schema.prisma']);
    if(migration.status!==0)throw new Error(`Isolated PostgreSQL migration failed\n${migration.stdout}\n${migration.stderr}`);
    const selected=await client.$queryRawUnsafe<{name:string}[]>('SELECT current_database() AS name');
    if(selected[0]?.name!==databaseName)throw new Error('PostgreSQL test client is not connected to its isolated database');
    evidence.migrationsApplied=true;await saveEvidence();
  } catch(error) {
    try {await dispose();}catch {throw new Error('PostgreSQL test setup failed and cleanup needs review; inspect the isolated evidence file');}
    throw new Error(redact(error instanceof Error?error.message:String(error)));
  }
  return {databaseName,databaseUrl,client,dispose,runNode};
}
