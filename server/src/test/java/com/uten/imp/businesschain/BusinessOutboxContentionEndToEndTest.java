package com.uten.imp.businesschain;

import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentSourceConflictException;
import com.uten.imp.common.concurrency.ProcurementMutationFootprint;
import com.uten.imp.features.notice.outbox.BusinessOutboxDeliveryDiagnostics;
import com.uten.imp.features.notice.outbox.BusinessOutboxFailureRecorder;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.BusinessOutboxPublisher;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.time.Duration;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.doAnswer;

/** Actual row contention, actual IQC source changes and durable terminal outcomes over isolated PostgreSQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.database.lock-timeout=200ms",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@Import(BusinessOutboxContentionEndToEndTest.Faults.class)
class BusinessOutboxContentionEndToEndTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws java.io.IOException {
        PG.start();
        registry.add("spring.datasource.url", PG::getJdbcUrl);
        registry.add("spring.datasource.username", PG::getUsername);
        registry.add("spring.datasource.password", PG::getPassword);
        var directory = Files.createTempDirectory("uten-outbox-contention-");
        registry.add("uten.storage.local-dir", directory::toString);
    }
    // The cached Spring context owns live pools; Testcontainers releases PG after the test JVM closes them.

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired BusinessOutboxProcessor processor;
    @Autowired BusinessOutboxFailureRecorder recorder;
    @Autowired BusinessOutboxScheduler applicationScheduler;
    @Autowired BusinessOutboxPublisher publisher;
    @Autowired ProcurementInspectionService inspections;
    @Autowired StockDocService stock;
    @Autowired FulfillmentMutationLocks locks;
    @MockitoSpyBean ProcurementMutationFootprint footprints;

    @BeforeEach void isolateWorker() { applicationScheduler.close(); }
    @AfterEach void clearActor() { SecurityContextHolder.clearContext(); }

    @Test
    void aBusyDrawRetriesAfterCommitAndCannotRecreateACompletedWarehouseTask() {
        var recovery = new CloseoutCommandRecoveryPostgresTest();
        ReflectionTestUtils.setField(recovery,"beans",beans);
        ReflectionTestUtils.setField(recovery,"db",db);
        ReflectionTestUtils.setField(recovery,"stock",stock);
        Object setup = ReflectionTestUtils.invokeMethod(recovery,"draws",1,true);
        List<UUID> documents = ReflectionTestUtils.invokeMethod(setup,"documents");
        assertThat(documents).hasSize(1);
        UUID draw = documents.getFirst();
        UUID event = db.queryForObject("SELECT id FROM business_outbox WHERE aggregate_id=? AND event_type='PRODUCTION_DRAW_PENDING' ORDER BY created_at DESC LIMIT 1",UUID.class,draw);
        postponeOthers(event);
        var request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey("outbox-controlled-draw-"+UUID.randomUUID());
        request.setDocIds(documents); request.setProtocolVersion(2);
        request.setReviews(stock.issueBatchReview(documents).documents().stream()
                .map(row -> new StockDocIssueBatchRequest.DocumentReview(row.docId(),row.reviewToken())).toList());
        var meters = new SimpleMeterRegistry();
        try (var worker = worker(meters)) {
            new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
                db.queryForList("SELECT id FROM stock_documents WHERE id=? FOR UPDATE",UUID.class,draw);
                worker.drain();
                await(() -> count(meters,"DEFERRED","LOCK_BUSY")==1);
                assertDeferred(event,"LOCK_BUSY","55P03");
                assertThat(stock.issueFullBatch(request).issuedCount()).isEqualTo(1);
            });
            eligible(event); worker.drain(); awaitDelivered(event);
            assertThat(db.queryForObject("SELECT fn_production_draw_pending(?)",Boolean.class,draw)).isFalse();
            assertThat(db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='STOCK_DOCUMENT' AND aggregate_id=? AND resolved_at IS NULL",Long.class,draw)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted AND issued_qty<>fn_production_draw_item_requested_qty(id)",Long.class,draw)).isZero();
            long movements = db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Long.class,draw);
            worker.drain(); awaitQuiescent(worker);
            assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Long.class,draw)).isEqualTo(movements);
            assertThat(db.queryForObject("SELECT attempts FROM business_outbox WHERE id=?",Integer.class,event)).isEqualTo(1);
        } finally { meters.close(); }
    }

    @Test
    void anActualCommittedSiblingInspectionInvalidatesThePreReadThenProjectsExactlyOnce() throws Exception {
        var scenario = new WarehouseIqcMultiLineFixture(beans,db).prepare(2,2,"outbox-iqc-"+UUID.randomUUID().toString().substring(0,8));
        var fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture);
        UUID recipient = fixture.createUserWithPerms(scenario.world(),"outbox-return-"+UUID.randomUUID().toString().substring(0,8),
                "notice:read","procurement_iqc_rejection:view","procurement_iqc_rejection:view:all","procurement_iqc_rejection:record_return");
        fixture.loginAs(scenario.world().superAdminUserId());
        var rows = scenario.receipts().stream().filter(row -> "PURCHASE".equals(row.type())).toList();
        assertThat(rows).hasSize(2);
        var failed = rows.getFirst(); var sibling = rows.getLast();
        assertRealPrelockTimeoutCauses(scenario.world().warehouseId(),failed.id());
        inspections.decideBatch("PURCHASE",failed.id(),decision(failed.inspectionId(),"0.75","0.50"));
        UUID event = db.queryForObject("SELECT id FROM business_outbox WHERE event_type='PROCUREMENT_IQC_REJECTION_DETECTED' AND aggregate_id=?",UUID.class,failed.inspectionId());
        UUID qualityEvent = db.queryForObject("SELECT (payload->>'inspectionEventId')::uuid FROM business_outbox WHERE id=?",UUID.class,event);
        postponeOthers(event);
        var discovered = new CountDownLatch(1); var changed = new CountDownLatch(1);
        var pauseOnce = new AtomicBoolean(true);
        doAnswer(invocation -> {
            Object plan = invocation.callRealMethod();
            Collection<ProcurementMutationFootprint.ReceiptRef> refs = invocation.getArgument(0);
            if (Thread.currentThread().getName().equals("business-outbox-dispatch")
                    && refs.stream().anyMatch(ref -> ref.id().equals(failed.id())) && pauseOnce.compareAndSet(true,false)) {
                discovered.countDown();
                if (!changed.await(15,TimeUnit.SECONDS)) { throw new AssertionError("The real sibling command must commit after discovery"); }
            }
            return plan;
        }).when(footprints).receipts(anyCollection());
        var meters = new SimpleMeterRegistry();
        try (var worker = worker(meters)) {
            worker.drain();
            try {
                assertThat(discovered.await(10,TimeUnit.SECONDS)).isTrue();
                // This is a real business command, not a forged fingerprint or a dummy xmin update.
                inspections.decideBatch("PURCHASE",sibling.id(),decision(sibling.inspectionId(),"1.25","0"));
                postponeOthers(event);
            } finally { changed.countDown(); }
            await(() -> count(meters,"DEFERRED","SOURCE_CHANGED")==1);
            assertDeferred(event,"SOURCE_CHANGED","expected=");
            assertThat(db.queryForObject("SELECT count(*) FROM procurement_iqc_rejection_cases WHERE inspection_item_id=?",Long.class,failed.inspectionId())).isZero();
            eligible(event); worker.drain(); awaitDelivered(event);
            UUID rejection = db.queryForObject("SELECT id FROM procurement_iqc_rejection_cases WHERE inspection_item_id=?",UUID.class,failed.inspectionId());
            await(() -> db.queryForObject("SELECT count(*) FROM business_outbox WHERE aggregate_id=? AND event_type='PROCUREMENT_IQC_REJECTION_OPENED' AND status=1",Long.class,rejection)==1L);
            assertThat(db.queryForObject("SELECT count(*) FROM procurement_iqc_rejection_events WHERE source_inspection_event_id=? AND event_type='FAIL_PROJECTED'",Long.class,qualityEvent)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='IQC_REJECTION_CASE' AND aggregate_id=? AND audience_user_id=? AND source_event='PROCUREMENT_IQC_REJECTION_OPENED' AND resolved_at IS NULL",Long.class,rejection,recipient)).isEqualTo(1);
            worker.drain(); awaitQuiescent(worker);
            assertThat(db.queryForObject("SELECT row_version FROM procurement_iqc_rejection_cases WHERE id=?",Long.class,rejection)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_kind='IQC_REJECTION_CASE' AND aggregate_id=? AND audience_user_id=? AND source_event='PROCUREMENT_IQC_REJECTION_OPENED'",Long.class,rejection,recipient)).isEqualTo(1);
        } finally { meters.close(); }
    }

    @Test
    void sustainedRealDatabaseContentionAndUnknownSqlFailuresStillReachVisibleDeadLetters() throws Exception {
        assertTerminalFailure("TEST_OUTBOX_BUSY","LOCK_BUSY","55P03",true);
        assertTerminalFailure("TEST_OUTBOX_UNKNOWN","UNEXPECTED","22012",false);
    }

    private void assertTerminalFailure(String type,String kind,String sqlState,boolean busy) throws Exception {
        UUID aggregate = UUID.randomUUID();
        UUID event = publisher.publishOnce(type,"TEST",aggregate,Map.of(),"outbox-terminal-"+aggregate);
        postponeOthers(event);
        var meters = new SimpleMeterRegistry();
        try (var blocker = DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
             var worker = worker(meters)) {
            blocker.setAutoCommit(false);
            if (busy) {
                try (var query = blocker.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(CAST(? AS text),0))")) {
                    query.setString(1,aggregate.toString()); try (var result = query.executeQuery()) { assertThat(result.next()).isTrue(); }
                }
            }
            for (int attempt=1;attempt<=8;attempt++) {
                eligible(event); worker.drain(); int expected=attempt;
                await(() -> db.queryForObject("SELECT attempts FROM business_outbox WHERE id=?",Integer.class,event)==expected);
                if (attempt<8) {
                    assertThat(db.queryForObject("SELECT status FROM business_outbox WHERE id=?",Integer.class,event)).isZero();
                    assertThat(db.queryForObject("SELECT available_at>now() FROM business_outbox WHERE id=?",Boolean.class,event)).isTrue();
                }
            }
            assertThat(db.queryForObject("SELECT status FROM business_outbox WHERE id=?",Integer.class,event)).isEqualTo(2);
            assertThat(db.queryForObject("SELECT last_error FROM business_outbox WHERE id=?",String.class,event)).contains("kind="+kind,sqlState);
            await(() -> count(meters,"EXHAUSTED",kind)==1);
            assertThat(count(meters,busy?"DEFERRED":"FAILED",kind)).isEqualTo(7);
            if (!busy) { assertThat(count(meters,"DEFERRED",kind)).isZero(); }
            blocker.rollback(); worker.drain(); awaitQuiescent(worker);
            assertThat(db.queryForObject("SELECT attempts FROM business_outbox WHERE id=?",Integer.class,event)).isEqualTo(8);
            assertThat(db.queryForObject("SELECT processed_at FROM business_outbox WHERE id=?",java.time.OffsetDateTime.class,event)).isNull();
        } finally { meters.close(); }
    }

    private static BatchInspectionDecideRequest decision(UUID inspection,String pass,String fail) {
        return new BatchInspectionDecideRequest(List.of(new BatchInspectionDecideRequest.Item(inspection,
                new BigDecimal("1.25"),new BigDecimal(pass),new BigDecimal(fail),"outbox-quality-"+inspection)),"controlled outbox source change");
    }
    private void assertRealPrelockTimeoutCauses(UUID warehouse,UUID receipt) throws Exception {
        UUID order=db.queryForObject("SELECT ordered.order_id FROM purchase_receipt_items received JOIN purchase_order_items ordered ON ordered.id=received.order_item_id WHERE received.receipt_id=? ORDER BY received.id LIMIT 1",UUID.class,receipt);
        var headerPlan=new FulfillmentMutationLockPlan(Set.of(new FulfillmentMutationLockPlan.CommercialSource(
                FulfillmentMutationLockPlan.CommercialType.PURCHASE_ORDER,order)),Set.of(),Set.of(),Set.of(),"controlled-header-timeout");
        var warehousePlan=new FulfillmentMutationLockPlan(Set.of(),Set.of(),Set.of(warehouse),Set.of(),"controlled-warehouse-timeout");
        try (var blocker=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
            blocker.setAutoCommit(false);
            try (var query=blocker.prepareStatement("SELECT id FROM purchase_orders WHERE id=? FOR UPDATE")) {
                query.setObject(1,order); try (var rows=query.executeQuery()) { assertThat(rows.next()).isTrue(); }
            }
            assertLockCause(headerPlan,FulfillmentMutationLocks.SOURCE_BUSY_MESSAGE);
            blocker.rollback();
            try (var query=blocker.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?,0))")) {
                query.setString(1,"MATERIAL-ANALYSIS-WAREHOUSE:"+warehouse);
                try (var rows=query.executeQuery()) { assertThat(rows.next()).isTrue(); }
            }
            assertLockCause(warehousePlan,FulfillmentMutationLocks.WAREHOUSE_BUSY_MESSAGE);
            blocker.rollback();
        }
    }
    private void assertLockCause(FulfillmentMutationLockPlan plan,String userMessage) {
        assertThatThrownBy(() -> new TransactionTemplate(transactionManager).executeWithoutResult(status -> locks.acquire(() -> plan)))
                .isInstanceOfSatisfying(FulfillmentSourceConflictException.class,error -> {
                    assertThat(error.reason()).isEqualTo(FulfillmentSourceConflictException.Reason.LOCK_BUSY);
                    Throwable sql=error.getCause();
                    while (sql!=null && !(sql instanceof SQLException)) { sql=sql.getCause(); }
                    assertThat(sql).isInstanceOfSatisfying(SQLException.class,cause -> assertThat(cause.getSQLState()).isEqualTo("55P03"));
                    var response=new com.uten.imp.common.web.GlobalExceptionHandler().handleApi(error);
                    assertThat(response.getStatusCode().value()).isEqualTo(409);
                    assertThat(response.getHeaders().getFirst("Retry-After")).isEqualTo("1");
                    var body=java.util.Objects.requireNonNull(response.getBody());
                    assertThat(body.getCode()).isEqualTo("CONFLICT");
                    assertThat(body.getMessage()).isEqualTo(userMessage);
                });
    }
    private BusinessOutboxScheduler worker(SimpleMeterRegistry meters) { return new BusinessOutboxScheduler(processor,recorder,new BusinessOutboxDeliveryDiagnostics(meters)); }
    private void postponeOthers(UUID event) { db.update("UPDATE business_outbox SET available_at=now()+interval '1 hour' WHERE status=0 AND id<>?",event); }
    private void eligible(UUID event) { db.update("UPDATE business_outbox SET available_at=now() WHERE id=? AND status=0",event); }
    private void awaitDelivered(UUID event) { await(() -> db.queryForObject("SELECT status FROM business_outbox WHERE id=?",Integer.class,event)==1); }
    private void assertDeferred(UUID event,String kind,String detail) {
        assertThat(db.queryForObject("SELECT status FROM business_outbox WHERE id=?",Integer.class,event)).isZero();
        assertThat(db.queryForObject("SELECT attempts FROM business_outbox WHERE id=?",Integer.class,event)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT available_at>now() FROM business_outbox WHERE id=?",Boolean.class,event)).isTrue();
        assertThat(db.queryForObject("SELECT last_error FROM business_outbox WHERE id=?",String.class,event)).contains("kind="+kind,detail);
    }
    private static double count(SimpleMeterRegistry meters,String outcome,String kind) {
        var counter=meters.find("uten.business.outbox.delivery").tags("outcome",outcome,"kind",kind).counter();
        return counter==null?0:counter.count();
    }
    private static void await(BooleanSupplier condition) {
        long end=System.nanoTime()+Duration.ofSeconds(20).toNanos();
        while (System.nanoTime()<end) {
            if (condition.getAsBoolean()) { return; }
            awaitIdleWorker();
        }
        throw new AssertionError("Durable outbox condition did not become true within 20 seconds");
    }
    private static void awaitIdleWorker() {
        try { Thread.sleep(20); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new AssertionError(interrupted); }
    }
    private static void awaitQuiescent(BusinessOutboxScheduler worker) {
        Object lock=ReflectionTestUtils.getField(worker,"dispatchLock");
        assertThat(lock).isNotNull();
        await(() -> {
            synchronized (lock) { return Boolean.FALSE.equals(ReflectionTestUtils.getField(worker,"queuedOrRunning")); }
        });
    }

    @TestConfiguration(proxyBeanMethods=false)
    static class Faults {
        @Bean BusinessOutboxDomainHandler controlledFailures(JdbcTemplate jdbc) {
            return new BusinessOutboxDomainHandler() {
                @Override public boolean supports(String type) { return type.equals("TEST_OUTBOX_BUSY")||type.equals("TEST_OUTBOX_UNKNOWN"); }
                @Override public void handle(UUID id,String type,UUID aggregate,com.fasterxml.jackson.databind.JsonNode payload,UUID actor) {
                    if (type.equals("TEST_OUTBOX_BUSY")) {
                        jdbc.queryForList("SELECT pg_advisory_xact_lock(hashtextextended(CAST(? AS text),0))",aggregate.toString());
                    } else {
                        jdbc.queryForObject("SELECT 1/0",Integer.class);
                    }
                }
            };
        }
    }
}
