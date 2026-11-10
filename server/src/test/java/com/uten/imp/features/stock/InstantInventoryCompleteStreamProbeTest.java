package com.uten.imp.features.stock;

import com.uten.imp.common.report.ReportExportCursor;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.util.Locale;
import java.util.Properties;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 即时库存完整流) against the real developer
 * database, READ ONLY: drives the production {@link StockQueryService#instantInventory}
 * batches inside one repeatable-read transaction with a {@link ReportExportCursor} —
 * the exact read shape of {@code InstantInventoryCompleteStreamService} (first batch
 * rows+count+totals+facets, then rows-only batches from the single ordered scan).
 * Compare with {@code InstantInventoryProgressiveReadProbeTest}: 2026-11-09 the
 * per-request OFFSET ladder measured 79.7 s for 35,763 rows; this shape must be seconds.
 * Run: UTEN_INVENTORY_STREAM_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_INVENTORY_STREAM_PROBE", matches = "(?i)true")
class InstantInventoryCompleteStreamProbeTest {

    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static TransactionTemplate transactions;
    private static StockQueryService service;

    @BeforeAll static void start() {
        var ds = new DriverManagerDataSource(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"));
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(ds);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp");
        var props = new Properties();
        props.setProperty("hibernate.hbm2ddl.auto", "none");
        props.setProperty("hibernate.jdbc.time_zone", "UTC");
        props.setProperty("hibernate.dialect", "org.hibernate.dialect.PostgreSQLDialect");
        props.setProperty("hibernate.connection.isolation",
                String.valueOf(Connection.TRANSACTION_REPEATABLE_READ));
        bean.setJpaProperties(props);
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        var manager = new JpaTransactionManager(factory);
        transactions = new TransactionTemplate(manager);
        transactions.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        transactions.setReadOnly(true);
        transactions.setTimeout(300);
        var masker = mock(StockCostMasker.class);
        when(masker.canView()).thenReturn(false);
        service = new StockQueryService(mock(StockBalanceRepository.class), em, masker);
    }

    @AfterAll static void stop() {
        if (factory != null) factory.close();
    }

    @Test void singleScanCompleteStreamTimesTheProductionReadShape() {
        var plan = CompleteReadBatchPlan.PROGRESSIVE;
        var summary = transactions.execute(status -> {
            try (var cursor = ReportExportCursor.open()) {
                long start = System.nanoTime();
                long seen = 0, total = -1, firstMs = -1;
                int batches = 0;
                String head = null, tail = null;
                while (true) {
                    int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                    long b0 = System.nanoTime();
                    PageResponse<InstantInventoryRow> value;
                    try (var ignored = ReportReadPlan.open(
                            seen == 0 ? ReportReadPlan.ALL : ReportReadPlan.ROWS_ONLY)) {
                        value = service.instantInventory(null, null, false, null, page, size, null, null);
                    }
                    long b1 = System.nanoTime();
                    if (seen == 0) {
                        total = value.getTotal();
                        firstMs = (b1 - b0) / 1_000_000;
                        assertThat(total).isGreaterThanOrEqualTo(0);
                    } else if (value.getTotal() < 0) {
                        value = new PageResponse<>(value.getItems(), page, size, total,
                                ReportReadPlan.totalPages(total, size));
                    }
                    long expected = Math.max(0, Math.min(size, total - seen));
                    assertThat(value.getItems()).hasSize((int) expected);
                    for (InstantInventoryRow row : value.getItems()) {
                        if (head == null) head = row.getGoodsCode();
                        tail = row.getGoodsCode();
                    }
                    seen += expected;
                    batches++;
                    if (seen == total) break;
                }
                return String.format(Locale.ROOT,
                        "rows=%d batches=%d total_ms=%d first_batch_ms=%d(head=%s tail=%s)",
                        total, batches, (System.nanoTime() - start) / 1_000_000, firstMs, head, tail);
            }
        });
        System.out.println("INVENTORY_STREAM_PROBE single-scan " + summary);
    }
}
