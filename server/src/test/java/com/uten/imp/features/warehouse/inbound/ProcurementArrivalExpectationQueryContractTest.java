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

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

class ProcurementArrivalExpectationQueryContractTest {

    @Test
    void pagedListClosesVisibilityPredicateBeforeGroupBy() {
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
        assertThat(parenthesisBalance(jdbc.expectationListSql)).isZero();
        assertThat(jdbc.expectationListSql.replaceAll("\\s+", " "))
                .contains("))) GROUP BY expectation.id");
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

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
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
