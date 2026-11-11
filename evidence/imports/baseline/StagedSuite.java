package com.uten.imp.businesschain;
import org.junit.platform.launcher.core.*;import org.junit.platform.launcher.listeners.*;import java.io.PrintWriter;import static org.junit.platform.engine.discovery.DiscoverySelectors.*;
public class StagedSuite{
 public static void main(String[] args){
 var req=LauncherDiscoveryRequestBuilder.request().selectors(selectMethod(StagedExportAudit.class,"hundredThousandGoodsFromPostgres"),selectMethod(StagedExportAudit.class,"publicImportWithUnknownColumnsAndLockedReceipt")).build();
 var l=new SummaryGeneratingListener();var launcher=LauncherFactory.create();launcher.registerTestExecutionListeners(l);launcher.execute(req);
 var s=l.getSummary();s.printTo(new PrintWriter(System.out,true));s.printFailuresTo(new PrintWriter(System.out,true));System.exit(s.getFailures().isEmpty()?0:1);
 }
}
