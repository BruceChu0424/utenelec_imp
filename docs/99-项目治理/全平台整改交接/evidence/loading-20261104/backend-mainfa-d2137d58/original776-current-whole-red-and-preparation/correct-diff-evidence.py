import difflib,hashlib,json
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3];folder=base/'cas-overlap-review';p=folder/'inputs.json';raw=p.read_bytes();old=folder/'inputs.before-canonical-diff.json';assert not old.exists();old.write_bytes(raw);data=json.loads(raw)
for row in data['rows']:
    main=(root/row['mainRaw']).read_bytes();task=(root/row['taskRaw']).read_bytes()
    diff=''.join(difflib.unified_diff(main.decode('utf-8-sig').splitlines(),task.decode('utf-8-sig').splitlines(),fromfile='Main/'+row['path'],tofile='Task/'+row['path'],n=5,lineterm='\n'))
    # splitlines removes source line terminators; join with explicit LF for a stable standalone diff.
    diff='\n'.join(difflib.unified_diff(main.decode('utf-8-sig').splitlines(),task.decode('utf-8-sig').splitlines(),fromfile='Main/'+row['path'],tofile='Task/'+row['path'],n=5,lineterm=''))+'\n'
    target=(root/row['diffPath']).with_name('canonical-diff.txt');target.write_bytes(diff.encode('utf-8'))
    row['originalDiffPath']=row['diffPath'];row['originalClaimedDiffSha256']=row['diffSha256'];row['originalObservedDiffSha256']=hashlib.sha256((root/row['diffPath']).read_bytes()).hexdigest()
    row['diffPath']=target.relative_to(root).as_posix();row['diffSha256']=hashlib.sha256(target.read_bytes()).hexdigest()
data['evidenceCorrection']='Initial diff builder hashed Python string before Windows newline expansion. Original raw Main/Task and old diff/inputs preserved; canonical LF diff now hashed from actual persisted bytes. No production/test/source modifications.'
p.write_bytes((json.dumps(data,ensure_ascii=False,indent=2)+'\n').encode('utf-8'));print('Corrected canonical diff evidence for14 source-bound paths; original snapshots retained')
