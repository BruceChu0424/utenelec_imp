"""Git source fingerprints use blob bytes; acceptance artifacts use exact file bytes."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

out=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination',nargs='?',default='manifest.json')
parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2])
parser.add_argument('--kind',choices=['preverification','final-unified'],default='preverification')
parser.add_argument('--include',action='append',default=[],help='Limit artifact paths to a relative run directory; repeatable')
args=parser.parse_args()
root=args.source_root.resolve()
if args.kind=='final-unified' and not args.include:raise SystemExit('A final manifest must name only the frozen candidate run directories')
destination=out/args.destination
if destination.exists():raise SystemExit('Preserve the prior manifest; choose a new filename')
def git(*args):return subprocess.check_output(['git','-C',str(root),*args])
def sha(data):return hashlib.sha256(data).hexdigest()
sources=[
 'server/src/main/java/com/uten/imp/common/export/MasterExportSelection.java',
 'server/src/main/java/com/uten/imp/common/export/MasterSelectionPredicate.java',
 'server/src/main/java/com/uten/imp/common/export/ExportSelectionBudget.java',
 'server/src/main/java/com/uten/imp/common/export/TableColumnProjection.java',
 'server/src/main/java/com/uten/imp/common/export/ExportRowSelection.java',
 'server/src/main/java/com/uten/imp/features/master/export/MasterReportExportSource.java',
 'server/src/main/java/com/uten/imp/common/export/XlsxExportService.java',
 'server/src/test/java/com/uten/imp/businesschain/MasterDirectoryExportPostgresTest.java',
 'server/src/test/java/com/uten/imp/businesschain/CompleteExportScalePostgresTest.java',
]
data={'source':git('rev-parse','HEAD').decode().strip(),'kind':args.kind,'sourceRoot':str(root),'artifactIncludes':args.include,
      'sourceTreeObjects':{path:git('rev-parse','HEAD:'+path).decode().strip() for path in ['server/src/main','server/src/test','server/pom.xml']},
      'fingerprintContract':{'gitSource':'SHA-256 of exact Git blob bytes','artifact':'SHA-256 of exact filesystem bytes'},
      'sourceBlobs':{path:sha(git('show','HEAD:'+path)) for path in sources},'artifacts':{}}
for file in sorted(out.rglob('*')):
    if not file.is_file() or file==destination:continue
    relative=file.relative_to(out)
    if args.include and not any(relative==Path(prefix) or Path(prefix) in relative.parents for prefix in args.include):continue
    if any(part in {'build','cp-build','tmp','probes'} for part in relative.parts):continue
    data['artifacts'][relative.as_posix()]={'bytes':file.stat().st_size,'sha256':sha(file.read_bytes()),'byteSource':'raw-file'}
reports=[]
for file in sorted(out.rglob('TEST-*.xml')):
    relative=file.relative_to(out)
    if any(part in {'build','cp-build','tmp','probes'} for part in relative.parts):continue
    if args.include and not any(relative==Path(prefix) or Path(prefix) in relative.parents for prefix in args.include):continue
    suite=ET.parse(file).getroot()
    reports.append({'path':file.relative_to(out).as_posix(),'sha256':sha(file.read_bytes()),
                    'class':suite.get('name'),'tests':int(suite.get('tests','0')),
                    'failures':int(suite.get('failures','0')),'errors':int(suite.get('errors','0')),
                    'skipped':int(suite.get('skipped','0'))})
data['junitReports']=reports
destination.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({'manifest':str(destination),'artifactCount':len(data['artifacts']),'junitReports':reports},ensure_ascii=False,indent=2))
