"""Frozen D3 runner metadata. Source uses Git blob bytes; artifacts use exact raw file bytes."""
from pathlib import Path
from collections import Counter
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE=Path(__file__).resolve().parent
INPUTS=['server/src/main','server/src/test','server/pom.xml','contracts','assets/fonts']
BLOBS=[
 'server/src/main/java/com/uten/imp/common/export/MasterExportSelection.java',
 'server/src/main/java/com/uten/imp/common/export/MasterSelectionPredicate.java',
 'server/src/main/java/com/uten/imp/common/export/ExportSelectionBudget.java',
 'server/src/main/java/com/uten/imp/common/export/ExportRowSelection.java',
 'server/src/main/java/com/uten/imp/common/export/TableColumnProjection.java',
 'server/src/main/java/com/uten/imp/common/export/XlsxExportService.java',
 'server/src/main/java/com/uten/imp/features/master/export/MasterReportExportSource.java',
 'server/src/test/java/com/uten/imp/businesschain/MasterDirectoryExportPostgresTest.java',
 'server/src/test/java/com/uten/imp/businesschain/CompleteExportScalePostgresTest.java',
 'server/src/test/java/com/uten/imp/features/reporting/export/ReportExportQueuePostgresTest.java',
 'evidence/scale/PhysicalXlsxScale.java']
def sha(raw):return hashlib.sha256(raw).hexdigest()
def write_new(path,data):
    with path.open('x',encoding='utf8',newline='\n') as stream:json.dump(data,stream,ensure_ascii=False,indent=2)
