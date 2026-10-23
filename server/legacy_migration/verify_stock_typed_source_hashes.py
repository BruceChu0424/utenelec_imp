"""Hash original stock CSV bytes in an owned, network-none PostgreSQL container.

Called only after successful mapping-v16 run metadata has been verified. No
candidate connection, business DDL, source row, money or names are returned.
The container receives the exact sealed bytes, so quoted empty values, NULL,
numeric typmods and multiline text follow PostgreSQL COPY, not Python JSON.
"""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid


COLUMNS = ('legacy_id','bill_legacy_id','goods_legacy_id','color_legacy_id','qty','price','amount',
    'unit_legacy_id','unit_rate','weight','surplus_qty','count_qty','place_legacy_id',
    'upstream_legacy_id','source_doc_no','summary')
KINDS = ('TRANSFER','OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT','CHECK')


def verify_local_docker():
    """Match the coordinator's local reset endpoint policy without importing it.

    Check both the resolved context (including DOCKER_CONTEXT selection) and
    DOCKER_HOST independently. A local override must never hide a remote context.
    This is metadata only and must run before creating containers or reading any
    source payload. Endpoints and raw Docker diagnostics are never echoed.
    """
    try:
        endpoint=subprocess.check_output(
            ['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],
            text=True,stderr=subprocess.PIPE,timeout=15).strip()
    except (OSError,subprocess.SubprocessError,UnicodeError):
        raise ValueError('Local Docker endpoint could not be verified; raw diagnostics withheld') from None
    for effective in (endpoint,os.environ.get('DOCKER_HOST',endpoint)):
        if not (effective.startswith('npipe:') or effective.startswith('unix:')):
            raise ValueError('Remote Docker endpoints are not permitted for local stock source verification')


def typed_source_hash(source):
    """Return SHA of sorted file|itemID|complete-typed-source-row-SHA tuples."""
    verify_local_docker()
    directory=Path(source['_input_directory'])
    keys=source['_nonposting_keys']
    if len(keys)!=source['nonposting_items'] or len(set(map(tuple,keys)))!=len(keys):
        raise ValueError('Stock typed source identity inventory differs')
    name='uten-stock-source-hash-'+uuid.uuid4().hex[:12]
    created=False
    def command(args,data=None,timeout=60):
        try:return subprocess.run(args,input=data,capture_output=True,timeout=timeout)
        except (OSError,subprocess.SubprocessError):raise ValueError('Owned stock source hash PostgreSQL is unavailable') from None
    def require(ok):
        if not ok:raise ValueError('Owned stock source hash verification failed; raw server details withheld')
    try:
        result=command(['docker','run','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:16-alpine'])
        require(result.returncode==0);created=True
        for _ in range(60):
            if command(['docker','exec',name,'pg_isready','-U','postgres']).returncode==0:break
            time.sleep(.15)
        else:require(False)
        meta=command(['docker','inspect',name]);require(meta.returncode==0)
        require(json.loads(meta.stdout)[0]['HostConfig']['NetworkMode']=='none')
        sql=['CREATE EXTENSION pgcrypto;', '''CREATE TEMP TABLE source_stage (
 legacy_id int,bill_legacy_id int,goods_legacy_id int,color_legacy_id int,
 qty numeric(18,4),price numeric(18,4),amount numeric(18,4),unit_legacy_id int,
 unit_rate numeric(18,6),weight numeric(18,4),surplus_qty numeric(18,4),count_qty numeric(18,4),
 place_legacy_id int,upstream_legacy_id int,source_doc_no text,summary text,doc_type text);''',
             'CREATE TEMP TABLE source_keys(doc_type text,legacy_id int,PRIMARY KEY(doc_type,legacy_id));']
        for kind in KINDS:
            filename='stock_'+kind.lower()+'_i.csv';path=directory/filename;data=path.read_bytes()
            require(hashlib.sha256(data).hexdigest()==source['files'][filename]['sha256'])
            header=next(csv.reader(io.StringIO(data.decode('utf-8-sig')),delimiter='|'))
            require(tuple(header)==COLUMNS)
            # Private ephemeral file, no host copy or data mounted into another DB.
            require(command(['docker','exec','-i',name,'sh','-c','cat > /tmp/'+filename],data).returncode==0)
            sql.extend(["\\copy source_stage("+','.join(COLUMNS)+") FROM '/tmp/"+filename+"' WITH(FORMAT csv,DELIMITER '|',HEADER true)",
                        "UPDATE source_stage SET doc_type='"+kind+"' WHERE doc_type IS NULL;"])
        buffer=io.StringIO(newline='');writer=csv.writer(buffer,delimiter='|',lineterminator='\n')
        for kind,old in keys:
            require(kind in KINDS and type(old) is int and old>0);writer.writerow((kind,old))
        require(command(['docker','exec','-i',name,'sh','-c','cat > /tmp/source_keys.csv'],buffer.getvalue().encode()).returncode==0)
        sql.append("\\copy source_keys FROM '/tmp/source_keys.csv' WITH(FORMAT csv,DELIMITER '|')")
        sql.append('''SELECT jsonb_build_object('keys',(SELECT count(*) FROM source_keys),'matched',count(*),
 'sha256',encode(digest(coalesce(string_agg('stock_'||lower(s.doc_type)||'_i.csv|'||s.legacy_id::text||'|'||
 encode(digest((to_jsonb(s)-'doc_type')::text,'sha256'),'hex')||chr(10),'' ORDER BY
 'stock_'||lower(s.doc_type)||'_i.csv',s.legacy_id),''),'sha256'),'hex'))
 FROM source_stage s JOIN source_keys k ON k.doc_type=s.doc_type AND k.legacy_id=s.legacy_id;''')
        result=command(['docker','exec','-i',name,'psql','-X','-q','-At','-U','postgres','-v','ON_ERROR_STOP=1'],
                       ('\n'.join(sql)+'\n').encode('utf-8'),timeout=60)
        require(result.returncode==0)
        lines=result.stdout.decode().strip().splitlines();require(len(lines)==1)
        actual=json.loads(lines[0]);require(actual['keys']==len(keys) and actual['matched']==len(keys))
        require(re.fullmatch('[0-9a-f]{64}',actual['sha256']) is not None)
        return actual['sha256']
    finally:
        if created:
            result=command(['docker','rm','-f',name]);require(result.returncode==0)
