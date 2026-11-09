package com.uten.imp.features.operations.workbench;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.testsupport.TestFlyway;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The workbench page proof on the fully migrated schema (V1123): every page of one
 * query carries the same revision, any committed write to a page source moves it,
 * and page number/metadata choice never enter it. Business rows are out of scope
 * here; the page SQL itself is exercised over the real catalog.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentWorkbenchVersionedReadPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig().withMemory(1536L * 1024 * 1024));
    private static JdbcTemplate jdbc;
    private static EntityManagerFactory factory;
    private static JpaTransactionManager manager;
    private final AtomicInteger scopeCalls = new AtomicInteger();
    private volatile String scope = "scope-a";
    private FulfillmentWorkbenchQueryService service;

    @BeforeAll static void start() {
        POSTGRES.start();
        TestFlyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .load().migrate();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(source);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        // Native page SQL only; one tiny entity package keeps Hibernate bootable.
        bean.setPackagesToScan("com.uten.imp.features.sales.order");
        var props = new Properties();
        props.setProperty("hibernate.hbm2ddl.auto", "none");
        bean.setJpaProperties(props);
        bean.afterPropertiesSet();
        factory = bean.getObject();
        manager = new JpaTransactionManager(factory);
    }

    @AfterAll static void stop() {
        if (factory != null) factory.close();
        POSTGRES.stop();
    }

    @BeforeEach void prepare() {
        var authority = mock(ReadScopeVersionAuthority.class);
        when(authority.scopeForCurrentSnapshot(anyString(), any())).thenAnswer(call -> {
            scopeCalls.incrementAndGet();
            return scope;
        });
        var current = mock(SecurityContextCurrentUser.class);
        UUID actor = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, actor, "workbench-fixture",
                Set.of("purchase_order:view", "subcontract_order:view", "stock_doc:view"), false, true, false)));
        var pages = new VersionedSummaryPages(jdbc, authority, current, new ObjectMapper(), manager);
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        service = new FulfillmentWorkbenchQueryService(SharedEntityManagerCreator.createSharedEntityManager(factory),
                access, pages, new com.uten.imp.features.subcontract.kit.SubcontractKitService(jdbc, null));
    }

    private FulfillmentWorkbenchPage read(String department, String status, int page, boolean metadata) {
        return service.queryVersioned(department, status, "", "", null, null, page, 100, null,
                WarehouseTaskScope.ALL, metadata);
    }

    @Test void theDomainMarksEveryPageSourceThroughTheSharedTransactionGate() {
        assertThat(jdbc.queryForObject("SELECT count(*) FROM summary_read_domains WHERE domain='fulfillment-workbench'",
                Long.class)).isEqualTo(1);
        List<Map<String, Object>> triggers = jdbc.queryForList("""
                SELECT c.relname, count(*) AS events, count(*) FILTER (WHERE t.tgqual IS NOT NULL) AS gated
                FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                WHERE t.tgname LIKE 'trg\\_fulfillment\\_workbench\\_%'
                  AND t.tgfoid='public.fn_mark_summary_read_domain()'::regprocedure
                GROUP BY c.relname""");
        assertThat(triggers).hasSize(59).allSatisfy(row -> {
            assertThat(((Number) row.get("events")).intValue()).as(row.get("relname").toString()).isEqualTo(4);
            assertThat(((Number) row.get("gated")).intValue()).as(row.get("relname").toString()).isEqualTo(4);
        });
        assertThat(triggers).extracting(row -> row.get("relname")).contains(
                "purchase_orders", "purchase_request_items", "subcontract_orders", "subcontract_application_items",
                "procurement_order_approval_cases", "stock_documents", "stock_document_items",
                "production_material_demands", "production_execution_segments", "subcontract_short_delivery_cases");
    }

    @Test void everyPageAndTheRowsOnlyContinuationCarryOneStableProof() {
        for (String department : List.of("PURCHASE", "SUBCONTRACT", "WAREHOUSE")) {
            var first = read(department, "", 1, true);
            var again = read(department, "", 1, true);
            var continuation = read(department, "", 2, false);
            assertThat(first.readSnapshotRevision()).as(department).matches("[0-9a-f]{64}");
            assertThat(first.readDataVersion()).as(department).matches("[0-9a-f]{64}");
            assertThat(first.readScopeVersion()).as(department).isEqualTo("scope-a");
            assertThat(again.readSnapshotRevision()).isEqualTo(first.readSnapshotRevision());
            assertThat(continuation.readSnapshotRevision()).as(department).isEqualTo(first.readSnapshotRevision());
            assertThat(continuation.readDataVersion()).isEqualTo(first.readDataVersion());
            assertThat(continuation.metadataIncluded()).isFalse();
            assertThat(first.metadataIncluded()).isTrue();
            assertThat(first.total()).isZero();
            // A different row selection is a different query, never a shared token.
            assertThat(read(department, "COMPLETED", 1, true).readSnapshotRevision())
                    .as(department).isNotEqualTo(first.readSnapshotRevision());
        }
    }

    @Test void aCommittedWriteToAnyPageSourceMovesTheDataVersion() {
        var before = read("PURCHASE", "", 1, true);
        // Business writes reach this proof through their statement triggers
        // (shapes asserted above; fn_mark_summary_read_domain behaviour is the
        // V1103 contract). The committed marker is the same freshness fact,
        // insertable here without a full business document fixture.
        jdbc.update("INSERT INTO summary_read_markers(domain, transaction_id) "
                + "VALUES ('fulfillment-workbench', txid_current())");
        var after = read("PURCHASE", "", 1, true);
        assertThat(after.readDataVersion()).isNotEqualTo(before.readDataVersion());
        assertThat(after.readSnapshotRevision()).isNotEqualTo(before.readSnapshotRevision());
    }

    @Test void readScopeDriftInsideOneRequestIsRejectedNotPublished() {
        scope = "scope-a";
        var first = read("PURCHASE", "", 1, true);
        assertThat(first.readScopeVersion()).isEqualTo("scope-a");
        int baseline = scopeCalls.get();
        // The publication fence re-stamps after the read; a grant change between
        // the two stamps must fail the page rather than return rows.
        var authority = mock(ReadScopeVersionAuthority.class);
        var calls = new AtomicInteger();
        when(authority.scopeForCurrentSnapshot(anyString(), any()))
                .thenAnswer(call -> calls.incrementAndGet() == 1 ? "scope-a" : "scope-b");
        var current = mock(SecurityContextCurrentUser.class);
        UUID actor = UUID.randomUUID();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, actor, "workbench-fixture",
                Set.of("purchase_order:view"), false, true, false)));
        var drifting = new FulfillmentWorkbenchQueryService(SharedEntityManagerCreator.createSharedEntityManager(factory),
                mock(FulfillmentWorkbenchAccessPolicy.class),
                new VersionedSummaryPages(jdbc, authority, current, new ObjectMapper(), manager),
                new com.uten.imp.features.subcontract.kit.SubcontractKitService(jdbc, null));
        assertThatThrownBy(() -> drifting.queryVersioned("PURCHASE", "", "", "", null, null, 1, 100, null,
                WarehouseTaskScope.ALL, true))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));
        assertThat(scopeCalls.get()).isEqualTo(baseline);
    }
}
