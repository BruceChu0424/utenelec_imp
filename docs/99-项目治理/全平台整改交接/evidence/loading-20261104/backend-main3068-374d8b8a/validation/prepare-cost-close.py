import json
from pathlib import Path
base=Path(__file__).resolve().parent
queue=json.loads((base/'queue-execution.json').read_text(encoding='utf-8-sig'));assert queue['state']=='completed' and queue['actualExitCode']==0
raw=(base/'backend-current-acceptance.json').read_bytes();acceptance=json.loads(raw);assert acceptance['green'] and acceptance['javaUniqueClasses']==61
pending=json.loads((base/'pending-cost-targets.json').read_text(encoding='utf-8'));plan=json.loads((base/'required-targets.json').read_text(encoding='utf-8'));assert pending['source']==plan['source']==acceptance['sourceAggregateSha256']
all_classes={c for g in plan['groups'].values() for c in g['classes']};assert not all_classes.intersection(pending['classes']) and len(pending['classes'])==4
copy=base/'pre-cost-61-acceptance.json';assert not copy.exists();copy.write_bytes(raw)
plan['groups'][pending['label']]={'classes':pending['classes'],'reason':pending['reason']}
(base/'required-targets.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(base/'final-extra-selection.txt').write_text(','.join(pending['classes'])+'\n',encoding='utf-8')
(base/'backend-current-acceptance.json').write_text(json.dumps({'green':False,'state':'pending_final_extra_four_class_whole','sourceAggregateSha256':plan['source'],'previous61CurrentAcceptance':'pre-cost-61-acceptance.json','sourceChanged':False},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'prepared':pending['label'],'requiredClassUnion':len(all_classes)+4,'sourceChanged':False}))
