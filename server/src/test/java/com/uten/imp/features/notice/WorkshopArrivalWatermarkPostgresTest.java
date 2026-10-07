package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real PostgreSQL issue/arrival baseline updates, independent of outbox delivery order. */
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
        jdbc.execute("CREATE TABLE production_execution_segments(id uuid PRIMARY KEY, package_id uuid, start_route text, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE production_material_demands(id uuid PRIMARY KEY, execution_segment_id uuid, is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE production_planning_package_document_items(document_id uuid, document_type text, demand_id uuid, package_id uuid)");
        jdbc.execute("CREATE TABLE production_execution_segment_notice_state(segment_id uuid PRIMARY KEY, arrival_notice_capacity numeric, updated_at timestamptz DEFAULT now())");
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
        UUID unrelated = segment(UUID.randomUUID(), "CONTINUOUS", "100", "0");
        var outbox = mock(BusinessEventPublisher.class);
        var service = new ChainNoticeService(mock(NoticeService.class), mock(UserAccountRepository.class),
                mock(PermissionResolver.class), jdbc, outbox, mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class), mock(SalesOrderFinanceConfirmerEligibility.class));
        doAnswer(call -> {
            assertThat(mark(continuous)).isZero(); // reset is committed with the issue, before delivery
            return null;
        }).when(outbox).publishOnce(anyString(), anyString(), any(), any(), anyString());
        tx.executeWithoutResult(status -> service.notifyProductionDrawIssued(draw, "issue-first-100"));
        assertThat(mark(fullKit)).isEqualByComparingTo("100");
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
            service.lowerWorkshopArrivalCapacityAfterIssue(draw);
            assertThat(mark(continuous)).isEqualByComparingTo("50");
            status.setRollbackOnly();
        });
        assertThat(mark(continuous)).isEqualByComparingTo("100");
    }

    private UUID segment(UUID draw, String route, String watermark, String remaining) {
        UUID id = UUID.randomUUID(), demand = UUID.randomUUID(), pack = UUID.randomUUID();
        jdbc.update("INSERT INTO production_execution_segments(id,package_id,start_route) VALUES (?,?,?)", id, pack, route);
        jdbc.update("INSERT INTO production_material_demands(id,execution_segment_id) VALUES (?,?)", demand, id);
        jdbc.update("INSERT INTO production_planning_package_document_items VALUES (?,'DRAW',?,?)", draw, demand, pack);
        jdbc.update("INSERT INTO production_execution_segment_notice_state(segment_id,arrival_notice_capacity) VALUES (?,?)", id, new BigDecimal(watermark));
        jdbc.update("INSERT INTO capacity_fixture VALUES (?,?)", id, new BigDecimal(remaining));
        return id;
    }

    private BigDecimal mark(UUID segment) {
        return jdbc.queryForObject("SELECT arrival_notice_capacity FROM production_execution_segment_notice_state WHERE segment_id=?", BigDecimal.class, segment);
    }
}
