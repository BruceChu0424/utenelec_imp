import hashlib,json
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent
old=base/'capture-current-golden.original-v1.py';text=old.read_text(encoding='utf-8-sig')
text=text.replace("status=base/'golden-capture-state.json'","status=base/'golden-capture-v2-state.json'")
text=text.replace("rows=json.loads('\\n'.join(lines[1:-1]))","payload='\\n'.join(lines[1:-1]).strip()\n        # SQL jsonb_agg over a migrating but still-empty history is NULL, not completed evidence.\n        if not payload:continue\n        rows=json.loads(payload)")
dest=base/'capture-current-golden-v2.py';assert not dest.exists();dest.write_text(text,encoding='utf-8')
receipt={'atUtc':datetime.now(timezone.utc).isoformat(),'originalObserverActualExitCode':1,'originalState':'golden-capture-original-v1-state.json','originalLog':'golden-capture.log','originalScriptSha256':hashlib.sha256(old.read_bytes()).hexdigest(),'originalLogSha256':hashlib.sha256((base/'golden-capture.log').read_bytes()).hexdigest(),'failure':'JSONDecodeError when jsonb_agg was SQL NULL on an owned ordinary fixture whose history was still empty during actual migration. No complete history accepted.','v2Change':'Skip only empty/NULL aggregate as incomplete; unchanged BEGIN READ ONLY/ROLLBACK, exact1013 count/head1074/all script-version-checksum-description guards and no TEMPLATE/company connection.','v2ScriptSha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'businessTestsAffected':False,'frozen7411SourceChanged':False}
(base/'golden-observer-v1-failure-and-v2-repair.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8');print(json.dumps(receipt))
