package remediation;
import java.io.PrintWriter;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.*;
import static org.junit.platform.engine.discovery.DiscoverySelectors.*;

/** An actual original PG business case; no warmup, API replacement or altered deadline. */
public class BudgetSuite {
    public static void main(String[] args) {
        var listener=new SummaryGeneratingListener();
        var launcher=LauncherFactory.create();launcher.registerTestExecutionListeners(listener);
        launcher.execute(LauncherDiscoveryRequestBuilder.request().selectors(selectMethod(
                "com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest",args.length==0?"twentyMaterialLinesCompleteWithinDeadlineBudget":args[0])).build());
        var result=listener.getSummary();result.printTo(new PrintWriter(System.out,true));
        result.printFailuresTo(new PrintWriter(System.out,true));
        System.exit(result.getTestsFailedCount()==0&&result.getTestsSucceededCount()==1?0:1);
    }
}
