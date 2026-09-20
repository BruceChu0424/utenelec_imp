package com.uten.imp.businesschain;

import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;

/** Shared real-service fixture only; no inherited test methods or fabricated stock. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
 "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
abstract class WorkshopMaterialReturnAuditSupport {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired protected AutowireCapableBeanFactory beans;
 @Autowired protected JdbcTemplate db;
 @Autowired protected StockDocService stock;
 @Autowired protected ProductionExecutionSegmentService segments;
 protected FullChainEndToEndTest fixture;
 private WorkshopSupplyAdversarialEndToEndTest scenario;
 @BeforeEach void prepareAuditFixture(){
  scenario=new WorkshopSupplyAdversarialEndToEndTest();beans.autowireBean(scenario);scenario.prepare();fixture=scenario.fixture;
 }
 @AfterEach void clearAuditActor(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}
 @SuppressWarnings("unchecked") protected <T>T read(Object object,String method,Object... args){
  return ReflectionTestUtils.invokeMethod(object==this?scenario:object,method,args);
 }
 protected long versionOf(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
}
