package com.uten.imp.features.master.goods;

import org.junit.jupiter.api.*;
import jakarta.persistence.EntityManagerFactory;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.*;

/** Real V498 DDL/DML, rollback and concurrent first-use against PostgreSQL. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsQuantityUnitLifecyclePostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID PIECE = UUID.randomUUID(), BOX = UUID.randomUUID();
    private static final UUID HISTORICAL = UUID.randomUUID(), LEGACY = UUID.randomUUID();
    private static final UUID BOM_PARENT = UUID.randomUUID(), BOM_CHILD = UUID.randomUUID();
    private static final UUID UNUSED_LEGACY = UUID.randomUUID(), METADATA_ONLY = UUID.randomUUID();
    private static DriverManagerDataSource ds;
    private static JdbcTemplate jdbc;
    private static EntityManagerFactory emf;
    private static final List<Source> SOURCES = new ArrayList<>();
    private record Source(String table, List<String> columns, String predicate) {}

    @BeforeAll static void setup() throws Exception {
        DB.start();
        ds = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(ds);
        jdbc.execute("CREATE TABLE units(id uuid PRIMARY KEY, name text, is_deleted boolean DEFAULT false, status text DEFAULT '使用')");
        jdbc.update("INSERT INTO units(id,name) VALUES (?, '个'), (?, '箱')", PIECE, BOX);
        jdbc.execute("CREATE TABLE goods(id uuid PRIMARY KEY, unit_id uuid REFERENCES units(id), unit_legacy_id integer, name text, is_deleted boolean DEFAULT false, owner_employee_id uuid, status text DEFAULT '使用', auto_created boolean DEFAULT false)");
        String sql;
        try (var in = Objects.requireNonNull(GoodsQuantityUnitLifecyclePostgresTest.class.getResourceAsStream(
                "/db/migration/V498__goods_quantity_unit_lifecycle_guard.sql"))) {
            sql = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
        var matcher = Pattern.compile("\\('([a-z_]+)', ARRAY\\[([^]]+)\\], '([^']+)'\\)").matcher(sql);
        while (matcher.find()) {
            var source = new Source(matcher.group(1), Arrays.asList(matcher.group(2).replace("'", "").split(",")), matcher.group(3));
            SOURCES.add(source);
            jdbc.execute("CREATE TABLE " + source.table() + "(id uuid PRIMARY KEY DEFAULT gen_random_uuid(), "
                    + source.columns().stream().map(c -> c + " uuid REFERENCES goods(id)").reduce((a,b) -> a + "," + b).orElseThrow()
                    + ", qty numeric DEFAULT 0, unit_id uuid, unit_rate numeric DEFAULT 1, is_deleted boolean DEFAULT false, distinct_document_count bigint DEFAULT 0)");
        }
        assertThat(SOURCES).hasSize(52);
        jdbc.execute("CREATE TABLE warehouse_goods_place_preferences(goods_id uuid REFERENCES goods(id), place text)");
        jdbc.execute("CREATE TABLE goods_image_references(goods_id uuid REFERENCES goods(id), image_path text)");
        for (UUID id : List.of(HISTORICAL, BOM_PARENT, BOM_CHILD, METADATA_ONLY)) {
            jdbc.update("INSERT INTO goods(id,unit_id,unit_legacy_id,name) VALUES (?, ?, 12, '保留原资料')", id, PIECE);
        }
        for (UUID id : List.of(LEGACY, UNUSED_LEGACY)) {
            jdbc.update("INSERT INTO goods(id,unit_id,unit_legacy_id,name) VALUES (?, NULL, 12, '历史未解单位')", id);
        }
        jdbc.update("INSERT INTO stock_balances(goods_id,qty) VALUES (?,0)", HISTORICAL);
        jdbc.update("INSERT INTO sales_order_items(goods_id,qty,is_deleted) VALUES (?,24,true)", LEGACY);
        jdbc.update("INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES (?,?,2)", BOM_PARENT, BOM_CHILD);
        jdbc.update("INSERT INTO warehouse_goods_place_preferences VALUES (?, 'A1')", METADATA_ONLY);
        jdbc.update("INSERT INTO goods_image_references VALUES (?, 'photo.png')", METADATA_ONLY);
        jdbc.execute(sql);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(ds);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        factory.setJpaProperties(properties); factory.afterPropertiesSet();
        emf = factory.getObject();
    }

    @AfterAll static void close() { if (emf != null) emf.close(); DB.stop(); }

    @Test void forwardBackfillIncludesZeroBalancesDeletedHistoryAndBothBomEnds() {
        for (UUID id : List.of(HISTORICAL, LEGACY, BOM_PARENT, BOM_CHILD)) assertThat(locked(id)).isTrue();
        assertThat(locked(UNUSED_LEGACY)).isFalse();
        assertThat(locked(METADATA_ONLY)).isFalse();
        assertThat(jdbc.queryForObject("SELECT qty FROM sales_order_items WHERE goods_id=?", java.math.BigDecimal.class, LEGACY))
                .isEqualByComparingTo("24");
        assertThat(jdbc.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=?", java.math.BigDecimal.class, BOM_PARENT))
                .isEqualByComparingTo("2");
    }

    @Test void everyQuantitySourceLocksAllDeclaredGoodsColumns() {
        for (Source source : SOURCES) {
            List<UUID> ids = new ArrayList<>();
            for (String ignored : source.columns()) ids.add(goods(PIECE));
            jdbc.update("INSERT INTO " + source.table() + "(" + String.join(",", source.columns())
                    + ",distinct_document_count) VALUES (" + String.join(",", Collections.nCopies(ids.size(), "?")) + ",1)", ids.toArray());
            for (UUID id : ids) {
                assertThat(locked(id)).as(source.table()).isTrue();
                assertBlocked(id, BOX);
            }
        }
    }

    @Test void unusedAndMetadataOnlyGoodsCanChangeWhileUsedSameUnitMetadataEditsWork() {
        UUID unused = goods(PIECE);
        jdbc.update("UPDATE goods SET unit_id=? WHERE id=?", BOX, unused);
        jdbc.update("UPDATE goods SET unit_id=? WHERE id=?", BOX, METADATA_ONLY);
        jdbc.update("UPDATE goods SET unit_id=? WHERE id=?", PIECE, UNUSED_LEGACY);
        jdbc.update("UPDATE goods SET name='只改备注名称', unit_id=? WHERE id=?", PIECE, HISTORICAL);
        assertThat(unit(unused)).isEqualTo(BOX);
        assertThat(unit(METADATA_ONLY)).isEqualTo(BOX);
        assertThat(unit(UNUSED_LEGACY)).isEqualTo(PIECE);
        assertThat(unit(HISTORICAL)).isEqualTo(PIECE);
        assertThat(locked(HISTORICAL)).isTrue();
    }

    @Test void lockedLegacyNullUnitCannotBeGuessedOrItsLegacyLabelErased() {
        assertBlocked(LEGACY, BOX);
        assertThatThrownBy(() -> jdbc.update("UPDATE goods SET unit_legacy_id=NULL WHERE id=?", LEGACY))
                .hasMessageContaining("历史基本单位尚未核对");
        jdbc.update("UPDATE goods SET name='核对中' WHERE id=?", LEGACY);
        assertThat(unit(LEGACY)).isNull();
        assertThat(jdbc.queryForObject("SELECT unit_legacy_id FROM goods WHERE id=?", Integer.class, LEGACY)).isEqualTo(12);
    }

    @Test void deletingOrReassigningReferencesCannotUnlockTheOriginalGoods() {
        UUID first = goods(PIECE), next = goods(PIECE);
        jdbc.update("INSERT INTO purchase_order_items(goods_id,qty) VALUES (?,24)", first);
        jdbc.update("UPDATE purchase_order_items SET goods_id=? WHERE goods_id=?", next, first);
        jdbc.update("DELETE FROM purchase_order_items WHERE goods_id=?", next);
        assertBlocked(first, BOX);
        assertBlocked(next, BOX);
        assertThatThrownBy(() -> jdbc.update("UPDATE goods SET quantity_unit_locked=false WHERE id=?", first))
                .hasMessageContaining("基本单位不能再改");
    }

    @Test void rolledBackFirstUseDoesNotLeaveAFalsePermanentLock() throws Exception {
        UUID id = goods(PIECE);
        try (Connection connection = ds.getConnection()) {
            connection.setAutoCommit(false);
            execute(connection, "INSERT INTO sales_order_items(goods_id,qty) VALUES (?,24)", id);
            connection.rollback();
        }
        assertThat(locked(id)).isFalse();
        jdbc.update("UPDATE goods SET unit_id=? WHERE id=?", BOX, id);
        assertThat(unit(id)).isEqualTo(BOX);
    }

    @Test void concurrentFirstReferenceWinsAndTheWaitingUnitChangeIsRejected() throws Exception {
        UUID id = goods(PIECE);
        var executor = Executors.newSingleThreadExecutor();
        try (Connection first = ds.getConnection()) {
            first.setAutoCommit(false);
            execute(first, "INSERT INTO sales_order_items(goods_id,qty) VALUES (?,24)", id);
            AtomicInteger waiter = new AtomicInteger();
            Future<String> change = executor.submit(() -> {
                try (Connection second = ds.getConnection()) {
                    waiter.set(pid(second));
                    execute(second, "UPDATE goods SET unit_id=? WHERE id=?", BOX, id);
                    return "unexpected success";
                } catch (SQLException ex) { return ex.getSQLState(); }
            });
            waitForDatabaseLock(waiter);
            first.commit();
            assertThat(change.get(10, TimeUnit.SECONDS)).isEqualTo("23514");
        } finally { executor.shutdownNow(); }
        assertThat(unit(id)).isEqualTo(PIECE);
        assertThat(locked(id)).isTrue();
    }

    @Test void unitChangeBeforeFirstUseCommitsThenTheNewBasisBecomesLocked() throws Exception {
        UUID id = goods(PIECE);
        var executor = Executors.newSingleThreadExecutor();
        try (Connection first = ds.getConnection()) {
            first.setAutoCommit(false);
            execute(first, "UPDATE goods SET unit_id=? WHERE id=?", BOX, id);
            AtomicInteger waiter = new AtomicInteger();
            Future<?> insert = executor.submit(() -> {
                try (Connection second = ds.getConnection()) {
                    waiter.set(pid(second));
                    execute(second, "INSERT INTO sales_order_items(goods_id,qty) VALUES (?,24)", id);
                } catch (SQLException ex) { throw new IllegalStateException(ex); }
            });
            waitForDatabaseLock(waiter);
            first.commit();
            insert.get(10, TimeUnit.SECONDS);
        } finally { executor.shutdownNow(); }
        assertThat(unit(id)).isEqualTo(BOX);
        assertThat(locked(id)).isTrue();
        assertBlocked(id, PIECE);
    }

    @Test void normalizationFirstKeepsItsBasisUntilItsQuantitySourceCommits() throws Exception {
        UUID id = goods(PIECE);
        var first = emf.createEntityManager();
        var executor = Executors.newSingleThreadExecutor();
        try {
            first.getTransaction().begin();
            var normalized = new PurchaseLineUnitPolicy(first).normalizeAndValidate(id, null, java.math.BigDecimal.ONE, 1);
            assertThat(normalized.unitId()).isEqualTo(PIECE);
            AtomicInteger waiter = new AtomicInteger();
            Future<String> change = executor.submit(() -> {
                try (Connection second = ds.getConnection()) {
                    waiter.set(pid(second));
                    execute(second, "UPDATE goods SET unit_id=? WHERE id=?", BOX, id);
                    return "unexpected success";
                } catch (SQLException ex) { return ex.getSQLState(); }
            });
            waitForDatabaseLock(waiter);
            first.createNativeQuery("INSERT INTO purchase_request_items(goods_id,unit_id,unit_rate,qty) VALUES (:goods,:unit,:rate,24)")
                    .setParameter("goods", id).setParameter("unit", normalized.unitId()).setParameter("rate", normalized.unitRate()).executeUpdate();
            first.getTransaction().commit();
            assertThat(change.get(10, TimeUnit.SECONDS)).isEqualTo("23514");
            assertThat(unit(id)).isEqualTo(PIECE);
            assertThat(jdbc.queryForObject("SELECT qty*unit_rate FROM purchase_request_items WHERE goods_id=?", java.math.BigDecimal.class, id))
                    .isEqualByComparingTo("24");
        } finally {
            if (first.getTransaction().isActive()) first.getTransaction().rollback();
            first.close(); executor.shutdownNow();
        }
    }

    @Test void editFirstMakesRealNormalizerWaitThenUseNewBasisBeforeComputingOrWriting() throws Exception {
        UUID id = goods(PIECE);
        assertThat(unit(id)).isEqualTo(PIECE);
        var executor = Executors.newSingleThreadExecutor();
        try (Connection editor = ds.getConnection()) {
            editor.setAutoCommit(false);
            execute(editor, "UPDATE goods SET unit_id=? WHERE id=?", BOX, id);
            AtomicInteger waiter = new AtomicInteger();
            Future<UUID> creation = executor.submit(() -> {
                var em = emf.createEntityManager();
                try {
                    em.getTransaction().begin();
                    waiter.set(((Number) em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
                    var normalized = new PurchaseLineUnitPolicy(em).normalizeAndValidate(id, null, java.math.BigDecimal.ONE, 1);
                    em.createNativeQuery("INSERT INTO purchase_request_items(goods_id,unit_id,unit_rate,qty) VALUES (:goods,:unit,:rate,24)")
                            .setParameter("goods", id).setParameter("unit", normalized.unitId()).setParameter("rate", normalized.unitRate()).executeUpdate();
                    em.getTransaction().commit();
                    return normalized.unitId();
                } finally {
                    if (em.getTransaction().isActive()) em.getTransaction().rollback();
                    em.close();
                }
            });
            waitForDatabaseLock(waiter);
            editor.commit();
            assertThat(creation.get(10, TimeUnit.SECONDS)).isEqualTo(BOX);
        } finally { executor.shutdownNow(); }
        assertThat(jdbc.queryForObject("SELECT unit_id FROM purchase_request_items WHERE goods_id=?", UUID.class, id)).isEqualTo(BOX);
        assertThat(jdbc.queryForObject("SELECT qty*unit_rate FROM purchase_request_items WHERE goods_id=?", java.math.BigDecimal.class, id))
                .isEqualByComparingTo("24");
        assertThat(locked(id)).isTrue();
    }

    private static UUID goods(UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,unit_id,name) VALUES (?,?,'新品')", id, unit);
        return id;
    }
    private static UUID unit(UUID id) { return jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?", UUID.class, id); }
    private static boolean locked(UUID id) { return Boolean.TRUE.equals(jdbc.queryForObject("SELECT quantity_unit_locked FROM goods WHERE id=?", Boolean.class, id)); }
    private static void assertBlocked(UUID id, UUID unit) {
        assertThatThrownBy(() -> jdbc.update("UPDATE goods SET unit_id=? WHERE id=?", unit, id))
                .hasMessageContaining("基本单位");
    }
    private static void execute(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) statement.setObject(index + 1, args[index]);
            statement.executeUpdate();
        }
    }
    private static int pid(Connection connection) throws SQLException {
        try (var statement = connection.createStatement(); var result = statement.executeQuery("SELECT pg_backend_pid()")) {
            result.next(); return result.getInt(1);
        }
    }
    private static void waitForDatabaseLock(AtomicInteger waiter) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(10).toNanos();
        while (System.nanoTime() < deadline) {
            if (waiter.get() > 0 && Boolean.TRUE.equals(jdbc.queryForObject(
                    "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')", Boolean.class, waiter.get()))) return;
            Thread.sleep(20);
        }
        fail("The competing transaction did not reach a real PostgreSQL lock wait");
    }
}