def git(root,*args):return subprocess.check_output(['git','-C',str(root),*args])
def snapshot(root):
    return {'source':git(root,'rev-parse','HEAD').decode().strip(),
      'trees':{p:git(root,'rev-parse','HEAD:'+p).decode().strip() for p in INPUTS},
      'dirtyCode':git(root,'diff','--name-only','HEAD','--',*INPUTS).decode().splitlines(),
      'untrackedCode':git(root,'ls-files','--others','--exclude-standard','--','server/src','contracts').decode().splitlines(),
      'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
def code_ok(value,revision):return value['source']==revision and not(value['dirtyCode'] or value['untrackedCode'])
def read_json(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def exit_code(path):
    try:return int(path.read_text(encoding='utf-8-sig').strip())
    except (FileNotFoundError,ValueError):return None

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('operation',choices=['begin','physical-input','end','seal'])
parser.add_argument('--workspace',type=Path,required=True)
parser.add_argument('--revision',required=True)
parser.add_argument('--out',type=Path,required=True)
parser.add_argument('--selector')
args=parser.parse_args();root=args.workspace.resolve();out=args.out.resolve()
if not re.fullmatch('[0-9a-f]{40}',args.revision):raise SystemExit('The exact Root-frozen SHA is required')

if args.operation=='begin':
    source=snapshot(root)
    if not code_ok(source,args.revision):raise SystemExit('Frozen source differs or owning inputs are dirty')
    source.update({'sourceStart':source['source'],'expectedRevision':args.revision,
      'kind':'final-candidate-execution; begins only after Root freeze','selector':args.selector,
      'mainAtStart':git(root,'rev-parse','refs/heads/main').decode().strip(),
      'sourceGitBlobSha256':{p:sha(git(root,'show',args.revision+':'+p)) for p in BLOBS},
      'runnerOrigin':{p.name:sha(p.read_bytes()) for p in [HERE/'run-final-d3.ps1',Path(__file__)]}})
    write_new(out/'source-start.json',source)
    write_new(out/'original-23-inventory.json',read_json(HERE/'original-23-inventory.json'))
elif args.operation=='physical-input':
    source=snapshot(root)
    if not code_ok(source,args.revision):raise SystemExit('Source changed before physical generation')
    relative='evidence/scale/PhysicalXlsxScale.java';raw=git(root,'show',args.revision+':'+relative)
    target=out/'physical/inputs/PhysicalXlsxScale.java'
    with target.open('xb') as stream:stream.write(raw)
    writer=out/'build/classes/com/uten/imp/common/export/XlsxExportService.class'
    write_new(out/'physical/input-source.json',{'source':args.revision,'helperPath':relative,'helperGitBlobSha256':sha(raw),
      'actualHelperRawEqualsFrozenBlob':target.read_bytes()==raw,'compiledWriterSha256':sha(writer.read_bytes())})
elif args.operation=='end':
    source=snapshot(root);source.update({'sourceStart':args.revision,'sourceEnd':source['source'],
      'kind':'execution-end, not a passing verdict','mavenExit':exit_code(out/'logs/maven.exit'),
      'physicalExit':exit_code(out/'physical/physical.exit'),'sourceUnchanged':code_ok(source,args.revision)})
    write_new(out/'source-end.json',source)
else:
    problems=[];start=read_json(out/'source-start.json')
    end=read_json(out/'source-end.json') if (out/'source-end.json').exists() else None
    if end is None or not code_ok(end,args.revision):problems.append('missing end receipt or changed source')
    maven=exit_code(out/'logs/maven.exit');physical=exit_code(out/'physical/physical.exit')
    if maven!=0:problems.append('Maven did not exit 0; 255/missing remains interrupted or incomplete')
    if physical!=0:problems.append('Physical generation did not exit 0')
    expected=Counter((c['class'],c['name']) for c in read_json(out/'original-23-inventory.json')['cases'])
    actual=Counter();suites=[]
    for path in sorted((out/'reports').glob('TEST-*.xml')):
        try:suite=ET.parse(path).getroot()
        except ET.ParseError:
            problems.append('incomplete/unparseable raw JUnit XML: '+path.name);continue
        counts={k:int(suite.get(k,'0')) for k in ['tests','failures','errors','skipped']}
        suites.append({'file':str(path.relative_to(out)),**counts})
        for case in suite.findall('testcase'):actual[(case.get('classname',suite.get('name')),case.get('name'))]+=1
        if counts['failures'] or counts['errors'] or counts['skipped']:problems.append('failed/error/skipped JUnit suite: '+suite.get('name'))
    if expected-actual:problems.append('original 23 cases are missing')
    log=(out/'logs/maven.log').read_text(encoding='utf8',errors='replace') if (out/'logs/maven.log').exists() else ''
    physical_log=(out/'physical/physical.log').read_text(encoding='utf8',errors='replace') if (out/'physical/physical.log').exists() else ''
    assertions=[line for line in log.splitlines() if line.startswith(('D3_','D3-'))]
    for required in ['selected=50001 matching=50002 excluded=1 ordered=50001','cancellation=preserved missing=rejected revokedAuthority=rejected',
                     'rows=100000 batches=1000','exactSum=123450.0000']:
        if required not in log:problems.append('missing authoritative assertion: '+required)
    oracle=re.search(r'orderHash=([a-f0-9]{64}) sourceOrderHash=([a-f0-9]{64})',log)
    if not oracle or oracle.group(1)!=oracle.group(2):problems.append('independent SQL order/amount hash is absent or mismatched')
    if 'rows=1048600 sheets=2 last=R1048599' not in physical_log or 'cancelledFilePublished=false leftoverTableTempDirs=0' not in physical_log:
        problems.append('physical 1048600-row/two-sheet/readback/cancellation evidence is absent')
    selected=re.search(r'D3_SELECTED_XLSX .*?physicalDataRows=50001.*?exactQuantityRows=50001.*?bytes=(\d+) sha256=([a-f0-9]{64}) file=([^\r\n]+)',log)
    if not selected:problems.append('real selected workbook evidence is absent')
    else:
        book=Path(selected.group(3))
        if not book.is_file() or book.stat().st_size!=int(selected.group(1)) or sha(book.read_bytes())!=selected.group(2):problems.append('selected workbook raw bytes do not match the log')
    leftovers=[str(p) for folder in [out/'tmp-maven',out/'physical/tmp'] for p in folder.glob('uten-table-sync-*')]
    if leftovers:problems.append('temporary workbook directories remain')
    if (out/'physical/input-source.json').exists():
        inp=read_json(out/'physical/input-source.json');writer=out/'build/classes/com/uten/imp/common/export/XlsxExportService.class'
        if sha(writer.read_bytes())!=inp['compiledWriterSha256']:problems.append('writer class changed after physical generation')
    result={'actualSource':args.revision,'kind':'D3-scale-subgroup-only','status':'passed' if not problems else 'failed-or-incomplete','problems':problems,
      'mavenExit':maven,'physicalExit':physical,'originalCasesRetained':sum((expected&actual).values()),'originalExpected':23,
      'totalCases':sum(actual.values()),'extraCases':[list(k) for k in (actual-expected)],'suites':suites,
      'assertionLogLines':assertions,'physicalLogLines':physical_log.splitlines(),'leftoverTableTempDirectories':leftovers,
      'scope':'actual PG/service tests + separate synthetic physical writer; not ordinary Web login or Win7 target acceptance'}
    write_new(out/'acceptance.json',result)
    artifacts={}
    for path in sorted(out.rglob('*')):
        if not path.is_file() or any(p in {'build','dependency-build','tmp-maven','tmp','probes'} for p in path.relative_to(out).parts):continue
        artifacts[path.relative_to(out).as_posix()]={'bytes':path.stat().st_size,'rawSha256':sha(path.read_bytes())}
    write_new(out/'manifest.json',{'actualSource':args.revision,'gitInputTrees':start['trees'],'sourceGitBlobSha256':start['sourceGitBlobSha256'],
      'fingerprintContract':{'source':'exact Git blob bytes/tree objects','artifact':'exact raw file bytes'},'artifacts':artifacts})
    print(json.dumps({'status':result['status'],'source':args.revision,'originalCasesRetained':result['originalCasesRetained'],'totalCases':result['totalCases'],'problems':problems},ensure_ascii=False))
    sys.exit(0 if not problems else 1)
