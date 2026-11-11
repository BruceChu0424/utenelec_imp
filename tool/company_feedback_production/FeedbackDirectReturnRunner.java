import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder;
import org.junit.platform.launcher.core.LauncherFactory;
import org.junit.platform.launcher.listeners.SummaryGeneratingListener;

/** Runs the two unchanged public-service/PG tests; exits only after JUnit has completed both. */
public class FeedbackDirectReturnRunner {
    public static void main(String[] args) {
        var request = LauncherDiscoveryRequestBuilder.request().selectors(
            DiscoverySelectors.selectMethod("com.uten.imp.businesschain.ProductionExecutionRouteGateEndToEndTest#unissuedDirectMaterialCanGoToNormalStockBeforeIssueOnAnExplicitBatchRoute"),
            DiscoverySelectors.selectMethod("com.uten.imp.businesschain.ProductionExecutionRouteGateEndToEndTest#unusedPreparedDirectReturnAndReversalAdjustOnlyExactPickingInstructions")
        ).build();
        var summary = new SummaryGeneratingListener();
        var launcher = LauncherFactory.create();
        launcher.registerTestExecutionListeners(summary);
        launcher.execute(request);
        var out = new java.io.PrintWriter(System.out, true);
        summary.getSummary().printTo(out);
        summary.getSummary().printFailuresTo(out);
        // Spring test schedulers may remain alive after the launcher returns.
        // This matches the existing Feedback*Runner convention; no active test is cancelled.
        System.exit(summary.getSummary().getTestsFoundCount() == 2
            && summary.getSummary().getTestsSucceededCount() == 2
            && summary.getSummary().getTotalFailureCount() == 0 ? 0 : 1);
    }
}
