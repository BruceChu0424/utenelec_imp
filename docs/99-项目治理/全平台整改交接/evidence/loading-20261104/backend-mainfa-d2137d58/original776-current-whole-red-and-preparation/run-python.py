import hashlib,json,os,sys,unittest
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3];os.chdir(root/'server/legacy_migration');sys.path.insert(0,os.getcwd());sys.executable='C:/Program Files/LibreOffice/program/python.exe'
modules=['test_verify_candidate','test_local_source_freeze','test_rehearse_local_import','test_verify_rehearsal_counter_baseline','test_verify_rehearsal_result','test_compose_bootstrap']
guard=root/'deploy/updater/release_guard.py';start_sha=hashlib.sha256(guard.read_bytes()).hexdigest();started=datetime.now(timezone.utc).isoformat()
class Ledger(unittest.TextTestResult):
    def __init__(self,*args,**kwargs):super().__init__(*args,**kwargs);self.cases=[]
    def addSuccess(self,test):super().addSuccess(test);self.cases.append({'case':test.id(),'status':'passed'})
    def addFailure(self,test,error):super().addFailure(test,error);self.cases.append({'case':test.id(),'status':'failed'})
    def addError(self,test,error):super().addError(test,error);self.cases.append({'case':test.id(),'status':'error'})
    def addSkip(self,test,reason):super().addSkip(test,reason);self.cases.append({'case':test.id(),'status':'skipped','reason':reason})
suite=unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in modules)
result=unittest.TextTestRunner(verbosity=2,resultclass=Ledger).run(suite);code=0 if result.wasSuccessful() else 1
receipt={'startedAtUtc':started,'completedAtUtc':datetime.now(timezone.utc).isoformat(),'scope':'Formal source-frozen81 actual new producer/authority/CLI/local-source/v22 tests. No company database/Main/source writes.','actualExitCode':code,'sourceAggregateSha256':json.loads((base/'source-input.json').read_text(encoding='utf-8'))['aggregateSha256'],'modules':modules,'tests':result.testsRun,'failed':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped),'guardStartSha256':start_sha,'guardEndSha256':hashlib.sha256(guard.read_bytes()).hexdigest(),'caseLedger':result.cases}
(base/'python-execution.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');sys.exit(code)
