"""Git source fingerprints use blob bytes; acceptance artifacts use exact file bytes."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[2]
out=Path(__file__).resolve().parent
destination=out/(sys.argv[1] if len(sys.argv)>1 else 'manifest.json')
if destination.exists():raise SystemExit('Preserve the prior manifest; choose a new filename')
def git(*args):return subprocess.check_output(['git','-C',str(root),*args])
def sha(data):return hashlib.sha256(data).hexdigest()
sources=[
 'server/src/main/java/com/uten/imp/common/export/MasterExportSelection.java',
 'server/src/main/java/com/uten/imp/common/export/ExportSelectionBudget.java',
 'server/src/main/java/com/uten/imp/common/export/TableColumnProjection.java',
 'server/src/main/java/com/uten/imp/common/export/ExportRowSelection.java',
 'server/src/main/java/com/uten/imp/features/master/export/MasterReportExportSource.java',
 'server/src/main/java/com/uten/imp/common/export/XlsxExportService.java',
 'server/src/test/java/com/uten/imp/businesschain/MasterDirectoryExportPostgresTest.java',
 'server/src/test/java/com/uten/imp/businesschain/CompleteExportScalePostgresTest.java',
]
data={'source':git('rev-parse','HEAD').decode().strip(),'kind':'preverification, not root final unified acceptance',
      'sourceTreeObjects':{path:git('rev-parse','HEAD:'+path).decode().strip() for path in ['server/src/main','server/src/test','server/pom.xml']},
      'fingerprintContract':{'gitSource':'SHA-256 of exact Git blob bytes','artifact':'SHA-256 of exact filesystem bytes'},
      'sourceBlobs':{path:sha(git('show','HEAD:'+path)) for path in sources},'artifacts':{}}
for file in sorted(out.rglob('*')):
    if not file.is_file() or file==destination:continue
    relative=file.relative_to(out)
    if any(part in {'build','cp-build','tmp','probes'} for part in relative.parts):continue
    data['artifacts'][relative.as_posix()]={'bytes':file.stat().st_size,'sha256':sha(file.read_bytes()),'byteSource':'raw-file'}
reports=[]
for file in sorted(out.glob('*/build/surefire-reports/TEST-*.xml')):
    suite=ET.parse(file).getroot()
    reports.append({'path':file.relative_to(root).as_posix(),'sha256':sha(file.read_bytes()),
                    'class':suite.get('name'),'tests':int(suite.get('tests','0')),
                    'failures':int(suite.get('failures','0')),'errors':int(suite.get('errors','0')),
                    'skipped':int(suite.get('skipped','0'))})
data['junitReports']=reports
destination.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({'manifest':str(destination),'artifactCount':len(data['artifacts']),'junitReports':reports},ensure_ascii=False,indent=2))
