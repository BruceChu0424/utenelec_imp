package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;

/** Loopback-only, disposable real UI acceptance. Never a company account or distribution server. */
@EnabledIfEnvironmentVariable(named="UTEN_SALES_FINANCE_INTERACTIVE_UAT",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.DEFINED_PORT,properties={
        "server.address=127.0.0.1","server.port=18091","spring.profiles.active=dev",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.provider=local","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
class SalesFinanceInteractiveUatHarnessTest {
    static final String MAKER="local-study-maker", REVIEWER="local-study-reviewer";
    // Deliberately public synthetic fixture secret; no real user or company credential is used.
    static final String PASSWORD="LocalOnly-Study-2026!";

    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception{
        Path web=Path.of("../build/web").toAbsolutePath().normalize();
        if(!Files.isRegularFile(web.resolve("index.html")))
            throw new IllegalStateException("Build this task's local Web fixture before starting UI acceptance");
        FullChainEndToEndTest.registerDataSource(registry);
        registry.add("spring.web.resources.static-locations",()->web.toUri().toString());
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PasswordEncoder passwords;
    @Autowired ObjectMapper json;
    @AfterEach void clearIdentity(){SecurityContextHolder.clearContext();}

    @Test void serveRealShipmentAndReceiptApplicationUntilOwnedStopMarker()throws Exception{
        String run=System.getProperty("uten.sales-finance.uat.run","feedback-20261104");
        if(!run.matches("[a-zA-Z0-9_-]{1,80}"))throw new IllegalArgumentException("Invalid owned UAT run identifier");
        Path owned=Path.of("../tmp/sales-finance-interactive",run).toAbsolutePath().normalize();
        Files.createDirectories(owned);
        if(Files.exists(owned.resolve("stop")))throw new IllegalStateException("Use a new UAT run after the prior stop marker");
        var scenario=ShipmentReceivableBatchFixture.prepare(beans,db,"study-"+run);
        var shipmentService=beans.getBean(com.uten.imp.features.sales.shipment.SalesShipmentService.class);
        scenario.fixture().loginAs(scenario.world().superAdminUserId());
        // A normal shipment belongs to one real order; the other order in the
        // fixture exists only to prove unrelated financial sources are rejected.
        var pending=scenario.fixture().shipmentRequest(scenario.world(),scenario.firstItem(),scenario.goods(),"10");
        pending.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        pending.getItems().getFirst().setLineNo(1);
        pending.setRemark("本地演示：本批部分付款，剩余到货后付；未实际到账不能收清");
        var pendingShipment=shipmentService.create(pending);
        shipmentService.confirmSales(pendingShipment.getId(),pendingShipment.getWorkflow().getReviewRevision());
        String encoded=passwords.encode(PASSWORD);
        db.update("UPDATE users SET login_account=?,password_hash=?,must_change_password=false WHERE id=?",
                MAKER,encoded,scenario.world().superAdminUserId());
        db.update("UPDATE users SET login_account=?,password_hash=?,must_change_password=false WHERE id=?",
                REVIEWER,encoded,scenario.reviewer());
        var ready=new LinkedHashMap<String,Object>();
        ready.put("localOnly",true);ready.put("syntheticData",true);ready.put("api","http://127.0.0.1:18091/api");
        ready.put("pid",ProcessHandle.current().pid());ready.put("run",run);
        ready.put("shipmentId",scenario.shipment());ready.put("ledgerId",scenario.ledger());
        ready.put("firstOrderId",scenario.firstOrder());ready.put("secondOrderId",scenario.secondOrder());
        ready.put("bankId",scenario.bank());
        ready.put("pendingShipmentId",pendingShipment.getId());
        Files.writeString(owned.resolve("ready.json"),json.writeValueAsString(ready));
        SecurityContextHolder.clearContext();
        Instant deadline=Instant.now().plus(Duration.ofHours(2));
        while(!Files.exists(owned.resolve("stop"))&&Instant.now().isBefore(deadline))Thread.sleep(250);
        Files.writeString(owned.resolve("stopped.json"),"{\"stopped\":true,\"localOnly\":true}");
    }
}
