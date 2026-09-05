package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

class ProcurementArrivalExpectationQueryContractTest {

    @Test
    void listAndCountShareTheRealSubcontractOutboundVisibilityPredicate() {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate();
        ProcurementArrivalControlService service =
                new ProcurementArrivalControlService(
                        jdbc,
                        new ObjectMapper(),
                        mock(BusinessEventPublisher.class),
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class),
                        mock(FinanceReviewerEligibilityPort.class),
                        mock(ReceiptPriceMasker.class));

        service.expectations(1, 20, "", "");

        assertThat(jdbc.expectationListSql).isNotNull();
        assertThat(jdbc.expectationCountSql).isNotNull();
        assertThat(parenthesisBalance(jdbc.expectationListSql)).isZero();
        assertThat(parenthesisBalance(jdbc.expectationCountSql)).isZero();
        for (String sql : List.of(jdbc.expectationListSql, jdbc.expectationCountSql)) {
            assertThat(sql.replaceAll("\\s+", " "))
                    .contains("expectation.order_type <> 'SUBCONTRACT'")
                    .contains("subcontract_material_issue_items issue_item")
                    .contains("issue.status = 1")
                    .contains("release_plan.flow_mode IN")
                    .contains("'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND'")
                    .contains("procurement_iqc_rejection_cases rejection")
                    .contains("visible_item.expectation_id = expectation.id")
                    .doesNotContain("procurement_iqc_replacement_allocations");
        }
    }

    @Test
    void destinationPreviewUsesBasicUnitsAndIsBatchMappedOnce() throws Exception {
        assertThat(ProcurementArrivalControlService.receivableBaseQty(
                new BigDecimal("2"), BigDecimal.ZERO, new BigDecimal("24")))
                .isEqualByComparingTo("48");
        assertThat(Arrays.stream(ProcurementArrivalContracts.InboundExpectationItem.class
                        .getRecordComponents())
                .map(java.lang.reflect.RecordComponent::getName).toList())
                .contains("baseUnitId", "baseUnitName", "expectedAllocations");
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("inboundAllocationRead.expectedForOrderItems(")
                .contains("base_unit.name AS base_unit_name")
                .contains("OrderItemQuantity(");
        assertThat(count(source, "inboundAllocationRead.expectedForOrderItems("))
                .isEqualTo(1);
    }

    private static int count(String value, String token) {
        return (value.length() - value.replace(token, "").length()) / token.length();
    }

    private static int parenthesisBalance(String sql) {
        int balance = 0;
        for (int index = 0; index < sql.length(); index++) {
            balance += switch (sql.charAt(index)) {
                case '(' -> 1;
                case ')' -> -1;
                default -> 0;
            };
            assertThat(balance)
                    .as("SQL closes a parenthesis before it is opened at index %s", index)
                    .isGreaterThanOrEqualTo(0);
        }
        return balance;
    }

    private static final class CapturingJdbcTemplate extends JdbcTemplate {
        private String expectationListSql;
        private String expectationCountSql;

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
            if (sql.contains("FROM inbound_expectations expectation")) {
                expectationCountSql = sql;
            }
            return requiredType.cast(0L);
        }

        @Override
        public <T> List<T> query(String sql, RowMapper<T> rowMapper, Object... args) {
            if (sql.contains("GROUP BY expectation.id")) {
                expectationListSql = sql;
            }
            return List.of();
        }
    }
}
