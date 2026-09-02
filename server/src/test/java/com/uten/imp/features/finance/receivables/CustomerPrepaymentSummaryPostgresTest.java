package com.uten.imp.features.finance.receivables;

import com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.SalesOrderMoneySummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL proof that the sales-order money summary executes every native
 * aggregate (aliases must avoid reserved words such as OFFSET) and stays conservative
 * on an order without any receipts, ledger rows, or prepayment offsets.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=prepayment-summary-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=prepayment-summary-harness-pgp-key-test-only-0123456",
                "uten.crypto.hmac-key=prepayment-summary-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=prepayment-summary-bootstrap-admin-test",
                "uten.bootstrap.admin-password=PrepaymentSummaryAdminPass-1!"
        })
class CustomerPrepaymentSummaryPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private CustomerPrepaymentQueryService service;

    @Test
    void summaryExecutesAllAggregatesAndReportsZeroMoneyForAnOrderWithoutActivity() {
        UUID clientId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        String suffix = orderId.toString().replace("-", "").substring(0, 6).toUpperCase(java.util.Locale.ROOT);
        // fn_reserve_business_document_identifier 要求 XD+YYYYMMDD+6位流水
        String orderBillNo = "XD20260827000001";
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type)
                VALUES(?,?,?,'使用',2,'MONTHLY')
                """, clientId, "CP-SUM-" + suffix, "Customer prepayment summary");
        jdbc.update("""
                INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,?,1,'使用')
                """, currencyId, "SUM-" + suffix, "Summary currency");
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    total_original,total_local,status,is_closed,is_stopped,deposit,shipment_policy)
                VALUES(?,?,DATE '2026-08-27',?,?,1,20,20,1,FALSE,FALSE,0,'ALLOW_PARTIAL')
                """, orderId, orderBillNo, clientId, currencyId);

        SalesOrderMoneySummary summary = service.salesOrderSummary(orderId);

        assertThat(summary.salesOrderId()).isEqualTo(orderId);
        assertThat(summary.orderBillNo()).isEqualTo(orderBillNo);
        assertThat(summary.orderTotalOriginal()).isEqualTo("20.0000");
        assertThat(summary.formalArOriginal()).isEqualTo("0.0000");
        assertThat(summary.cashReceivedOriginal()).isEqualTo("0.0000");
        assertThat(summary.prepaymentAppliedOriginal()).isEqualTo("0.0000");
        assertThat(summary.prepaymentAppliedTargetBookLocal()).isEqualTo("0.0000");
        assertThat(summary.prepaymentExchangeDifferenceLocal()).isEqualTo("0.0000");
        assertThat(summary.arOutstandingOriginal()).isEqualTo("0.0000");
        assertThat(summary.plannedRemainingOriginal()).isEqualTo("20.0000");
        assertThat(summary.overpaidOriginal()).isEqualTo("0.0000");
        assertThat(summary.hasUnallocated()).isFalse();
        assertThat(summary.unallocatedReceiptLines()).isEmpty();
        assertThat(summary.warnings()).isEmpty();
    }
}
