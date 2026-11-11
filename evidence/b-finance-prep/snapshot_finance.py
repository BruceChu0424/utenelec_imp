"""Read-only pre/post audit of synthetic finance setup; no credential output."""
from pathlib import Path
import argparse,json,re,psycopg2
from psycopg2.extras import RealDictCursor
from datetime import datetime,timezone
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--out',required=True);a=p.parse_args()
out=Path(a.out)
if out.exists():raise SystemExit('Preserve previous audit')
config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'))
m=re.fullmatch(r'jdbc:postgresql://127\.0\.0\.1:(\d+)/(feedback|[a-z0-9_]*remediat[a-z0-9_]*)',config['jdbcUrl'])
if not m:raise SystemExit('Explicit synthetic loopback database required')
with psycopg2.connect(host='127.0.0.1',port=m[1],dbname=m[2],user=config['username'],password=config['password']) as db:
    db.set_session(readonly=True,isolation_level='REPEATABLE READ')
    with db.cursor(cursor_factory=RealDictCursor) as c:
        def rows(sql):c.execute(sql);return list(c.fetchall())
        result={'kind':'prep; read-only synthetic finance snapshot','capturedAtUtc':datetime.now(timezone.utc).isoformat(),'database':config['jdbcUrl'],
            'transaction':rows("SELECT current_setting('transaction_read_only') read_only,current_setting('transaction_isolation') isolation"),
            'roles':rows('SELECT r.role_key,r.description,r.required_category,r.style_id,r.updated_at,r.updated_by,s.code,s.name,s.category,s.status,s.is_deleted,system_posting_style_id(r.role_key) IS NOT NULL usable FROM system_posting_style_roles r LEFT JOIN payment_styles s ON s.id=r.style_id ORDER BY r.role_key'),
            'styles':rows('SELECT id,code,name,category,path,status,is_deleted,created_by,updated_by,created_at,updated_at FROM payment_styles ORDER BY id'),
            'accounts':rows('SELECT id,employee_id,login_account,is_super_admin,status,must_change_password,is_deleted,auth_version,version FROM users ORDER BY id'),
            'businessCounts':rows("SELECT 'purchase_returns' tab,count(*) count FROM purchase_returns UNION ALL SELECT 'subcontract_returns',count(*) FROM subcontract_returns UNION ALL SELECT 'gl_vouchers',count(*) FROM gl_vouchers UNION ALL SELECT 'stock_movements',count(*) FROM stock_movements UNION ALL SELECT 'ar_ap_ledger',count(*) FROM ar_ap_ledger UNION ALL SELECT 'production_material_analysis_commands',count(*) FROM production_material_analysis_commands")}
out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(json.dumps(result,ensure_ascii=False,indent=2,default=str).encode('utf8'))
print('Wrote read-only finance audit: '+str(out))
