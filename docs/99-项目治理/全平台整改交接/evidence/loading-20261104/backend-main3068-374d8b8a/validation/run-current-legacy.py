import sys,os,json,unittest
from datetime import datetime,timezone
from pathlib import Path
base=Path(__file__).resolve().parent;root=base.parents[3];os.chdir(root/'server/legacy_migration');sys.path.insert(0,os.getcwd());sys.executable='C:/Program Files/LibreOffice/program/python.exe'
modules=['test_verify_rehearsal_counter_baseline','test_verify_rehearsal_result','test_compose_bootstrap']
source=json.loads((base/'source-input.json').read_text(encoding='utf-8'))
class Ledger(unittest.TextTestResult):
    def __init__(self,*a,**k):super().__init__(*a,**k);self.cases=[]
    def addSuccess(self,test):super().addSuccess(test);self.cases.append({'case':test.id(),'status':'passed'})
    def addFailure(self,test,err):super().addFailure(test,err);self.cases.append({'case':test.id(),'status':'failed'})
    def addError(self,test,err):super().addError(test,err);self.cases.append({'case':test.id(),'status':'error'})
    def addSkip(self,test,reason):super().addSkip(test,reason);self.cases.append({'case':test.id(),'status':'skipped','reason':reason})
started=datetime.now(timezone.utc).isoformat();suite=unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(m) for m in modules)
result=unittest.TextTestRunner(verbosity=2,resultclass=Ledger).run(suite)
code=0 if result.wasSuccessful() else 1
receipt={'startedAtUtc':started,'completedAtUtc':datetime.now(timezone.utc).isoformat(),'sourceAggregateSha256':source['aggregateSha256'],'upstreamMainHead':source['upstreamMainHead'],'actualExitCode':code,'modules':modules,'tests':result.testsRun,'failed':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped),'caseLedger':result.cases,'scope':'Current1067 gate, original bootstrap-v22 proof/source/current schema/identity and original CLI before-partial-output protection. Original launcher explicitly restored; previous66+1 historical red is not rewritten.'}
(base/'legacy-execution.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');sys.exit(code)
