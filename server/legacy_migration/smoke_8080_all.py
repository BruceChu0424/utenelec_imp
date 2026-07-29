import os, hmac, hashlib, base64, json, time, urllib.request, urllib.error, re
import psycopg2
ENV={}
with open(os.path.join(os.path.dirname(__file__), '..', '.env'), encoding='utf-8') as f:
    for line in f:
        if '=' in line and not line.strip().startswith('#'):
            k,v=line.strip().split('=',1); ENV[k]=v
SECRET=ENV['UTEN_JWT_SECRET'].encode()
m=re.search(r'//([^:/]+):(\d+)/(\w+)', ENV['UTEN_DB_URL']); host,port,db=m.group(1),int(m.group(2)),m.group(3)
c=psycopg2.connect(host=host,port=port,dbname=db,user=ENV['UTEN_DB_USER'],password=ENV['UTEN_DB_PASSWORD']); cur=c.cursor()
cur.execute("SELECT id,login_account FROM users WHERE status='active' AND COALESCE(must_change_password,false)=false AND COALESCE(is_deleted,false)=false LIMIT 1"); UID,ACC=cur.fetchone()
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=')
def sign(p):
    h=b64(json.dumps({'alg':'HS256','typ':'JWT'},separators=(',',':')).encode()); pl=b64(json.dumps(p,separators=(',',':')).encode())
    return (h+b'.'+pl+b'.'+b64(hmac.new(SECRET,h+b'.'+pl,hashlib.sha256).digest())).decode()
now=int(time.time())
PERMS=['stock:view','stock_doc:view','stock_doc:edit','purchase_report:view','goods:view','supplier:view','warehouse:view']
tok=sign({'sub':str(UID),'typ':'staff','acc':ACC,'perms':PERMS,'roles':[],'mcp':False,'iss':'uten-imp','iat':now,'exp':now+3600})
BASE='http://localhost:8080/api'
def get(p):
    req=urllib.request.Request(BASE+p,headers={'Authorization':'Bearer '+tok})
    try:
        r=urllib.request.urlopen(req,timeout=30); return r.status, r.read().decode()[:120]
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:120]
for ep in ['/stock/docs?docType=OTHER_OUT&size=1','/stock/balances?size=1','/stock/movements?size=1','/purchase/reports/monthly?limit=1','/purchase/reports/pending?limit=1','/master/suppliers/dict']:
    s,b=get(ep); print(f'{ep} -> {s} | {b[:60]}')
c.close()
