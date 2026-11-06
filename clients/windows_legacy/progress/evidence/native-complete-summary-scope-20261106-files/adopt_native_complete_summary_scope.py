from pathlib import Path
import datetime, hashlib, json, os, subprocess, tempfile
ROOT=Path('D:/Projects/uten_imp').resolve()
OUT=ROOT/'build/loading-validation/native-complete-summary-scope-20261106'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args],env=dict(os.environ,GIT_OPTIONAL_LOCKS='0'))
def main():
 review=json.loads((OUT/'review.json').read_bytes());validation=json.loads((OUT/'validation.json').read_bytes())
 if validation['actualExitCode'] or len(validation['runs'])!=6 or any(x['actualExitCode'] for x in validation['runs']):raise RuntimeError('Exact original Core checks are not green on both architectures')
 for x in validation['runs']:
  if sha(OUT/(x['name']+'.log'))!=x['logSha256']:raise RuntimeError('Actual build/test log drift')
 if sha(ROOT/review['fixturePath'])!=review['fixtureSha256']:raise RuntimeError('Front-owned Main fixture is not the exact tested final fixture yet')
 changes={x['path']:x for x in review['changes']}
 for name,digest in review['privateInputMap'].items():
  if sha(ROOT/name)!=digest:raise RuntimeError('Fresh Main protected preimage drift: '+name)
 for name,row in changes.items():
  if sha(OUT/'tree'/name)!=row['proposedSha256']:raise RuntimeError('Final proposal leaf drift')
 index=Path(git('rev-parse','--git-path','index').decode().strip());index=index if index.is_absolute() else ROOT/index
 head=git('rev-parse','HEAD').decode().strip();index_sha=sha(index)
 if git('ls-files','-u').strip():raise RuntimeError('Unmerged Main index refused')
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');adoption=OUT/('main-adoption-'+stamp);adoption.mkdir(exist_ok=False)
 journal={'atUtc':stamp,'mainHeadFresh':head,'mainIndexSha256Before':index_sha,'proposalHeadHistorical':review['mainHeadAtProposal'],'fixtureSha256':review['fixtureSha256'],'validationSha256':sha(OUT/'validation.json'),'changes':[],'sourceCommittedPushedPackagedOrDeployed':False}
 def save():(adoption/'journal.json').write_text(json.dumps(journal,indent=2)+'\n','utf-8')
 save()
 for name,row in changes.items():
  if git('rev-parse','HEAD').decode().strip()!=head or sha(index)!=index_sha:raise RuntimeError('Legitimate concurrent Git activity: stop without restoring')
  target=ROOT/name
  if not target.resolve().is_relative_to(ROOT) or target.is_symlink() or target.stat().st_file_attributes&0x400:raise RuntimeError('Unexpected reparse leaf refused')
  if sha(target)!=row['beforeSha256']:raise RuntimeError('Fresh leaf CAS refused: '+name)
  before=adoption/'before'/name;before.parent.mkdir(parents=True,exist_ok=True);before.write_bytes(target.read_bytes())
  desired=(OUT/'tree'/name).read_bytes();handle,temp=tempfile.mkstemp(prefix='.summary-scope-',suffix='.tmp',dir=target.parent)
  try:
   with os.fdopen(handle,'wb') as stream:stream.write(desired);stream.flush();os.fsync(stream.fileno())
   if sha(target)!=row['beforeSha256'] or git('rev-parse','HEAD').decode().strip()!=head or sha(index)!=index_sha:raise RuntimeError('Pre-replace Main CAS drift')
   os.replace(temp,target)
  finally:
   if os.path.exists(temp):os.unlink(temp)
  journal['changes'].append(dict(row,actualMainSha256=sha(target)));save()
 if git('rev-parse','HEAD').decode().strip()!=head or sha(index)!=index_sha:raise RuntimeError('Post-adoption legitimate Git drift; preserve evidence')
 journal.update(actualExitCode=0,mainHeadAfter=head,mainIndexSha256After=sha(index),all64ProtectedInputPreimagesChecked=True,MainWritten=True,fullErpOrWin7Accepted=False)
 (adoption/'receipt.json').write_text(json.dumps(journal,indent=2)+'\n','utf-8');print(json.dumps({'receipt':str(adoption/'receipt.json'),'receiptSha256':sha(adoption/'receipt.json'),'actualExitCode':0}))
if __name__=='__main__':main()
