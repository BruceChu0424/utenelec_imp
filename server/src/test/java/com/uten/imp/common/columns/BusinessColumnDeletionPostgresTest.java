package com.uten.imp.common.columns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;

/** Real migrated PostgreSQL with Spring JPA transactions; no substitute catalog schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessColumnDeletionPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static TransactionTemplate transactions;
    private static JdbcTemplate sql;
    private static BusinessColumnService service;

    @BeforeAll static void start() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("business_column_delete");
        var ds = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        sql = new JdbcTemplate(ds);
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(ds);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.sales.order");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        bean.setJpaProperties(properties);
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        transactions = new TransactionTemplate(new JpaTransactionManager(factory));
        service = new BusinessColumnService(em, new SecurityContextCurrentUser(), new ObjectMapper());
    }

    @AfterAll static void stop() throws Exception {
        if (factory != null) factory.close();
        if (database != null) database.close();
    }
    @AfterEach void clearUser() { SecurityContextHolder.clearContext(); }

    @Test void catalogRemovalPreservesApprovedDocumentTermsAndResolvesCopiedOrExistingReferences() throws Exception {
        UUID creator = UUID.randomUUID();
        login(creator, false);
        var column = tx(() -> service.create(new BusinessColumnService.Create("sales_order", uniqueName(), "AMOUNT", "ADD")));
        var snapshot = new ExtraColumnSnapshot(column.id(), column.name(), column.type(), column.operation(), "5");
        UUID order = UUID.randomUUID(), item = UUID.randomUUID();
        String saved = new ObjectMapper().writeValueAsString(List.of(snapshot));
        try (Connection seed = database.openConnection()) {
            var jdbc = new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(seed, true));
            jdbc.execute("SET session_replication_role=replica");
            try {
                jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status) VALUES(?, ?, CURRENT_DATE, ?,1)",
                        order, "COL-DELETE-" + order, UUID.randomUUID());
                jdbc.update("""
                        INSERT INTO sales_order_items(id,bill_no,bill_date,order_id,goods_id,line_no,qty,price,
                            amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,extra_columns)
                        VALUES(?,?,CURRENT_DATE,?,?,1,3,10,35,35,'COL','历史货品','MASTER_AT_SAVE',?::jsonb)
                        """, item, "COL-DELETE-" + order, order, UUID.randomUUID(), saved);
            } finally { jdbc.execute("SET session_replication_role=origin"); }
        }
        String before = sql.queryForObject("SELECT extra_columns::text FROM sales_order_items WHERE id=?", String.class, item);
        tx(() -> { service.delete("sales_order", column.id()); service.delete("sales_order", column.id()); return null; });
        assertThat(service.search("sales_order", column.name())).extracting(BusinessColumnService.Definition::id)
                .doesNotContain(column.id());
        assertThat(sql.queryForObject("SELECT extra_columns::text FROM sales_order_items WHERE id=?", String.class, item)).isEqualTo(before);
        assertThat(sql.queryForObject("SELECT amount_original FROM sales_order_items WHERE id=?", java.math.BigDecimal.class, item))
                .isEqualByComparingTo("35");
        assertThat(sql.queryForObject("SELECT count(*) FROM business_column_deletions WHERE column_id=?", Integer.class, column.id())).isEqualTo(1);
        assertThat(sql.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='business_column_deletions' AND after->>'column_id'=?",
                Integer.class, column.id().toString())).isEqualTo(1);
        var requested = List.of(new ExtraColumnInput(column.id(), "7"));
        assertThat(tx(() -> service.resolve("sales_order", requested, List.of(snapshot), false)).getFirst().value()).isEqualTo("7");
        assertThat(tx(() -> service.resolve("sales_order", requested, List.of(), false)).getFirst().columnId()).isEqualTo(column.id());
    }

    @Test void onlyCreatorCanRemoveAndRestoreAndScopesAndCurrentPermissionsRemainAuthoritative() {
        UUID creator = UUID.randomUUID();
        login(creator, false);
        for (String scope : List.of("sales_quote", "sales_order", "purchase_order", "subcontract_order")) {
            var input = new BusinessColumnService.Create(scope, uniqueName(), "TEXT", "NONE");
            var column = tx(() -> service.create(input));
            assertThat(column.canDelete()).isTrue();
            login(UUID.randomUUID(), true);
            assertThat(service.search(scope, column.name())).allSatisfy(d -> assertThat(d.canDelete()).isFalse());
            assertThatThrownBy(() -> tx(() -> { service.delete(scope, column.id()); return null; }))
                    .isInstanceOf(ApiException.class).hasMessageContaining("自己创建");
            login(creator, false);
            tx(() -> { service.delete(scope, column.id()); return null; });
            login(UUID.randomUUID(), true);
            assertThatThrownBy(() -> tx(() -> service.create(input))).isInstanceOf(ApiException.class)
                    .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.CONFLICT));
            login(creator, false);
            assertThat(tx(() -> service.create(input)).id()).isEqualTo(column.id());
        }
        var column = tx(() -> service.create(new BusinessColumnService.Create("sales_order", uniqueName(), "TEXT", "NONE")));
        assertThatThrownBy(() -> tx(() -> { service.delete("purchase_order", column.id()); return null; }))
                .isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        login(creator, Set.of("sales_order:view"), false);
        assertThatThrownBy(() -> tx(() -> { service.delete("sales_order", column.id()); return null; }))
                .isInstanceOf(ApiException.class).hasMessageContaining("编辑");
    }

    @Test void sameCreatorWaitingForDeletionSeesCommittedTombstoneAndRestoresIdentity() throws Exception {
        waitingCreate(true);
    }
    @Test void otherCreatorWaitingForDeletionSeesCommittedTombstoneAndCannotRestoreIt() throws Exception {
        waitingCreate(false);
    }

    private void waitingCreate(boolean sameCreator) throws Exception {
        UUID creator = UUID.randomUUID(), worker = sameCreator ? creator : UUID.randomUUID();
        login(creator, false);
        var input = new BusinessColumnService.Create("sales_order", uniqueName(), "TEXT", "NONE");
        var original = tx(() -> service.create(input));
        try (Connection blocker = database.openConnection(); var executor = Executors.newSingleThreadExecutor()) {
            blocker.setAutoCommit(false);
            var blockerSql = new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(blocker, true));
            blockerSql.queryForObject("SELECT id FROM business_column_definitions WHERE id=? FOR UPDATE", UUID.class, original.id());
            blockerSql.update("INSERT INTO business_column_deletions(column_id,deleted_by) VALUES(?,?)", original.id(), creator);
            AtomicInteger workerPid = new AtomicInteger();
            var pending = executor.submit(() -> {
                login(worker, false);
                try {
                    return tx(() -> {
                        workerPid.set(((Number) em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
                        return service.create(input);
                    });
                } finally { SecurityContextHolder.clearContext(); }
            });
            boolean waiting = false;
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            try {
                while (System.nanoTime() < deadline && !pending.isDone()) {
                    if (workerPid.get() != 0 && Boolean.TRUE.equals(sql.queryForObject(
                            "SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?", Boolean.class, workerPid.get()))) {
                        waiting = true;
                        break;
                    }
                    Thread.sleep(25);
                }
                assertThat(waiting).as("Identical create waits on the catalog identity while deletion is uncommitted").isTrue();
            } finally { blocker.commit(); }
            if (sameCreator) {
                assertThat(pending.get(10, TimeUnit.SECONDS).id()).isEqualTo(original.id());
                assertThat(sql.queryForObject("SELECT count(*) FROM business_column_deletions WHERE column_id=?", Integer.class, original.id())).isZero();
            } else {
                assertThatThrownBy(() -> pending.get(10, TimeUnit.SECONDS))
                        .hasCauseInstanceOf(ApiException.class)
                        .satisfies(e -> assertThat(((ApiException) e.getCause()).getCode()).isEqualTo(ErrorCode.CONFLICT));
                assertThat(sql.queryForObject("SELECT count(*) FROM business_column_deletions WHERE column_id=?", Integer.class, original.id())).isEqualTo(1);
            }
        }
    }

    private static <T> T tx(Supplier<T> work) { return transactions.execute(status -> work.get()); }
    private static String uniqueName() { return "可删除列" + UUID.randomUUID(); }
    private static void login(UUID actor, boolean administrator) {
        login(actor, Set.of("sales_quote:edit", "sales_order:edit", "purchase_order:edit", "subcontract_order:edit",
                "sales_order:price:view", "purchase_order:price:view", "subcontract_order:price:view"), administrator);
    }
    private static void login(UUID actor, Set<String> permissions, boolean administrator) {
        var user = new AuthUser(actor, UUID.randomUUID(), "column-delete-test", permissions, false, true, administrator);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
