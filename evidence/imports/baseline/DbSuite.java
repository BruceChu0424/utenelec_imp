package com.uten.imp.businesschain;
import static org.junit.platform.engine.discovery.DiscoverySelectors.*;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.*;
import java.io.PrintWriter;
public class DbSuite {
 public static void main(String[] args) {
   var selectors=java.util.List.of(selectMethod(ExportAudit.class,"requestedMouldSortMatchesTheRenderedWorkbook"),selectMethod(ExportAudit.class,"publicImportWithUnknownColumnsAndLockedReceipt"),selectMethod(ExportAudit.class,"hundredThousandGoodsFromPostgres"));
   var req=LauncherDiscoveryRequestBuilder.request().selectors(selectors).build(); var listener=new SummaryGeneratingListener();
   var launcher=LauncherFactory.create();launcher.registerTestExecutionListeners(listener);launcher.execute(req);
   var summary=listener.getSummary();summary.printTo(new PrintWriter(System.out,true));summary.printFailuresTo(new PrintWriter(System.out,true));System.exit(summary.getFailures().isEmpty()?0:1);
 }
}

