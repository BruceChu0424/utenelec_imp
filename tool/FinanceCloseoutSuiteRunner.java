import java.io.PrintWriter;
import java.nio.file.*;
import java.util.*;
import org.junit.platform.engine.TestExecutionResult;
import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.launcher.*;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.SummaryGeneratingListener;

/** Explicit local finance suite; never starts the manual hold-open UAT test unless selected alone. */
public final class FinanceCloseoutSuiteRunner {
    public static void main(String[] args)throws Exception {
        var lines=Files.readAllLines(Path.of(args[0]));
        var selectors=lines.stream().filter(line->!line.isBlank()&&!line.startsWith("#"))
            .map(line->line.contains("#")?DiscoverySelectors.selectMethod(line):DiscoverySelectors.selectClass(line)).toList();
        var request=LauncherDiscoveryRequestBuilder.request().selectors(selectors).build();
        var summary=new SummaryGeneratingListener();
        var progress=new TestExecutionListener(){
            @Override public void executionFinished(TestIdentifier id,TestExecutionResult result){
                if(result.getStatus()==TestExecutionResult.Status.FAILED){
                    System.out.println("FAILED "+id.getUniqueId()+" "+result.getThrowable().map(e->e.getClass().getName()).orElse(""));
                    result.getThrowable().ifPresent(error->printFailure(id,error));
                    System.out.flush();
                }
                if(id.isContainer()&&id.getUniqueId().matches(".*\\[class:[^\\]]+\\]$")){
                    System.out.println("CLASS_FINISHED "+result.getStatus()+" "+id.getUniqueId());System.out.flush();
                }
            }
        };
        LauncherFactory.create().execute(request,summary,progress);
        var result=summary.getSummary();var output=new PrintWriter(System.out,true);
        result.printTo(output);
        for(var failure:result.getFailures()) {
            System.out.println("FAILURE_DETAIL "+failure.getTestIdentifier().getUniqueId());
            printFailure(failure.getTestIdentifier(),failure.getException());
        }
        System.out.println("FINANCE_SELECTED_CLASSES="+selectors.size());
        System.exit(result.getTestsFailedCount()==0&&result.getTestsAbortedCount()==0
            &&result.getContainersFailedCount()==0&&result.getTestsSucceededCount()>0?0:1);
    }
    private static void printFailure(TestIdentifier id,Throwable error) {
        // Opt-in source-file checks must never dump real workbook rows/amounts
        // through an assertion's object rendering. Failure status and locations
        // remain visible; ordinary synthetic regressions retain full diagnostics.
        boolean privateSource=id.getUniqueId().contains("FinanceAccountingWorkbookParserTest")
            ||id.getUniqueId().contains("FinanceTemplateSourceReaderTest");
        if(!privateSource){error.printStackTrace(System.out);return;}
        System.out.println(error.getClass().getName()+": private-source assertion details withheld; inspect the named check locally");
        for(var frame:error.getStackTrace())System.out.println("\tat "+frame);
    }
}
