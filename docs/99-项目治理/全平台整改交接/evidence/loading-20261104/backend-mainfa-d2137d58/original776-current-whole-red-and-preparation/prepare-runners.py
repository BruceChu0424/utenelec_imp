from pathlib import Path
base=Path(__file__).resolve().parent
old=(base.parent/'main-6fb-crosswalk-qualified/capture-current-golden.py').read_text(encoding='utf-8-sig')
text=old.replace("base/'source-input.json'","base/'complete-source-input.json'").replace('target-loading-main-6fb-version-identity','target-loading-main-fa-final').replace('1010','1013').replace('1071','1074')
text=text.replace("environment.get('POSTGRES_DB')!='uten_imp'","environment.get('POSTGRES_DB') not in {'uten_imp','application_chain'}").replace("'-d','uten_imp'","'-d',environment['POSTGRES_DB']")
(base/'capture-current-golden.py').write_text(text,encoding='utf-8')
for filename in ['compile.ps1','run-suite.ps1']:
    p=base/filename;text=p.read_text(encoding='utf-8-sig')
    marker="$taskSource=Get-Content -Raw -LiteralPath (Join-Path $taskEvidence 'complete-source-input.json') | ConvertFrom-Json" if filename=='compile.ps1' else "$taskSource=Get-Content -Raw -LiteralPath (Join-Path $taskEvidenceRoot 'complete-source-input.json') | ConvertFrom-Json"
    gate="\n& 'C:/Program Files/LibreOffice/program/python.exe' 'build/loading-validation/main-fa-final/verify-source.py' *> 'build/loading-validation/main-fa-final/"+filename[:-4]+"-source-preflight.log'\nif ($LASTEXITCODE -ne 0) { throw 'Complete source preflight refused drift' }"
    assert marker in text;text=text.replace(marker,marker+gate);p.write_text(text,encoding='utf-8')
