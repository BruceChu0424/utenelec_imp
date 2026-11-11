"""Complete only this preparation run's newly created master identity.
Two read dependencies were found in the real category/cost UI. No old actor,
import preview, business row or mapping is changed; no HTTP login is performed.
"""
from pathlib import Path
import argparse,hashlib,json,psycopg2
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--seed',required=True);p.add_argument('--out',required=True);a=p.parse_args();out=Path(a.out)
if out.exists():raise SystemExit('Preserve completed identity fixture')
config=json.loads(Path(a.config).read_text(encoding='utf-8-sig'));assert config['jdbcUrl']=='jdbc:postgresql://127.0.0.1:26630/feedback'
source=Path(a.seed);seed=json.loads(source.read_text(encoding='utf-8-sig'));actor=seed['accounts']['masterImport'];tag=seed['fixtureTag'];assert actor['login']=='USR-b-masterImport-'+tag
with psycopg2.connect(host='127.0.0.1',port=26630,dbname='feedback',user=config['username'],password=config['password']) as db:
 with db.cursor() as c:
  c.execute('SELECT login_account,is_super_admin,must_change_password FROM users WHERE id=%s FOR UPDATE',(actor['userId'],));assert c.fetchone()==(actor['login'],False,False)
  c.execute("SELECT md5(jsonb_agg(to_jsonb(r) ORDER BY role_key)::text) FROM system_posting_style_roles r");roles=c.fetchone()[0]
  c.execute('SELECT md5(jsonb_agg(to_jsonb(o) ORDER BY user_id,permission_id)::text) FROM user_permission_overrides o WHERE user_id<>%s',(actor['userId'],));old=c.fetchone()[0]
  for code in ['material_category:view','currency:view']:
   c.execute("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT %s,id,'grant' FROM permissions WHERE code=%s",(actor['userId'],code));assert c.rowcount==1
  c.execute('SELECT md5(jsonb_agg(to_jsonb(o) ORDER BY user_id,permission_id)::text) FROM user_permission_overrides o WHERE user_id<>%s',(actor['userId'],));assert c.fetchone()[0]==old
  c.execute("SELECT md5(jsonb_agg(to_jsonb(r) ORDER BY role_key)::text) FROM system_posting_style_roles r");assert c.fetchone()[0]==roles
  c.execute("SELECT p.code FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=%s AND o.effect='grant' ORDER BY p.code",(actor['userId'],));grants=[r[0] for r in c.fetchall()]
  assert set(grants)==set(actor['permissions'])|{'material_category:view','currency:view'}
seed['accounts']['masterImport']['permissions']=grants
seed['profileCompletion']={'status':'prep identity completion only; no import/UI pass','sourceSeedSha256':hashlib.sha256(source.read_bytes()).hexdigest(),'onlyNewMasterUserId':actor['userId'],'addedReadDependencies':['material_category:view','currency:view'],'reason':'ProductCategoryPage calls protected category tree; cost tab calls CurrencyRepository.dict. No category/currency write permission granted.','otherActorsPermissionsUnchanged':True,'mappedFinanceRolesUnchanged':True}
out.write_bytes(json.dumps(seed,ensure_ascii=False,indent=2).encode('utf8'));print('Completed only the new master identity read dependencies; no business import.')
