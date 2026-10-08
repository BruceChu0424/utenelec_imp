package com.uten.imp.businesschain;

import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Real direct handover and material/cost facts, including the executed physical lock SQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@Import(StockDocDirectTransferLockReusePostgresTest.CounterConfiguration.class)
class StockDocDirectTransferLockReusePostgresTest {
    private static final ThreadLocal<AtomicInteger> PACKAGE_LOCKS=new ThreadLocal<>();
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired InventoryValueWorkService valueWork;
    @Autowired BusinessOutboxScheduler outbox;
    @AfterEach void cleanup(){PACKAGE_LOCKS.remove();SecurityContextHolder.clearContext();}

    @Test void draftApprovalAndImmediateIssueUseOnePhysicalDrawGraphWhileKeepingExactFacts() {
        outbox.close();
        var prepared=ControlledDailyReportInputs.prepare(beans,jdbc,3,"graph-reuse-"+UUID.randomUUID());
        InventoryValueWorkTestSupport.drain(valueWork,jdbc,List.copyOf(prepared.goodsIds()));
        var locks=new AtomicInteger();PACKAGE_LOCKS.set(locks);
        try {prepared.command().get();}finally{PACKAGE_LOCKS.remove();}
        prepared.verify().run();
        assertEquals(6,locks.get(),"Each receiver must lock its inbound graph and its DRAW graph once; approval cannot force a third identical physical prelock before issue");
        prepared.command().get();
        prepared.verify().run();
    }

    @TestConfiguration(proxyBeanMethods=false)
    static class CounterConfiguration {
        @Bean HibernatePropertiesCustomizer packageLockCounter() {
            return properties->properties.put("hibernate.session_factory.statement_inspector",(StatementInspector)sql->{
                String normalized=sql.replaceAll("\\s+"," ").trim().toLowerCase(java.util.Locale.ROOT);
                var counter=PACKAGE_LOCKS.get();
                if(counter!=null&&normalized.startsWith("select package.id from production_planning_packages package")
                        &&normalized.endsWith("for update"))counter.incrementAndGet();
                return sql;
            });
        }
    }
}
