"""Extract safe shape counts from a preserved Java Map diagnostic (no SQL or bindings)."""
from pathlib import Path
import json
import re
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
if target.exists():
    raise SystemExit('Preserve the existing derived profile')
line = next(text for text in source.read_text(encoding='utf8',errors='replace').splitlines()
            if text.startswith('[aggregate-submit-20-jdbc]'))
def table(name, value):
    match = re.search(r'\b'+name+r'=\{([^}]*)\}',line)
    return {key:value(raw) for item in match.group(1).split(', ') if item
            for key,raw in [item.split('=',1)]}
counts=table('sqlFingerprints',int)
durations=table('sqlNanos',int)
labels=table('sqlLabels',str)
summary={}
for fingerprint,duration in durations.items():
    item=summary.setdefault(labels[fingerprint],{'calls':0,'milliseconds':0})
    item['calls']+=counts[fingerprint]
    item['milliseconds']+=duration/1_000_000
result={'sourceRawLog':str(source.absolute()),
        'labels':sorted([{'label':key,**value} for key,value in summary.items()],key=lambda item:-item['milliseconds']),
        'topShapes':sorted([{'fingerprint':key,'label':labels[key],'calls':counts[key],'milliseconds':value/1_000_000}
                            for key,value in durations.items()],key=lambda item:-item['milliseconds'])[:25]}
target.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({'labels':result['labels'][:12],'topShapes':result['topShapes'][:12]},ensure_ascii=False,indent=2))
