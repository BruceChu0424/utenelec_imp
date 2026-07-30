#!/usr/bin/env python3
# 仓库管理 StockDoc API 端到端 smoke（自签 JWT，免登录）。
# 验证：list / detail / create / approve(写库存) / reverse(冲销)。
import os, hmac, hashlib, base64, json, time, urllib.request, urllib.error
import psycopg2

ENV = {}
with open(os.path.join(os.path.dirname(__file__), '..', '.env'), encoding='utf-8') as f:
    for line in f:
        if '=' in line and not line.strip().startswith('#'):
            k, v = line.strip().split('=', 1)
            ENV[k] = v

SECRET = ENV['UTEN_JWT_SECRET'].encode()
DB_URL = ENV['UTEN_DB_URL']  # jdbc:postgresql://localhost:5433/uten_imp
# 解析 host/port/db
import re
m = re.search(r'//([^:/]+):(\d+)/(\w+)', DB_URL)
host, port, db = m.group(1), int(m.group(2)), m.group(3)
conn = psycopg2.connect(host=host, port=port, dbname=db,
                        user=ENV['UTEN_DB_USER'], password=ENV['UTEN_DB_PASSWORD'])
cur = conn.cursor()
cur.execute("SELECT id, login_account FROM users WHERE status='active' AND COALESCE(must_change_password,false)=false AND COALESCE(is_deleted,false)=false LIMIT 1")
row = cur.fetchone()
if not row:
    raise SystemExit('no active user found')
USER_ID, ACC = row
print('using user', USER_ID, ACC)

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=')
def sign(payload):
    h = b64(json.dumps({'alg':'HS256','typ':'JWT'}, separators=(',',':')).encode())
    p = b64(json.dumps(payload, separators=(',',':')).encode())
    sig = hmac.new(SECRET, h + b'.' + p, hashlib.sha256).digest()
    return (h + b'.' + p + b'.' + b64(sig)).decode()

PERMS = ['stock_doc:view','stock_doc:edit','stock:view','goods:view','warehouses:view','supplier:view']
now = int(time.time())
token = sign({'sub': str(USER_ID), 'typ':'staff', 'acc': ACC, 'perms': PERMS, 'roles': [],
              'mcp': False, 'iss':'uten-imp', 'iat': now, 'exp': now+3600})

BASE = 'http://localhost:8082/api'
def call(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(BASE+path, data=data, method=method,
                                 headers={'Authorization':'Bearer '+token, 'Content-Type':'application/json'})
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status, json.loads(r.read().decode() or 'null')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

# 1. list
s, r = call('GET', '/stock/docs?docType=OTHER_OUT&size=2')
print('[list OTHER_OUT]', s, (r.get('total') if isinstance(r,dict) else r))
list_id = r['items'][0]['id'] if isinstance(r,dict) and r.get('items') else None
# 2. detail
if list_id:
    s, r = call('GET', '/stock/docs/'+list_id)
    print('[detail]', s, 'docType=', r.get('docType'), 'items=', len(r.get('items',[])) if isinstance(r,dict) else '?', 'status=', r.get('status'))

# 3. create 草稿 → approve(写库存) → reverse(冲销)，验证余额变化
cur.execute("SELECT id FROM warehouses LIMIT 1"); wh = cur.fetchone()[0]
cur.execute("SELECT id FROM goods LIMIT 1"); g = cur.fetchone()[0]
cur.execute("SELECT id FROM units LIMIT 1"); u = cur.fetchone()[0]
body = {'docType':'OTHER_OUT','billNo':'SMOKE-TEST-001','billDate':'2026-07-25',
        'warehouseId': wh, 'remark':'smoke',
        'items':[{'goodsId': g, 'unitId': u, 'unitRate': 1, 'qty': 5, 'amountLocal': 100}]}
s, r = call('POST', '/stock/docs', body)
print('[create]', s, 'id=', r.get('id') if isinstance(r,dict) else r, 'status=', r.get('status'))
nid = r['id']
# 余额前
cur.execute("SELECT qty FROM stock_balances WHERE warehouse_id=%s AND goods_id=%s", (wh, g))
before = cur.fetchone(); before = float(before[0]) if before else 0.0
print('[balance before approve]', before)
s, r = call('POST', '/stock/docs/'+nid+'/approve')
print('[approve]', s, 'status=', r.get('status') if isinstance(r,dict) else r)
cur.execute("SELECT qty FROM stock_balances WHERE warehouse_id=%s AND goods_id=%s", (wh, g))
after = cur.fetchone(); after = float(after[0]) if after else 0.0
print('[balance after approve]', after, '(expect -5)')
cur.execute("SELECT count(*) FROM stock_movements WHERE source_doc_id=%s", (nid,))
print('[movements for doc]', cur.fetchone()[0])
s, r = call('POST', '/stock/docs/'+nid+'/reverse')
print('[reverse]', s, 'status=', r.get('status') if isinstance(r,dict) else r)
cur.execute("SELECT qty FROM stock_balances WHERE warehouse_id=%s AND goods_id=%s", (wh, g))
rev = cur.fetchone(); rev = float(rev[0]) if rev else 0.0
print('[balance after reverse]', rev, '(expect back to', before, ')')
# 清理 smoke 单据
call('DELETE', '/stock/docs/'+nid)
print('[cleanup deleted smoke doc]')
conn.close()
