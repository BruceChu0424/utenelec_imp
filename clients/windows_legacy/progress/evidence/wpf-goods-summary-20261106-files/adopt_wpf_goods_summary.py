from pathlib import Path
import datetime,hashlib,json,os,subprocess,tempfile
ROOT=Path('D:/Projects/uten_imp').resolve();OUT=ROOT/'build/loading-validation/wpf-goods-summary-20261106'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args],env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
def main():
 review=json.loads((OUT/'v4-review.json').read_bytes());validation=json.loads((OUT/'v4-validation.json').read_bytes());TREE=OUT/review['tree']
 if validation['actualExitCode'] or len(validation['actualRuns'])!=8 or any(x['actualExitCode'] for x in validation['actualRuns']):raise RuntimeError('Final actual two-architecture checks are not all green')
 for row in validation['actualRuns']:
  if sha(OUT/(row['name']+'.log'))!=row['logSha256']:raise RuntimeError('Final actual log drift')
 before=json.loads((OUT/'inputs-before.json').read_bytes())
 for n,h in before.items():
  if sha(ROOT/n)!=h:raise RuntimeError('Fresh owning Main dependency/source preimage drift: '+n)
 for row in review['leaves']:
  n=row['path'];p=ROOT/n
  if row['beforeSha256'] is None:
   if p.exists():raise RuntimeError('New Main leaf now exists: '+n)
  elif sha(p)!=row['beforeSha256']:raise RuntimeError('Fresh Main target preimage drift: '+n)
  if sha(TREE/n)!=row['proposedSha256'] or validation['privateInputMap'][n]!=row['proposedSha256']:raise RuntimeError('Tested final proposal drift: '+n)
 head=git('rev-parse','HEAD').decode().strip();index=Path(git('rev-parse','--git-path','index').decode().strip());index=index if index.is_absolute() else ROOT/index;index_sha=sha(index)
 if git('ls-files','-u').strip():raise RuntimeError('Unmerged Main index refused')
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');dest=OUT/('main-adoption-'+stamp);dest.mkdir(exist_ok=False)
 receipt={'freshMainHead':head,'mainIndexBeforeSha256':index_sha,'reviewSha256':sha(OUT/'v4-review.json'),'actualValidationSha256':sha(OUT/'v4-validation.json'),'changes':[],'all202SourceDependencyPreimagesChecked':True,'noCommitPushPackageDeployment':True}
 def stableGit():
  if git('rev-parse','HEAD').decode().strip()!=head or sha(index)!=index_sha:raise RuntimeError('Concurrent legitimate Git activity: stop without restoring')
 def save():(dest/'journal.json').write_text(json.dumps(receipt,indent=2)+'\n','utf-8')
 save()
 for row in review['leaves']:
  stableGit();p=ROOT/row['path'];p.parent.mkdir(parents=True,exist_ok=True)
  if not p.parent.resolve().is_relative_to(ROOT) or p.is_symlink() or p.exists() and p.stat().st_file_attributes&0x400:raise RuntimeError('Reparse target refused')
  if row['beforeSha256'] is None:
   if p.exists():raise RuntimeError('Fresh new-leaf CAS refused')
  else:
   if sha(p)!=row['beforeSha256']:raise RuntimeError('Fresh target CAS refused')
   q=dest/'before'/row['path'];q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(p.read_bytes())
  handle,tmp=tempfile.mkstemp(prefix='.goods-summary-',suffix='.tmp',dir=p.parent)
  try:
   with os.fdopen(handle,'wb') as stream:stream.write((TREE/row['path']).read_bytes());stream.flush();os.fsync(stream.fileno())
   stableGit()
   if row['beforeSha256'] is None:os.rename(tmp,p)
   else:
    if sha(p)!=row['beforeSha256']:raise RuntimeError('Immediate pre-replace CAS refused')
    os.replace(tmp,p)
  finally:
   if os.path.exists(tmp):os.unlink(tmp)
  receipt['changes'].append(dict(row,actualMainSha256=sha(p)));save()
 stableGit()
 for n,h in validation['privateInputMap'].items():
  if sha(ROOT/n)!=h:raise RuntimeError('Post-adoption exact tested Main source drift: '+n)
 receipt.update(actualExitCode=0,mainHeadAfter=head,mainIndexAfterSha256=sha(index),all204TestedInputsExactInMain=True,workItemStatusesAdvanced=False,MainWritten=True)
 (dest/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n','utf-8');print(json.dumps({'receipt':str(dest/'receipt.json'),'sha256':sha(dest/'receipt.json'),'actualExitCode':0}))
if __name__=='__main__':main()
