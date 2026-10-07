package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/**
 * Real PostgreSQL issue/arrival baseline updates, independent of outbox delivery order.
 * Production relation columns come from the current Flyway catalog. Capacity is a private
 * function oracle: these tests cover issue scope, transaction rollback and row locking;
 * full physical capacity and business constraints are covered by the full-chain suites.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopArrivalWatermarkPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static TransactionTemplate tx;

    @BeforeAll static void start() {
        DB.start();
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        tx = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        MigratedProjectionSchema.createCurrentTables(jdbc,
                "production_execution_segments", "production_material_demands",
                "production_planning_package_document_items", "production_material_stock_postings",
                "production_execution_segment_notice_state");
        // Capacity computation has its own full-domain tests. This fixture changes physical capacity
        // independently, so the authoritative UPDATE is tested for scope and monotonicity.
        jdbc.execute("CREATE TABLE capacity_fixture(segment_id uuid PRIMARY KEY, remaining numeric)");
        jdbc.execute("CREATE FUNCTION fn_execution_material_output_capacity(uuid, boolean) RETURNS numeric LANGUAGE sql AS 'SELECT remaining FROM capacity_fixture WHERE segment_id=$1'");
    }

    @AfterAll static void stop() { DB.stop(); }

    @Test void issueLowersOnlyItsContinuousSegmentsBeforeOutboxAndLaterSmallerArrivalCanNotify() {
        UUID draw = UUID.randomUUID();
        UUID continuous = segment(draw, "CONTINUOUS", "100", "0");
        UUID fullKit = segment(draw, "FULL_KIT", "100", "0");
        UUID notIssued = segment(draw, "CONTINUOUS", "100", "0");
        UUID unrelated = segment(UUID.randomUUID(), "CONTINUOUS", "100", "0");
        var outbox = mock(BusinessEventPublisher.class);
        var service = new ChainNoticeService(mock(NoticeService.class), mock(UserAccountRepository.class),
                mock(PermissionResolver.class), jdbc, outbox, mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class), mock(SalesOrderFinanceConfirmerEligibility.class));
        doAnswer(call -> {
            assertThat(mark(continuous)).isZero(); // reset is committed with the issue, before delivery
            return null;
        }).when(outbox).publishOnce(anyString(), anyString(), any(), any(), anyString());
        tx.executeWithoutResult(status -> {
            post(continuous);
            post(fullKit);
            service.notifyProductionDrawIssued(draw, "issue-first-100");
        });
        assertThat(mark(fullKit)).isEqualByComparingTo("100");
        assertThat(mark(notIssued)).isEqualByComparingTo("100");
        assertThat(mark(unrelated)).isEqualByComparingTo("100");

        // No intermediate receipt was necessary to reset 100. A new batch of 50 is actionable.
        jdbc.update("UPDATE capacity_fixture SET remaining=50 WHERE segment_id=?", continuous);
        assertThat(service.arrivalProgressWarrantsNotice(
                java.util.Map.of("arrival_notice_capacity", mark(continuous)), "IN_PROGRESS", "CONTINUOUS", new BigDecimal("50"))).isTrue();
        tx.executeWithoutResult(status -> service.lowerWorkshopArrivalCapacityAfterIssue(draw));
        assertThat(mark(continuous)).isZero(); // issue replay cannot consume a new receipt's notification

        // Source issue rollback also rolls back its baseline; no notification state leaks.
        jdbc.update("UPDATE production_execution_segment_notice_state SET arrival_notice_capacity=100 WHERE segment_id=?", continuous);
        tx.executeWithoutResult(status -> {
            post(continuous);
            service.lowerWorkshopArrivalCapacityAfterIssue(draw);
            assertThat(mark(continuous)).isEqualByComparingTo("50");
            status.setRollbackOnly();
        });
        assertThat(mark(continuous)).isEqualByComparingTo("100");
    }

    @Test void capacityHookDoesNotWaitForAnUnissuedSiblingOnTheSameDraw() throws Exception {
        UUID draw = UUID.randomUUID();
        UUID issued = segment(draw, "CONTINUOUS", "100", "0");
        UUID sibling = segment(draw, "CONTINUOUS", "100", "0");
        var service = new ChainNoticeService(mock(NoticeService.class), mock(UserAccountRepository.class),
                mock(PermissionResolver.class), jdbc, mock(BusinessEventPublisher.class), mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class), mock(SalesOrderFinanceConfirmerEligibility.class));
        var locked = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        try (var executor = Executors.newSingleThreadExecutor()) {
            var holdingSibling = executor.submit(() -> tx.executeWithoutResult(status -> {
                jdbc.queryForList("SELECT id FROM production_execution_segments WHERE id=? FOR UPDATE", sibling);
                locked.countDown();
                try {
                    if (!release.await(5, TimeUnit.SECONDS)) throw new AssertionError("sibling lock was not released");
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError(interrupted);
                }
            }));
            try {
                assertThat(locked.await(5, TimeUnit.SECONDS)).isTrue();
                tx.executeWithoutResult(status -> {
                    jdbc.execute("SET LOCAL lock_timeout='1s'");
                    post(issued);
                    service.lowerWorkshopArrivalCapacityAfterIssue(draw);
                });
                assertThat(mark(issued)).isZero();
                assertThat(mark(sibling)).isEqualByComparingTo("100");
            } finally {
                release.countDown();
            }
            holdingSibling.get(5, TimeUnit.SECONDS);
        }
    }

    private UUID segment(UUID draw, String route, String watermark, String remaining) {
        UUID id = UUID.randomUUID(), demand = UUID.randomUUID(), pack = UUID.randomUUID();
        jdbc.update("INSERT INTO production_execution_segments(id,package_id,start_route) VALUES (?,?,?)", id, pack, route);
        jdbc.update("INSERT INTO production_material_demands(id,execution_segment_id) VALUES (?,?)", demand, id);
        jdbc.update("""
                INSERT INTO production_planning_package_document_items
                    (document_id, document_type, demand_id, package_id, document_item_id)
                VALUES (?,'DRAW',?,?,?)
                """, draw, demand, pack, UUID.randomUUID());
        jdbc.update("INSERT INTO production_execution_segment_notice_state(segment_id,arrival_notice_capacity) VALUES (?,?)", id, new BigDecimal(watermark));
        jdbc.update("INSERT INTO capacity_fixture(segment_id,remaining) VALUES (?,?)", id, new BigDecimal(remaining));
        return id;
    }

    private BigDecimal mark(UUID segment) {
        return jdbc.queryForObject("SELECT arrival_notice_capacity FROM production_execution_segment_notice_state WHERE segment_id=?", BigDecimal.class, segment);
    }

    private void post(UUID segment) {
        jdbc.update("""
                INSERT INTO production_material_stock_postings
                    (demand_id, stock_document_item_id, posting_type, recorded_tx_id)
                SELECT demand.id, mapping.document_item_id, 'ISSUE', pg_current_xact_id()
                FROM production_material_demands demand
                JOIN production_planning_package_document_items mapping ON mapping.demand_id = demand.id
                WHERE demand.execution_segment_id = ?
                """, segment);
    }
}
