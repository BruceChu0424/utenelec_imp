package com.uten.imp.features.operations.workbench;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.sql.Connection;
import java.util.Optional;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production fulfillment workbench versioned read
 * ({@code FulfillmentWorkbenchQueryService.queryVersioned} — the purchase / subcontract /
 * warehouse task-center queues) through the shared progressive ladder exactly as the
 * client's fetchPageSized batches do, including the real {@link VersionedSummaryPages}
 * proof machinery, with a permissive reader. The per-batch SQL is a candidates CTE whose
 * single statement recomputes COUNT per batch; the printed rows/batches/total_ms/
 * first_batch_ms show whether each queue clears the 3 s migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class FulfillmentWorkbenchLadderProbeTest {

    private static EntityManagerFactory factory;
    private static FulfillmentWorkbenchQueryService service;

    @BeforeAll static void start() {
        var source = new DriverManagerDataSource(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"));
        var jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(source);
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
        var authority = mock(ReadScopeVersionAuthority.class);
        when(authority.scopeForCurrentSnapshot(anyString(), any())).thenReturn("probe-scope");
        var current = mock(SecurityContextCurrentUser.class);
        UUID actor = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, actor, "ladder-probe",
                Set.of("purchase_order:view", "subcontract_order:view", "stock_doc:view",
                        "purchase_request:view", "subcontract_application:view"),
                false, true, false)));
        var pages = new VersionedSummaryPages(jdbc, authority, current, new ObjectMapper(),
                new JpaTransactionManager(factory));
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        when(access.documentAccess(anyString(), anyString()))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
        service = new FulfillmentWorkbenchQueryService(
                SharedEntityManagerCreator.createSharedEntityManager(factory), access, pages,
                new com.uten.imp.features.subcontract.kit.SubcontractKitService(jdbc, null));
    }

    @AfterAll static void stop() {
        if (factory != null) factory.close();
    }

    private static void ladder(String department) {
        var plan = CompleteReadBatchPlan.PROGRESSIVE;
        long start = System.nanoTime(), firstBatchMs = -1;
        long seen = 0, total = -1;
        int batches = 0;
        while (true) {
            int size = plan.sizeAt(seen), page = plan.pageAt(seen);
            long b0 = System.nanoTime();
            var result = service.queryVersioned(department, null, "", "", null, null,
                    page, size, null, WarehouseTaskScope.ALL, seen == 0);
            long b1 = System.nanoTime();
            if (seen == 0) {
                total = result.total();
                firstBatchMs = (b1 - b0) / 1_000_000;
                assertThat(total).isGreaterThanOrEqualTo(0);
            } else {
                assertThat(result.total()).isEqualTo(total);
            }
            seen += result.items().size();
            batches++;
            if (seen >= total) break;
        }
        assertThat(seen).isEqualTo(total);
        System.out.printf(java.util.Locale.ROOT,
                "LADDER_PROBE fulfillment_%s rows=%d batches=%d total_ms=%d first_batch_ms=%d%n",
                department.toLowerCase(java.util.Locale.ROOT), total, batches,
                (System.nanoTime() - start) / 1_000_000, firstBatchMs);
    }

    @Test void purchaseQueueLadder() { ladder("PURCHASE"); }

    @Test void subcontractQueueLadder() { ladder("SUBCONTRACT"); }

    @Test void warehouseQueueLadder() { ladder("WAREHOUSE"); }
}
