"""Record each final group against the frozen Git objects and a clean source tree."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

base = Path(__file__).resolve().parent
root = base.parents[1]
position, stage, *status = sys.argv[1:]
expected = '7b912287e53315228b469790ff066a9fab643e3c'
source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
assert source == expected, f'Frozen source changed: {source}'
paths = ['server/src/main', 'server/src/test', 'server/pom.xml', 'contracts']
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', *paths], cwd=root, check=True)
tree = subprocess.check_output(['git', '-c', 'core.quotePath=false', 'ls-tree', '-r', 'HEAD', '--', *paths], cwd=root)
proof = dict(stage=stage, position=position, source=source,
             timeUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
             trackedSourceClean=True, sourceGitTreeSha256=hashlib.sha256(tree).hexdigest())
build = Path(os.environ.get('C_FINAL_BUILD', str(base / 'maven/build')))
class_names = {
    'ImportColumnGuard.class', 'SpreadsheetEvidenceReader.class', 'SpreadsheetEvidenceReader$Value.class',
    'GoodsCostWorkbookParser.class', 'GoodsCostImportService.class', 'GoodsCostImportContracts$Preview.class',
    'CostImportEvidenceGuard.class', 'GoodsImportService.class', 'GoodsBomImportService.class',
    'FinanceChartWorkbookParser.class', 'FinanceChartService.class', 'FinanceChartContracts$Preview.class',
    'FinanceOperatingNoteParser.class', 'FinanceExpenseAnalysisService.class',
    'FinanceExpenseAnalysisContracts$NoteImportPreview.class', 'FinanceAccountingWorkbookParser.class',
    'FinanceAccountingImportService.class', 'FinanceAuxiliaryWorkbookParser.class',
    'FinanceAuxiliaryImportService.class', 'FinancialAuxiliarySourceReadAdapter.class',
}
classes = build / 'classes'
if classes.exists():
    proof['compiledClasses'] = {path.relative_to(classes).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in classes.rglob('*.class') if path.name in class_names}
if position == 'start':
    proof['sourceGitObjects'] = [dict(path=line.split('\t', 1)[1], blob=line.split('\t', 1)[0].split()[-1])
                                 for line in tree.decode('utf8').splitlines()]
else:
    previous = json.loads((base / f'{stage}-start.json').read_text(encoding='utf8'))
    assert previous['source'] == source
    assert previous['sourceGitTreeSha256'] == proof['sourceGitTreeSha256']
    if previous.get('compiledClasses'):
        assert previous['compiledClasses'] == proof['compiledClasses'], 'Compiled product classes changed during group'
    proof['sameSourceObjects'] = True
    proof['exit'] = int(status[0])
target = base / f'{stage}-{position}.json'
with target.open('x', encoding='utf8', newline='\n') as stream:
    json.dump(proof, stream, ensure_ascii=False, indent=2)
    stream.write('\n')
print(f'{stage} {position} source={source} clean=true objects={proof["sourceGitTreeSha256"]}')
