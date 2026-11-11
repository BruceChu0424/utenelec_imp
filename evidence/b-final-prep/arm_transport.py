"""Arm exact real passthrough transport after Root explicitly opens its window.
No request/response business values are replaced. Never run during A's freeze.
"""
from pathlib import Path
import argparse,json,re
p=argparse.ArgumentParser();p.add_argument('--private',required=True);p.add_argument('--analysis',required=True);p.add_argument('--mode',choices=['hold','committed-response-loss'],required=True);p.add_argument('--tag');a=p.parse_args()
if not re.fullmatch('[0-9a-f-]{36}',a.analysis):raise SystemExit('Explicit synthetic analysis UUID required')
private=Path(a.private).resolve();file=private/'fault.json';value=json.loads(file.read_text()) if file.exists() else {}
path='/api/production/material-analyses/'+a.analysis+'/aggregate-orders/submit'
if a.mode=='hold':
    if not a.tag or not re.fullmatch('[a-zA-Z0-9_-]{1,80}',a.tag):raise SystemExit('New gate tag required')
    gate=private/'transport-holds'/a.tag
    if not (gate/'helper-ready.json').is_file():raise SystemExit('Warm and authorize the service helper before arming a UI hold')
    ready=json.loads((gate/'helper-ready.json').read_text())
    if ready['analysisId']!=a.analysis:raise SystemExit('Helper and transport analysis do not match')
    if (gate/'hold-ready.json').exists() or (gate/'release').exists():raise SystemExit('Preserve previous gate; choose a new tag')
    if value.get('holdNextPost'):raise SystemExit('Another exact hold is armed')
    value['holdNextPost']={'path':path,'tag':a.tag}
else:
    paths=value.setdefault('loseCommittedReplyPaths',[])
    if path in paths:raise SystemExit('This exact committed-response loss is already armed')
    paths.append(path)
temporary=private/'fault.next.tmp';temporary.write_text(json.dumps(value),encoding='utf8');temporary.replace(file)
print('Armed '+a.mode+' for exact POST '+path)
