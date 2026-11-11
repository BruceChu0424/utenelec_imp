package audit;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.*;
import static org.junit.platform.engine.discovery.DiscoverySelectors.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
public class CandidateImportSuite {
 public static void main(String[] args)throws Exception {
  var listener=new SummaryGeneratingListener();var launcher=LauncherFactory.create();launcher.registerTestExecutionListeners(listener);
  var request=LauncherDiscoveryRequestBuilder.request();
  for(String name:args)request.selectors(selectClass(name));
  launcher.execute(request.build());var result=listener.getSummary();result.printTo(new PrintWriter(System.out,true));result.printFailuresTo(new PrintWriter(System.out,true));
  long failures=result.getFailures().stream().filter(f->f.getTestIdentifier().isTest()&&f.getException() instanceof AssertionError).count();
  long errors=result.getFailures().stream().filter(f->f.getTestIdentifier().isTest()&&!(f.getException() instanceof AssertionError)).count();
  System.out.println("AUDIT_JUNIT_COUNTS tests="+result.getTestsFoundCount()+" successful="+result.getTestsSucceededCount()+" assertionFailures="+failures+" executionErrors="+errors+" skipped="+result.getTestsSkippedCount()+" aborted="+result.getTestsAbortedCount()+" failedContainers="+result.getContainersFailedCount());
  if(!result.getFailures().isEmpty()||result.getTestsSucceededCount()==0)System.exit(1);
 }
}
