package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.inventory.value-work.enabled=false","uten.workshop-material.auto-close.enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceReviewedJanuaryUiFixtureTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceReviewedJanuaryUiFixtureTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void positiveOriginalStatementsRequireAReviewedCompleteBookRatherThanRemovingUnknownStressAccounts()throws Exception {
        var fixture=new FinanceReviewedJanuaryUiFixture();beans.autowireBean(fixture);fixture.seed();
    }
}
