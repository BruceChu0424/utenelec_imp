package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.*;
import java.nio.file.*;
import java.time.*;

/** Explicit manual local UAT harness. No company endpoints, accounts or data. */
@EnabledIfEnvironmentVariable(named="UTEN_FINANCE_INTERACTIVE_UAT",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.DEFINED_PORT,properties={
 "server.address=127.0.0.1","server.port=18089","spring.profiles.active=dev",
 "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.provider=local","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=FinanceInteractiveUatHarnessTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class FinanceInteractiveUatHarnessTest {
 private static MigratedSchemaBaseline.ScopedDatabase database;
 private static org.testcontainers.postgresql.PostgreSQLContainer candidateDatabase;
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception{
  String candidate=System.getProperty("uten.finance.uat.migrations");
  if(candidate==null){
   database=MigratedSchemaBaseline.openDatabase("finance_interactive_uat");
   FixtureDatabaseProperties.bindSameRole(registry,database::getJdbcUrl,database::getUsername,database::getPassword);
  }else{
   Path snapshot=Path.of(candidate).toAbsolutePath().normalize();
   Path owned=Path.of("../tmp/finance-interactive").toAbsolutePath().normalize();
   if(!snapshot.startsWith(owned)||!Files.isDirectory(snapshot))throw new IllegalArgumentException("UAT snapshot must be task-owned");
   candidateDatabase=new org.testcontainers.postgresql.PostgreSQLContainer("postgres:16-alpine")
     .withDatabaseName("uten_finance_manual_uat").withUsername("fixture_admin").withPassword("uten");
   candidateDatabase.start();
   FixtureDatabaseProperties.bindSameRole(registry,candidateDatabase::getJdbcUrl,candidateDatabase::getUsername,candidateDatabase::getPassword);
   registry.add("spring.flyway.locations",()->"filesystem:"+snapshot.toString().replace('\\','/'));
  }
  String directory=Files.createTempDirectory("uten-finance-interactive-").toString();registry.add("uten.storage.local-dir",()->directory);
 }
 public static class Cleanup extends AbstractTestExecutionListener{
  @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
  @Override public void afterTestClass(TestContext ignored)throws Exception{if(database!=null)database.close();if(candidateDatabase!=null)candidateDatabase.stop();}
 }
 @Autowired AutowireCapableBeanFactory beans;
 @Autowired JdbcTemplate jdbc;
 @Test void serveActualAnonymousFinanceApplicationUntilTheManualStopMarker()throws Exception{
  // Reuse the already verified original purchase/IQC/stock/AP/actual-bank,
  // independent-review, statement and graph fixture; assertions remain active.
  var scenario=new PayableStatementAdjustmentPostgresTest();beans.autowireBean(scenario);
  scenario.originalFeeDecisionKeepsPeriodNetApartFromRemainingCashAndReversesOnlyAfterLaterRealPayments();
  SecurityContextHolder.clearContext();
  // This disposable synthetic bootstrap identity is never a company account.
  jdbc.update("UPDATE users SET must_change_password=false WHERE login_account=?",FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
  String run=System.getProperty("uten.finance.uat.run","default");
  if(!run.matches("[a-zA-Z0-9_-]{1,80}"))throw new IllegalArgumentException("Invalid task-owned UAT run identifier");
  var directory=Path.of("../tmp/finance-interactive",run);Files.createDirectories(directory);
  Files.writeString(directory.resolve("ready.json"),"{\"localOnly\":true,\"syntheticData\":true,\"api\":\"http://127.0.0.1:18089/api\",\"pid\":"+ProcessHandle.current().pid()+",\"run\":\""+run+"\"}");
  Instant deadline=Instant.now().plus(Duration.ofHours(4));
  while(!Files.exists(directory.resolve("stop"))&&Instant.now().isBefore(deadline))Thread.sleep(1000);
 }
}
