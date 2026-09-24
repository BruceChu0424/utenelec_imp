package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Exercises the actual snapshot SQL without business-order rows to fall back to. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementApprovalRevisionSnapshotPostgresTest {
    @Test
    void bothOrderTypesKeepDeletedRowsAndExactAmountsBoundToEachSubmission() {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("procurement_revision_review")
                .withUsername("uten").withPassword("uten-test-only")) {
            postgres.start();
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            jdbc.execute("""
                    CREATE TABLE procurement_order_approval_cases (
                        id uuid, order_type text, order_id uuid, attempt integer, submission_snapshot jsonb, display_snapshot jsonb);
                    CREATE TABLE goods (id uuid, code text, name text);
                    CREATE TABLE colors (id uuid, name text);
                    CREATE TABLE units (id uuid, name text);
                    CREATE TABLE currencies (id uuid, name text);
                    CREATE TABLE purchase_order_item_sources (order_item_id uuid, request_item_id uuid);
                    CREATE TABLE purchase_request_items (id uuid, request_id uuid);
                    CREATE TABLE purchase_requests (id uuid, bill_no text);
                    CREATE TABLE subcontract_order_item_sources (order_item_id uuid, application_item_id uuid);
                    CREATE TABLE subcontract_application_items (id uuid, application_id uuid);
                    CREATE TABLE subcontract_applications (id uuid, bill_no text);
                    """);
            ProcurementFinanceApprovalService service = new ProcurementFinanceApprovalService(
                    List.of(), jdbc, new ObjectMapper(), mock(BusinessEventPublisher.class),
                    mock(WorkflowReviewerEligibility.class), mock(ProcurementApprovalProjectionQuery.class),
                    mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class),
                    mock(com.uten.imp.features.notice.ChainNoticeService.class),
                    mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                    mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class));
            UUID dollars = UUID.randomUUID(), yuan = UUID.randomUUID();
            jdbc.update("INSERT INTO currencies VALUES (?, ?)", dollars, "美元");
            jdbc.update("INSERT INTO currencies VALUES (?, ?)", yuan, "人民币");
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                UUID order = UUID.randomUUID(), first = UUID.randomUUID(), second = UUID.randomUUID();
                UUID existing = UUID.randomUUID(), deleted = UUID.randomUUID(), added = UUID.randomUUID();
                insert(jdbc, first, type, order, 1,
                        row(existing, 1, "10", "19.999999999999") + "," + row(deleted, 2, "5", "10"), dollars);
                insert(jdbc, second, type, order, 2,
                        row(existing, 1, "12", "24") + "," + row(added, 3, "8", "16"), yuan);
                // A later submission must never replace the reviewed case's quantities.
                insert(jdbc, UUID.randomUUID(), type, order, 3, row(existing, 1, "999", "1998"), yuan);
                List<ProcurementApprovalContracts.ReviewLine> before = lines(service, type, second, true);
                List<ProcurementApprovalContracts.ReviewLine> after = lines(service, type, second, false);
                assertThat(before).extracting(ProcurementApprovalContracts.ReviewLine::orderItemId)
                        .containsExactly(existing, deleted);
                assertThat(before.getFirst().amountOriginal()).isEqualByComparingTo("19.999999999999");
                assertThat(before.getFirst().currencyName()).isEqualTo("美元");
                assertThat(after.getFirst().currencyName()).isEqualTo("人民币");
                assertThat(after).extracting(ProcurementApprovalContracts.ReviewLine::orderItemId)
                        .containsExactly(existing, added);
                assertThat(after.getFirst().qty()).isEqualByComparingTo(new BigDecimal("12"));
                assertThat(lines(service, type, first, true)).isEmpty();
            }
        }
    }

    private static void insert(JdbcTemplate jdbc, UUID id, String type, UUID order, int attempt, String rows, UUID currency) {
        jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,submission_snapshot) VALUES (?, ?, ?, ?, CAST(? AS jsonb))",
                id, type, order, attempt, "{\"currencyId\":\"" + currency + "\",\"items\":[" + rows + "]}");
    }

    private static String row(UUID id, int number, String qty, String amount) {
        return """
                {"itemId":"%s","lineNo":%d,"qty":"%s","price":"2",
                 "amountOriginal":"%s","amountLocal":"%s","deliverDate":"2026-10-01"}
                """.formatted(id, number, qty, amount, amount);
    }

    private static List<ProcurementApprovalContracts.ReviewLine> lines(
            ProcurementFinanceApprovalService service, String type, UUID id, boolean previous) {
        return ReflectionTestUtils.invokeMethod(service, "loadReviewLines", type, id, previous);
    }
}
