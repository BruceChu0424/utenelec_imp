import sys,pathlib,json,re,datetime
from unittest.mock import patch
base=pathlib.Path(__file__).resolve().parent;root=base.parents[3]
sys.path.insert(0,str(root/'server/legacy_migration'));import verify_candidate as v
invalid=[p.name for p in sorted((root/'server/src/main/resources/db/migration').iterdir()) if p.suffix=='.sql' and re.fullmatch(r'V([0-9]+)__[A-Za-z0-9_]+[.]sql',p.name) is None]
result={'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Read-only current actual1009 source syntax. No company database/Main/source writes; expected legacy preflight failure preserved.','source':'374d8b8a3290a0b843fc72271298b6d104f01810d0eaf0735d27db3d2d7f2202','actualRejectedLegitimateFilenameCount':len(invalid),'actualRejectedLegitimateFilenames':invalid,'pythonIntUnderscoreMisread':{'999_10':int('999_10'),'999_1':int('999_1')}}
with patch.object(v.subprocess,'run') as git_run,patch.object(v.subprocess,'check_output') as git_output:
    try:v.verify(root,base/'not-a-manifest.tsv')
    except ValueError as error:result['actualException']=str(error)
    result['gitRunCalls']=git_run.call_count;result['gitOutputCalls']=git_output.call_count
assert len(invalid)==14 and result['actualException']=='invalid or non-regular migration resource' and result['gitRunCalls']==result['gitOutputCalls']==0
(base/'preflight-original-subversion-rejection.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,ensure_ascii=False))
