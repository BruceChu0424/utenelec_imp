package com.uten.imp.common.report;

import com.uten.imp.common.web.CompleteReadBatchPlan;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probes (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: each test drives one production report-table read (the six report
 * pages' complete-read path behind {@code ReportPagedRead}: first batch rows+count+facets+
 * totals, then aligned continuation batches with the same rows-only read plan the client's
 * metadataReuse requests produce) through the shared progressive ladder. Printed
 * rows/batches/total_ms/first_batch_ms show whether each family clears the 3 s migration
 * bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class ReportTableLadderProbeTest {

    /** page, size and first-batch flag of one ladder batch. */
    private interface PageCallback {
        Batch read(int page, int size, boolean metadata);
    }

    private record Batch(long total, int rows) { }

    private static String ladder(String family, PageCallback pageCallback) {
        var plan = CompleteReadBatchPlan.PROGRESSIVE;
        long start = System.nanoTime(), firstBatchMs = -1;
        long seen = 0, total = -1;
        int batches = 0;
        while (true) {
            int size = plan.sizeAt(seen), page = plan.pageAt(seen);
            long b0 = System.nanoTime();
            Batch batch = pageCallback.read(page, size, seen == 0);
            long b1 = System.nanoTime();
            if (seen == 0) {
                total = batch.total();
                firstBatchMs = (b1 - b0) / 1_000_000;
                assertThat(total).isGreaterThanOrEqualTo(0);
            } else {
                assertThat(batch.total()).isEqualTo(total);
            }
            seen += batch.rows();
            batches++;
            if (seen >= total) break;
        }
        assertThat(seen).isEqualTo(total);
        return String.format(java.util.Locale.ROOT,
                "LADDER_PROBE %s rows=%d batches=%d total_ms=%d first_batch_ms=%d",
                family, total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs);
    }

    private interface ConnectionConsumer {
        void run(Connection connection) throws Exception;
    }

    private static void withReadOnlyConnection(ConnectionConsumer body) throws Exception {
        try (Connection connection = DriverManager.getConnection(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"))) {
            connection.setAutoCommit(false);
            connection.setReadOnly(true);
            try (var statement = connection.createStatement()) {
                statement.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY");
                statement.execute("SET LOCAL statement_timeout = '180s'");
                statement.execute("SET LOCAL lock_timeout = '2s'");
                statement.execute("SET LOCAL jit = off");
            }
            body.run(connection);
            connection.rollback();
        }
    }

    private static EntityManager forwardingEntityManager(NamedParameterJdbcTemplate named) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(named, call.getArgument(0)));
        return em;
    }

    private static Query query(NamedParameterJdbcTemplate named, String sql) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        return mock(Query.class, call -> {
            String method = call.getMethod().getName();
            if (method.equals("setParameter")) { parameters.put(call.getArgument(0), call.getArgument(1)); return call.getMock(); }
            if (method.equals("getResultList") || method.equals("getSingleResult")) {
                if (method.equals("getSingleResult")) return named.queryForObject(sql, parameters, Object.class);
                return named.query(sql, parameters, (rs, row) -> {
                    if (rs.getMetaData().getColumnCount() == 1) return rs.getObject(1);
                    Object[] values = new Object[rs.getMetaData().getColumnCount()];
                    for (int column = 0; column < values.length; column++) values[column] = rs.getObject(column + 1);
                    return values;
                });
            }
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }

    @Test
    void salesOrderDetailLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var named = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            var priceMasker = mock(com.uten.imp.features.sales.order.SalesPriceMasker.class);
            when(priceMasker.canView()).thenReturn(true);
            var accessPolicy = mock(com.uten.imp.features.sales.SalesDocumentAccessPolicy.class);
            when(accessPolicy.scope()).thenReturn(
                    new com.uten.imp.security.OwnerVisibility.OwnerScope(true, Set.of()));
            when(accessPolicy.nativeReadScope(anyString(), anyString()))
                    .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
            when(accessPolicy.nativeReadScope(anyString(), anyString(),
                    org.mockito.ArgumentMatchers.<String>any()))
                    .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
            when(accessPolicy.nativeReadScope(anyString(), anyString(),
                    any(com.uten.imp.security.OwnerVisibility.OwnerScope.class)))
                    .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
            var service = new com.uten.imp.features.sales.report.SalesReportService(
                    forwardingEntityManager(named), priceMasker, accessPolicy);
            System.out.println(ladder("sales_order_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.orderDetail(null, null, null, null, null,
                            null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    @Test
    void purchaseOrderDetailLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var service = new com.uten.imp.features.purchase.report.PurchaseReportService(
                    forwardingEntityManager(named(connection)));
            System.out.println(ladder("purchase_order_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.orderDetail(null, null, null, null, null,
                            null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    @Test
    void productionPlanDetailLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var service = new com.uten.imp.features.production.report.ProductionReportService(
                    forwardingEntityManager(named(connection)));
            System.out.println(ladder("production_plan_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.planDetail(null, null, null, null, null,
                            null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    @Test
    void subcontractOrderDetailLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var service = new com.uten.imp.features.subcontract.report.SubcontractReportService(
                    forwardingEntityManager(named(connection)));
            System.out.println(ladder("subcontract_order_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.orderDetail(null, null, null, null, null,
                            null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    @Test
    void stockReportDetailAndSummaryLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var em = forwardingEntityManager(named(connection));
            var service = new com.uten.imp.features.stock.report.StockReportService(em,
                    mock(com.uten.imp.features.stock.StockQueryService.class),
                    mock(com.uten.imp.features.stock.StockCostMasker.class));
            System.out.println(ladder("stock_report_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.detail("TRANSFER", null, null, null, null, null,
                            null, null, null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
            System.out.println(ladder("stock_report_summary", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.summary("TRANSFER", null, null, null, null, null,
                            null, null, null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    @Test
    void financeArApDetailLadder() throws Exception {
        withReadOnlyConnection(connection -> {
            var access = mock(com.uten.imp.features.finance.FinanceDocumentAccessPolicy.class);
            when(access.scope()).thenReturn(
                    new com.uten.imp.security.OwnerVisibility.OwnerScope(true, Set.of()));
            var service = new com.uten.imp.features.finance.report.FinanceReportService(
                    forwardingEntityManager(named(connection)), access,
                    mock(com.uten.imp.features.admin.systemsetting.SystemSettingsService.class),
                    mock(com.uten.imp.features.finance.statement.FinanceStatementService.class),
                    mock(com.uten.imp.features.finance.cost.FinanceCostService.class),
                    mock(com.uten.imp.features.finance.gl.GlReportService.class),
                    mock(com.uten.imp.features.finance.asset.FixedAssetService.class),
                    mock(com.uten.imp.features.finance.report.PartyMonthlySummaryService.class));
            System.out.println(ladder("finance_ar_ap_detail", (page, size, metadata) -> {
                try (var plan = ReportReadPlan.open(
                        metadata ? ReportReadPlan.ALL : new ReportReadPlan(false, false, false))) {
                    var result = service.arApDetail("AR", null, null, null, null, null,
                            null, Map.of(), page, size, null, null);
                    return new Batch(result.total(), result.rows().size());
                }
            }));
        });
    }

    private static NamedParameterJdbcTemplate named(Connection connection) {
        return new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
    }
}
