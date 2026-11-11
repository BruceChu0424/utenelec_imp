"""Prepare a reviewable copy; never edits or starts Root's live proxy."""
from pathlib import Path
import argparse,hashlib,json
p=argparse.ArgumentParser();p.add_argument('--original',required=True);a=p.parse_args()
base=Path(__file__).resolve().parent;original=Path(a.original);source=original.read_text(encoding='utf8')
start='    const started=Date.now();';end='    req.pipe(upstream);return;'
assert source.count(start)==1 and source.count(end)==1
candidate=source.replace("import http from 'node:http';","import http from 'node:http';\nimport {holdExactPost} from './submit_hold.mjs';")
candidate=candidate.replace(start,'    const forward=()=>{\n'+start)
candidate=candidate.replace(end,"    req.pipe(upstream);};\n    if(holdExactPost(req,res,url.pathname,path.join(base,'private'),forward,item=>log.write(JSON.stringify(item)+'\\n')))return;\n    forward();return;")
out=base/'proxy-with-hold-prep.mjs'
if out.exists():raise SystemExit('Preserve prepared proxy copy')
out.write_bytes(candidate.encode('utf8'))
(base/'proxy-copy-provenance.json').write_text(json.dumps({'status':'prep; not installed or running','original':str(original),'originalSha256':hashlib.sha256(original.read_bytes()).hexdigest(),'candidateSha256':hashlib.sha256(out.read_bytes()).hexdigest()},indent=2),encoding='utf8')
