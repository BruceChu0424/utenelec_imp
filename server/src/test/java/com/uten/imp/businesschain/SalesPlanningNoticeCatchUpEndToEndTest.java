package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.SalesPlanningNoticeCatchUpService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.OutboxDeliveryException;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real sales decisions, source handoff and persisted per-recipient delivery, on the complete schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class SalesPlanningNoticeCatchUpEndToEndTest {
    // This suite deliberately controls outbox ordering and injects a failed delivery.
    // Other cached Spring contexts must never consume its events or add unrelated global candidates.
    private static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("planning_catch_up").withUsername("uten").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        DATABASE.start();
        registry.add("spring.datasource.url", DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username", DATABASE::getUsername);
        registry.add("spring.datasource.password", DATABASE::getPassword);
    }
    // DirtiesContext closes the scheduler and pool first. Ryuk reclaims this private container at JVM exit;
    // stopping PostgreSQL in @AfterAll would race Spring's still-live scheduled tasks during teardown.
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService finance;
    @Autowired TaskClaimService claims;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired ChainNoticeService chain;
    @MockitoSpyBean NoticeService notices;
    @Autowired SalesPlanningNoticeCatchUpService catchUp;
    @Autowired BusinessOutboxProcessor processor;
    @MockitoBean BusinessOutboxScheduler scheduler;
    private final ObjectMapper json = new ObjectMapper();
    private final List<UUID> recipients = new ArrayList<>();
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID order;
    private TransactionTemplate transactions;

    @BeforeEach void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        world = fixture.seedWorld("planning-catchup-" + suffix());
        fixture.loginAs(world.superAdminUserId());
        transactions = new TransactionTemplate(transactionManager);
        order = sales.create(fixture.orderRequest(world, world.goodsA(), "10", "100")).getId();
        sales.approve(order);
        var claim = claims.claim("SALES_ORDER_FINANCE_CONFIRM", order.toString());
        finance.confirm(order, new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, 0L, claim.claimId()));
    }
    @AfterEach void cleanup() {
        for (UUID user : recipients) jdbc.update("UPDATE users SET status='disabled' WHERE id=?", user);
        SecurityContextHolder.clearContext();
    }

    @Test void repeatedDeliveryDoesNotCreateAnotherInitialHandoff() {
        UUID user = planner();
        deliver();
        assertEquals(1, count(user));
        deliver();
        assertEquals(1, count(user), "A repeated event is the same initial handoff, including acknowledged history");
    }

    @Test void delayedDeliveryCannotReviveAnOrderAlreadyTakenIntoAnalysis() {
        UUID user = planner();
        deliver();
        UUID item = jdbc.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted", UUID.class, order);
        analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "handoff-" + suffix(),
                List.of(new PreviewItem("SALES_ORDER_ITEM", item, null, null, null, null, null, null, BigDecimal.ONE))));
        assertEquals(0, activeCount(user));
        assertTrue(jdbc.queryForObject("SELECT qty-planned_qty>0 FROM sales_order_items WHERE id=?", Boolean.class, item));
        deliver();
        assertEquals(0, activeCount(user), "Positive remaining source demand is not an unhandled initial order");
        assertEquals(1, count(user));
    }

    @Test void successfulFinanceEventWithNoRecipientIsCaughtUpForALaterAccount() {
        drain(); // The original event completes before this account even exists.
        UUID user = planner();
        assertEquals(0, count(user));
        catchUp.runBatch();
        drain();
        assertEquals(1, count(user));
        assertEquals(0L, jdbc.queryForObject("SELECT source_revision FROM notices WHERE id=?", Long.class, noticeId(user)));
        fixture.loginAs(user);
        assertTrue(visible(user));
        catchUp.runBatch(); drain();
        assertEquals(1, count(user));
    }

    @Test void authorizationGrantedAfterASkippedSignalRemainsRetryable() {
        drain();
        UUID user = planner();
        catchUp.runBatch(); // Signal exists, then this user's write authority changes before delivery.
        override(user, "production_material_analysis:create", "revoke");
        drain();
        assertEquals(0, count(user));
        override(user, "production_material_analysis:create", "grant");
        catchUp.runBatch(); drain();
        assertEquals(1, count(user), "A skipped outbox signal must not consume the permanent delivery identity");
    }

    @Test void missingEachAuthorityOrPlanningMembershipNeverCreatesACard() {
        drain();
        UUID outside = fixture.createUserWithPerms(world, "outside-" + suffix(),
                "notice:read", "production_material_analysis:view", "production_material_analysis:create");
        recipients.add(outside);
        for (String authority : List.of("notice:read", "production_material_analysis:view", "production_material_analysis:create")) {
            UUID user = planner();
            override(user, authority, "revoke");
            catchUp.runBatch(); drain();
            assertEquals(0, count(user), authority);
        }
        assertEquals(0, count(outside));
    }

    @Test void readAcknowledgedDeletedAndSnoozedReceiptsAreNeverReset() {
        drain();
        for (String state : List.of("read", "ack", "delete", "snooze")) {
            UUID user = planner();
            catchUp.runBatch(); drain();
            fixture.loginAs(user);
            UUID notice = noticeId(user);
            switch (state) {
                case "read" -> notices.markRead(notice);
                case "ack" -> notices.acknowledgePopup(notice);
                case "delete" -> notices.deleteForCurrentUser(List.of(notice));
                case "snooze" -> notices.snoozeNotice(notice, 5);
                default -> fail();
            }
            String before = jdbc.queryForObject("SELECT row_to_json(s)::text FROM notice_user_states s WHERE notice_id=? AND user_id=?",
                    String.class, notice, user);
            catchUp.runBatch(); deliver(); drain();
            assertEquals(1, count(user));
            assertEquals(before, jdbc.queryForObject("SELECT row_to_json(s)::text FROM notice_user_states s WHERE notice_id=? AND user_id=?",
                    String.class, notice, user));
        }
    }

    @Test void partialAnalysisBeforeAnyAccountAndItsCancellationNeverReopensInitialHandoff() {
        drain();
        AnalysisView analysis = takeIntoAnalysis();
        UUID user = planner();
        catchUp.runBatch(); deliver(); drain();
        assertEquals(0, count(user));
        analysisCommands.cancelAnalysis(analysis.analysisId(), new CancelRequest(analysis.version(), analysis.fingerprint(),
                "cancel-handoff-" + suffix(), "保留已接手历史"));
        catchUp.runBatch(); deliver(); drain();
        assertEquals(0, count(user));
    }

    @Test void twoCatchUpsAndNormalDeliveryShareTheOrderLock() throws Exception {
        UUID user = planner();
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(3)) {
            var jobs = List.of(pool.submit(() -> after(start, () -> transactions.executeWithoutResult(s -> chain.enqueueSalesPlanningCatchUp(order)))),
                    pool.submit(() -> after(start, this::deliver)),
                    pool.submit(() -> after(start, () -> transactions.executeWithoutResult(s -> chain.enqueueSalesPlanningCatchUp(order)))));
            start.countDown();
            for (var job : jobs) job.get(20, TimeUnit.SECONDS);
        }
        drain();
        assertEquals(1, count(user));
    }

    @Test void sourceCreationRacingDeliveryLeavesNoActiveInitialCard() throws Exception {
        UUID user = planner();
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var delivery = pool.submit(() -> after(start, this::deliver));
            var handoff = pool.submit(() -> after(start, () -> {
                fixture.loginAs(world.superAdminUserId());
                try { takeIntoAnalysis(); } finally { SecurityContextHolder.clearContext(); }
            }));
            start.countDown();
            delivery.get(20, TimeUnit.SECONDS); handoff.get(20, TimeUnit.SECONDS);
        }
        catchUp.runBatch(); drain();
        assertEquals(0, activeCount(user));
        assertTrue(count(user) <= 1);
    }

    @Test void busyBusinessOrderIsSkippedWithoutWaitingAndCanBeCaughtUpAfterRelease() throws Exception {
        drain();
        UUID user = planner();
        CountDownLatch locked = new CountDownLatch(1), release = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var owner = pool.submit(() -> transactions.executeWithoutResult(status -> {
                jdbc.queryForObject("SELECT id FROM sales_orders WHERE id=? FOR UPDATE", UUID.class, order);
                locked.countDown();
                after(release, () -> {});
            }));
            try {
                assertTrue(locked.await(5, TimeUnit.SECONDS));
                var reconcile = pool.submit(() -> chain.enqueueSalesPlanningCatchUp(order));
                assertFalse(reconcile.get(5, TimeUnit.SECONDS), "Normal business contention is skipped, not an error or an indefinite wait");
                assertEquals(0, count(user));
            } finally { release.countDown(); }
            owner.get(5, TimeUnit.SECONDS);
        }
        assertTrue(chain.enqueueSalesPlanningCatchUp(order));
        drain();
        assertEquals(1, count(user));
    }

    @Test void failureAfterNoticeAndStateWriteRollsBackAndRetriesExactlyOnce() {
        drain();
        UUID user = planner();
        catchUp.runBatch();
        doAnswer(call -> { call.callRealMethod(); throw new IllegalStateException("intentional post-write failure"); })
                .when(notices).publishSalesPlanningHandoff(eq(user), eq(order), anyLong(), anyString(), anyString());
        // Other eligible synthetic orders may be before this one in the shared outbox queue.
        assertThrows(OutboxDeliveryException.class, this::drain);
        assertEquals(0, count(user));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM notice_user_states s JOIN notices n ON n.id=s.notice_id "
                + "WHERE n.aggregate_id=? AND s.user_id=?", Integer.class, order, user));
        doCallRealMethod().when(notices).publishSalesPlanningHandoff(eq(user), eq(order), anyLong(), anyString(), anyString());
        catchUp.runBatch(); drain();
        assertEquals(1, count(user));
    }

    @Test void sameContentResubmissionKeepsUnansweredPlanningCardAndSingleConfirmationDoesNotMarkItRead() {
        UUID user = planner();
        deliver();
        UUID original = noticeId(user);
        resubmit("10");
        assertEquals(0L, revision());
        fixture.loginAs(user);
        assertFalse(visible(user), "Planning cannot act during the finance gate");
        assertTrue(notices.pendingReviewStatus(List.of(original)).isEmpty(), "An already open popup must also lose actionability");
        fixture.loginAs(world.superAdminUserId());
        confirm(false);
        drain();
        assertEquals(1, count(user));
        assertEquals(original, noticeId(user));
        assertEquals(1, activeCount(user));
        assertNull(jdbc.queryForObject("SELECT read_at FROM notice_user_states WHERE notice_id=? AND user_id=?",
                java.sql.Timestamp.class, original, user));
        fixture.loginAs(user);
        assertTrue(visible(user));
    }

    @Test void acknowledgedSameRevisionSurvivesBatchConfirmationAndGenuineNewRevisionCanNotifyAgain() {
        UUID user = planner();
        deliver();
        fixture.loginAs(user); notices.markRead(noticeId(user));
        fixture.loginAs(world.superAdminUserId());
        resubmit("10"); assertEquals(0L, revision()); confirm(true); drain();
        assertEquals(1, count(user));
        fixture.loginAs(user); assertFalse(visible(user));
        fixture.loginAs(world.superAdminUserId());
        resubmit("11"); assertEquals(1L, revision()); confirm(true);
        transactions.executeWithoutResult(status -> chain.deliverOutboxEvent("SALES_ORDER_FINANCE_CONFIRMED", order,
                json.createObjectNode().put("reviewRevision", 0L)));
        assertEquals(1, count(user), "Old revision delivery cannot represent the newly confirmed revision");
        drain();
        assertEquals(2, count(user));
        fixture.loginAs(user); assertTrue(visible(user));
    }

    @Test void cancelledAndFinanceRejectedOrdersCannotBeCaughtUp() {
        drain();
        UUID user = planner();
        resubmit("10");
        var claim = claims.claim("SALES_ORDER_FINANCE_CONFIRM", order.toString());
        finance.reject(order, new SalesOrderFinanceConfirmService.FinanceRejectRequest("核对后再提交", revision(), claim.claimId()));
        catchUp.runBatch(); deliver(); drain();
        assertEquals(0, count(user));
        sales.cancel(order);
        catchUp.runBatch(); deliver(); drain();
        assertEquals(0, count(user));
    }

    @Test void legacyReceiptWithoutAProvableRevisionIsNotRewrittenOrDuplicated() {
        UUID user = planner();
        UUID old = transactions.execute(status -> notices.publishForUser(user, "历史计划提醒", "已有接收记录", "task", "系统",
                "/production/material-analysis", "SALES_ORDER_APPROVED", "normal", order).getId());
        fixture.loginAs(user); notices.markRead(old);
        fixture.loginAs(world.superAdminUserId());
        resubmit("11"); confirm(false);
        catchUp.runBatch(); drain();
        assertEquals(1, count(user));
        assertNull(jdbc.queryForObject("SELECT source_revision FROM notices WHERE id=?", Long.class, old));
        assertNotNull(jdbc.queryForObject("SELECT popup_acknowledged_at FROM notice_user_states WHERE notice_id=? AND user_id=?",
                java.sql.Timestamp.class, old, user));
        UUID newcomer = planner();
        catchUp.runBatch(); drain();
        assertEquals(1, count(newcomer));
        assertEquals(1L, jdbc.queryForObject("SELECT source_revision FROM notices WHERE id=?", Long.class, noticeId(newcomer)));
    }

    @Test void secondaryPlanningMembershipWorksButDisabledAndDeletedAccountsDoNot() {
        drain();
        UUID secondary = fixture.createUserWithPerms(world, "secondary-" + suffix(),
                "notice:read", "production_material_analysis:view", "production_material_analysis:create");
        recipients.add(secondary);
        jdbc.update("INSERT INTO employee_secondary_departments(employee_id,department_id) "
                + "SELECT u.employee_id,d.id FROM users u,departments d WHERE u.id=? AND d.code='SUB_PLAN' AND NOT d.is_deleted", secondary);
        UUID disabled = planner(), deleted = planner();
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?", disabled);
        jdbc.update("UPDATE users SET is_deleted=true WHERE id=?", deleted);
        catchUp.runBatch(); drain();
        assertEquals(1, count(secondary));
        assertEquals(0, count(disabled)); assertEquals(0, count(deleted));
    }

    private AnalysisView takeIntoAnalysis() {
        UUID item = jdbc.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted", UUID.class, order);
        return analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "handoff-" + suffix(),
                List.of(new PreviewItem("SALES_ORDER_ITEM", item, null, null, null, null, null, null, BigDecimal.ONE))));
    }
    private void resubmit(String quantity) {
        var request = fixture.orderRequest(world, world.goodsA(), quantity, "100");
        request.getItems().getFirst().setId(jdbc.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted", UUID.class, order));
        sales.update(order, request);
    }
    private long revision() { return jdbc.queryForObject("SELECT finance_review_revision FROM sales_orders WHERE id=?", Long.class, order); }
    private void confirm(boolean batch) {
        var claim = claims.claim("SALES_ORDER_FINANCE_CONFIRM", order.toString());
        if (batch) finance.confirmBatch(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(
                List.of(order), null, Map.of(order, revision()), Map.of(order, claim.claimId())));
        else finance.confirm(order, new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, revision(), claim.claimId()));
    }
    private void override(UUID user, String authority, String effect) {
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,? FROM permissions WHERE code=? "
                + "ON CONFLICT(user_id,permission_id) DO UPDATE SET effect=EXCLUDED.effect", user, effect, authority);
    }
    private void drain() { for (int n=0; n<1000; n++) { if (!processor.processNext()) return; } fail("Outbox did not settle"); }
    private UUID noticeId(UUID user) {
        return jdbc.queryForObject("SELECT id FROM notices WHERE source_event='SALES_ORDER_APPROVED' AND aggregate_id=? "
                + "AND audience_user_id=? ORDER BY source_revision DESC NULLS LAST LIMIT 1", UUID.class, order, user);
    }
    private boolean visible(UUID user) {
        return notices.arrivals(null, null, 100).items().stream().anyMatch(row -> row.id().equals(noticeId(user).toString()));
    }
    private static void after(CountDownLatch start, Runnable task) {
        try { assertTrue(start.await(10, TimeUnit.SECONDS)); task.run(); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new AssertionError(e); }
    }

    private UUID planner() {
        UUID user = fixture.createUserWithPerms(world, "planner-" + suffix(),
                "notice:read", "production_material_analysis:view", "production_material_analysis:create");
        jdbc.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_PLAN' AND NOT is_deleted) "
                + "WHERE id=(SELECT employee_id FROM users WHERE id=?)", user);
        recipients.add(user);
        return user;
    }
    private void deliver() {
        transactions.executeWithoutResult(status -> chain.deliverOutboxEvent(
                "SALES_ORDER_FINANCE_CONFIRMED", order, json.createObjectNode()));
    }
    private int count(UUID user) {
        return jdbc.queryForObject("SELECT count(*) FROM notices WHERE source_event='SALES_ORDER_APPROVED' "
                + "AND aggregate_id=? AND audience_user_id=?", Integer.class, order, user);
    }
    private int activeCount(UUID user) {
        return jdbc.queryForObject("SELECT count(*) FROM notices WHERE source_event='SALES_ORDER_APPROVED' "
                + "AND aggregate_id=? AND audience_user_id=? AND resolved_at IS NULL", Integer.class, order, user);
    }
    private static String suffix() { return UUID.randomUUID().toString().substring(0, 8); }
}
