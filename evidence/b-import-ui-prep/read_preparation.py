from pathlib import Path
import argparse,hashlib,json,zipfile,xml.etree.ElementTree as E
from datetime import datetime,timezone
import psycopg2
from psycopg2.extras import RealDictCursor
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--root',required=True);p.add_argument('--out',required=True);a=p.parse_args();out=Path(a.out)
if out.exists():raise SystemExit('Preserve previous preparation evidence')
root=Path(a.root).resolve();config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'));assert config['jdbcUrl']=='jdbc:postgresql://127.0.0.1:26630/feedback'
result={'status':'prep: read only, no import or account changes','capturedAtUtc':datetime.now(timezone.utc).isoformat()}
with psycopg2.connect(host='127.0.0.1',port=26630,dbname='feedback',user=config['username'],password=config['password']) as db:
    db.set_session(readonly=True,isolation_level='REPEATABLE READ')
    with db.cursor(cursor_factory=RealDictCursor) as c:
        def rows(sql,*params):c.execute(sql,params if params else None);return list(c.fetchall())
        result['ordinaryActors']=rows("SELECT u.id,u.login_account,u.employee_id,u.is_super_admin,u.must_change_password,u.status,array_agg(p.code ORDER BY p.code) FILTER(WHERE o.effect='grant') grants FROM users u LEFT JOIN user_permission_overrides o ON o.user_id=u.id LEFT JOIN permissions p ON p.id=o.permission_id WHERE u.login_account LIKE 'USR-%' AND NOT u.is_deleted GROUP BY u.id ORDER BY u.login_account")
        result['roleMappings']=rows('SELECT role_key,style_id,system_posting_style_id(role_key) IS NOT NULL usable,updated_at FROM system_posting_style_roles ORDER BY role_key')
        result['goods']=rows('SELECT id,code,name,unit_id,category_id,owner_employee_id,status,app_status,bom_status FROM goods WHERE NOT is_deleted ORDER BY code')
        result['counts']=rows("SELECT 'goods' tab,count(*) count FROM goods UNION ALL SELECT 'goods_bom_items',count(*) FROM goods_bom_items UNION ALL SELECT 'gl_vouchers',count(*) FROM gl_vouchers UNION ALL SELECT 'finance_chart_codes',count(*) FROM finance_chart_codes UNION ALL SELECT 'finance_operating_report_notes',count(*) FROM finance_operating_report_notes UNION ALL SELECT 'finance_auxiliary_items',count(*) FROM finance_auxiliary_items")
files=['baseline/goods-extra-second-true.xlsx','baseline/bom-extra-second-true.xlsx','baseline/chart-true.xlsx','baseline/note-duplicate.xlsx','baseline/note-unknown.xlsx','baseline/cost-title-true.xlsx','baseline/voucher-empty-formula.xls','baseline/voucher-wrong-signature.xls','baseline/voucher-style.xls','web-fixtures/goods-legal.xlsx','web-fixtures/bom-legal.xlsx','web-fixtures/chart-legal.xlsx','web-fixtures/note-legal.xlsx','web-fixtures/cost-legal.xlsx','old-auxiliary.xlsx','auxiliary-extra-current.xlsx','old-vouchers.xls','old-balances.xls']
result['files']=[];n={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
for relative in files:
    f=root/'evidence/imports'/relative;raw=f.read_bytes();item={'path':str(f),'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
    if f.suffix=='.xlsx':
        with zipfile.ZipFile(f) as z:
            strings=[]
            if 'xl/sharedStrings.xml' in z.namelist():strings=[''.join(t.text or '' for t in si.findall('.//s:t',n)) for si in E.fromstring(z.read('xl/sharedStrings.xml')).findall('s:si',n)]
            sheets=[]
            for name in sorted(name for name in z.namelist() if name.startswith('xl/worksheets/sheet') and name.endswith('.xml')):
                cells=[]
                for cell in E.fromstring(z.read(name)).findall('.//s:c',n):
                    value=cell.find('s:v',n);text=value.text if value is not None else ''.join(t.text or '' for t in cell.findall('.//s:t',n))
                    if cell.attrib.get('t')=='s' and text is not None:text=strings[int(text)]
                    formula=cell.find('s:f',n)
                    if text or formula is not None:cells.append({'ref':cell.attrib['r'],'value':text,'formula':formula.text if formula is not None else None})
                sheets.append({'xml':name,'physicalNonemptyCellCount':len(cells),'cells':cells[:250]})
            item['sheets']=sheets
    result['files'].append(item)
out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(json.dumps(result,ensure_ascii=False,indent=2,default=str).encode('utf8'));print('Wrote read-only account/file preparation '+str(out))
