import difflib,hashlib,json,subprocess
from pathlib import Path
from datetime import datetime,timezone
base=Path(__file__).resolve().parent;root=base.parents[3];review=root/'build/loading-validation/resume-integration-delta-20261106T011412025248Z/review.json';upstream=json.loads(review.read_text(encoding='utf-8'))
paths=[p for p in upstream['needsReview'] if p.startswith('server/')];dest=base/'cas-overlap-review';assert not dest.exists();dest.mkdir()
rows=[]
assert subprocess.check_output(['git','-C','D:/Projects/uten_imp','rev-parse','HEAD'],text=True).strip()==upstream['mainHead']
for index,path in enumerate(paths):
    before=subprocess.check_output(['git','-C','D:/Projects/uten_imp','show',upstream['mainHead']+':'+path]);task=(root/path).read_bytes()
    folder=dest/str(index);folder.mkdir();(folder/'main.raw').write_bytes(before);(folder/'task.raw').write_bytes(task)
    diff=''.join(difflib.unified_diff(before.decode('utf-8-sig').splitlines(keepends=True),task.decode('utf-8-sig').splitlines(keepends=True),fromfile='Main/'+path,tofile='Task/'+path,n=5))
    (folder/'diff.txt').write_text(diff,encoding='utf-8')
    record=next(e for e in upstream['rows'] if e['path']==path)
    assert hashlib.sha256(before).hexdigest()==record['currentMainSha256'] and hashlib.sha256(task).hexdigest()==record['taskSha256']
    rows.append({'index':index,'path':path,'mainSha256':hashlib.sha256(before).hexdigest(),'taskSha256':hashlib.sha256(task).hexdigest(),'diffSha256':hashlib.sha256(diff.encode()).hexdigest(),'diffLines':len(diff.splitlines()),'mainRaw':(folder/'main.raw').relative_to(root).as_posix(),'taskRaw':(folder/'task.raw').relative_to(root).as_posix(),'diffPath':(folder/'diff.txt').relative_to(root).as_posix()})
(dest/'inputs.json').write_text(json.dumps({'atUtc':datetime.now(timezone.utc).isoformat(),'mainHead':upstream['mainHead'],'sourceReviewSha256':hashlib.sha256(review.read_bytes()).hexdigest(),'rows':rows},indent=2)+'\n',encoding='utf-8')
print(json.dumps(rows,ensure_ascii=True))
