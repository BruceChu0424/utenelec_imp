package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Array;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real responsibility data and helper invocation bounds; no elapsed-time allowance or permission cache. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseNoticeRecipientEvaluationPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static UUID root, warehouseA, warehouseB;
    private static Actor mainKeeper, manager, keeperA, keeperB, member, superAdmin;
    private static Actor disabledKeeper, resignedKeeper, deletedKeeper;
    private static final List<UUID> bulkPool = new ArrayList<>();
    private static String attributesBefore, attributesAfter, customBefore, customAfter;
    private static String driftedDefinitionBefore, driftedDefinitionAfter, driftedAttributesBefore, driftedAttributesAfter;
    private static SQLException driftedRefusal;

    private record Actor(UUID employee, UUID user) {}

    @BeforeAll
    static void prepare() throws Exception {
        PG.start();
        TestFlyway.configure().dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())
                .locations("classpath:db/migration").target("891").load().migrate();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        String migration = new ClassPathResource("db/migration/V892__warehouse_notice_recipient_single_evaluation.sql")
                .getContentAsString(StandardCharsets.UTF_8);
        try (Connection connection = connection()) {
            attributesBefore = attributes(connection);
            // Probe a configured predecessor inside a rollback-only private transaction.
            // The actual Flyway upgrade below still starts from the untouched V891 function.
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("CREATE ROLE warehouse_notice_owner_probe NOLOGIN");
                statement.execute("CREATE ROLE warehouse_notice_reader_probe NOLOGIN");
                statement.execute("ALTER FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) OWNER TO warehouse_notice_owner_probe");
                statement.execute("GRANT EXECUTE ON FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) TO warehouse_notice_reader_probe");
                statement.execute("ALTER FUNCTION public.fn_warehouse_notice_recipients(uuid[],uuid[]) SECURITY DEFINER STRICT PARALLEL RESTRICTED COST 17 SET search_path TO public,pg_temp");
                statement.execute(definition(connection).replace("WITH pool AS (", "\r\n\tWITH   pool AS (\r\n"));
                customBefore = attributes(connection);
                statement.execute(migration);
                customAfter = attributes(connection);
            } finally {
                connection.rollback();
                connection.setAutoCommit(true);
            }
        }
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                String predecessor = definition(connection);
                String drifted = predecessor.replace("ELSE ARRAY(SELECT id FROM pool ORDER BY id)",
                        "ELSE ARRAY(SELECT id FROM pool WHERE id IS NOT NULL ORDER BY id)");
                assertNotEquals(predecessor, drifted, "The negative probe must add an actual fallback restriction");
                statement.execute(drifted);
                driftedDefinitionBefore = definition(connection);
                driftedAttributesBefore = attributes(connection);
                Savepoint beforeUpgrade = connection.setSavepoint("before_guarded_upgrade");
                try {
                    statement.execute(migration);
                } catch (SQLException refused) {
                    driftedRefusal = refused;
                    connection.rollback(beforeUpgrade);
                }
                driftedDefinitionAfter = definition(connection);
                driftedAttributesAfter = attributes(connection);
            } finally {
                connection.rollback();
                connection.setAutoCommit(true);
            }
        }
        TestFlyway.configure().dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())
                .locations("classpath:db/migration").load().migrate();
        try (Connection connection = connection()) { attributesAfter = attributes(connection); }
        assertEquals(1, db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='892' AND success", Integer.class));
        UUID ordinary = department("NOTICE-ORDINARY");
        UUID warehouseDepartment = db.queryForList("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted", UUID.class)
                .stream().findFirst().orElseGet(() -> department("SUB_WH"));
        root = db.queryForObject("SELECT fn_warehouse_root_id()", UUID.class);
        if (root == null) root = warehouse("001", null);
        warehouseA = warehouse("NOTICE-A", root);
        warehouseB = warehouse("NOTICE-B", root);
        mainKeeper = actor("main", ordinary, false);
        manager = actor("manager", warehouseDepartment, false);
        keeperA = actor("keeper-a", ordinary, false);
        keeperB = actor("keeper-b", ordinary, false);
        member = actor("member", ordinary, false);
        superAdmin = actor("super-only", ordinary, true);
        disabledKeeper = actor("disabled", ordinary, false);
        resignedKeeper = actor("resigned", ordinary, false);
        deletedKeeper = actor("deleted", ordinary, false);
        db.update("UPDATE departments SET manager_id=? WHERE id=?", manager.employee(), warehouseDepartment);
        for (Actor keeper : List.of(keeperA, disabledKeeper, resignedKeeper, deletedKeeper))
            db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)", warehouseA, keeper.employee());
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)", root, mainKeeper.employee());
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)", warehouseB, keeperB.employee());
        db.update("UPDATE users SET status='disabled' WHERE id=?", disabledKeeper.user());
        db.update("UPDATE employees SET status='resigned' WHERE id=?", resignedKeeper.employee());
        db.update("UPDATE employees SET is_deleted=true WHERE id=?", deletedKeeper.employee());
        for (int i = 0; i < 128; i++) bulkPool.add(actor("bulk-" + i, ordinary, false).user());
    }

    @AfterAll
    static void close() { PG.stop(); }

    @Test
    void upgradePreservesDefaultAndConfiguredFunctionIdentityGrantsAndExecutionAttributes() {
        assertEquals(attributesBefore, attributesAfter);
        assertNotEquals(attributesBefore, customBefore, "The configured predecessor must exercise non-default attributes");
        assertEquals(customBefore, customAfter,
                "owner, ACL, security, strictness, search_path, volatility, parallel safety and cost must survive");
    }

    @Test
    void upgradeRefusesUnknownFallbackEvenWhenBothOriginalHelperMarkersRemain() {
        assertTrue(driftedDefinitionBefore.contains("pool.id = ANY(fn_warehouse_keeper_user_ids("));
        assertTrue(driftedDefinitionBefore.contains("pool.id = ANY(fn_warehouse_designated_supervisor_user_ids())"));
        assertNotNull(driftedRefusal, "An unknown extra fallback rule must not be silently overwritten");
        assertEquals("P0001", driftedRefusal.getSQLState());
        assertTrue(driftedRefusal.getMessage().contains("not the canonical V804 body"));
        assertEquals(driftedDefinitionBefore, driftedDefinitionAfter, "The refused upgrade must retain the entire existing function");
        assertEquals(driftedAttributesBefore, driftedAttributesAfter);
    }

    @Test
    void eligibleKeeperWinsWithoutEscapingTheSuppliedPermissionPool() throws Exception {
        assertEquals(List.of(keeperA.user()), recipients(List.of(warehouseA),
                List.of(member.user(), manager.user(), mainKeeper.user(), keeperA.user(), keeperA.user())));
        assertEquals(sorted(mainKeeper.user(), manager.user()), recipients(List.of(warehouseA),
                List.of(member.user(), manager.user(), mainKeeper.user(), keeperB.user())));
        assertEquals(List.of(keeperB.user()), recipients(List.of(warehouseB),
                List.of(member.user(), keeperA.user(), keeperB.user(), manager.user())));
        assertEquals(sorted(member.user(), superAdmin.user()), recipients(List.of(warehouseB),
                List.of(superAdmin.user(), member.user())), "An unrelated super-admin is not a designated supervisor");
    }

    @Test
    void inactiveResignedOrDeletedKeepersDoNotDisplaceTheEligibleSupervisor() throws Exception {
        assertEquals(List.of(manager.user()), recipients(List.of(warehouseA),
                List.of(disabledKeeper.user(), resignedKeeper.user(), deletedKeeper.user(), manager.user())));
    }

    @Test
    void unresolvedWarehousesAndNullEmptyDuplicateInputsKeepTheOriginalFallbackContract() throws Exception {
        List<UUID> pool = List.of(member.user(), manager.user(), mainKeeper.user());
        for (List<UUID> warehouses : Arrays.asList(null, List.<UUID>of(), List.of(UUID.randomUUID())))
            assertEquals(sorted(manager.user(), mainKeeper.user()), recipients(warehouses, pool));
        assertEquals(List.of(), recipients(List.of(warehouseA), null));
        assertEquals(List.of(), recipients(List.of(warehouseA), List.of()));
        assertEquals(List.of(keeperA.user()), recipients(Arrays.asList(null, warehouseA, warehouseA),
                Arrays.asList(null, keeperA.user(), keeperA.user(), manager.user())));
        assertEquals(Arrays.asList(member.user(), null), recipients(List.of(warehouseB),
                Arrays.asList(null, member.user(), member.user())), "The raw function retains the caller's null pool member in fallback");
    }

    @ParameterizedTest
    @ValueSource(ints = {1, 8, 128})
    void helperEvaluationsStayBoundedAsThePermissionPoolGrows(int size) throws Exception {
        List<UUID> pool = bulkPool.subList(0, size);
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("SET track_functions='all'");
            statement.execute("SELECT pg_stat_force_next_flush()");
            statement.execute("SELECT pg_stat_reset()");
            List<UUID> actual = new ArrayList<>();
            // Same CSV/unnest call shape as WarehouseDataScopeService, including custom-plan evaluation.
            try (PreparedStatement query = connection.prepareStatement("""
                    SELECT unnest(fn_warehouse_notice_recipients(
                        CAST(string_to_array(NULLIF(?, ''), ',') AS uuid[]),
                        CAST(string_to_array(?, ',') AS uuid[])))
                    """)) {
                query.setString(1, warehouseB.toString());
                query.setString(2, String.join(",", pool.stream().map(UUID::toString).toList()));
                try (ResultSet rows = query.executeQuery()) { while (rows.next()) actual.add(rows.getObject(1, UUID.class)); }
            }
            assertEquals(sorted(pool.toArray(UUID[]::new)), actual);
            statement.execute("SELECT pg_stat_force_next_flush()");
        }
        Map<String, Long> calls = db.query("""
                SELECT funcname,calls FROM pg_stat_user_functions
                WHERE funcname IN ('fn_warehouse_keeper_user_ids','fn_warehouse_designated_supervisor_user_ids')
                """, rows -> {
            Map<String, Long> counts = new java.util.HashMap<>();
            while (rows.next()) counts.put(rows.getString(1), rows.getLong(2));
            return counts;
        });
        for (String function : List.of("fn_warehouse_keeper_user_ids", "fn_warehouse_designated_supervisor_user_ids")) {
            long count = calls.getOrDefault(function, 0L);
            assertTrue(count >= 1 && count <= 2, function + " must run at most once per UDF evaluation, not per pool row: " + calls);
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
    }

    private static String attributes(Connection connection) throws Exception {
        try (Statement query = connection.createStatement(); ResultSet rows = query.executeQuery("""
                SELECT (to_jsonb(p)-'prosrc'-'prosqlbody')::text FROM pg_proc p
                WHERE p.oid='public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure
                """)) { assertTrue(rows.next()); return rows.getString(1); }
    }

    private static String definition(Connection connection) throws Exception {
        try (Statement query = connection.createStatement(); ResultSet rows = query.executeQuery(
                "SELECT pg_get_functiondef('public.fn_warehouse_notice_recipients(uuid[],uuid[])'::regprocedure)")) {
            assertTrue(rows.next());
            return rows.getString(1);
        }
    }

    private static List<UUID> recipients(List<UUID> warehouses, List<UUID> pool) throws Exception {
        try (Connection connection = connection(); PreparedStatement query = connection.prepareStatement(
                "SELECT unnest(fn_warehouse_notice_recipients(CAST(? AS uuid[]),CAST(? AS uuid[])))")) {
            Array warehouseArray = warehouses == null ? null : connection.createArrayOf("uuid", warehouses.toArray());
            Array poolArray = pool == null ? null : connection.createArrayOf("uuid", pool.toArray());
            try {
                if (warehouseArray == null) query.setNull(1, Types.ARRAY); else query.setArray(1, warehouseArray);
                if (poolArray == null) query.setNull(2, Types.ARRAY); else query.setArray(2, poolArray);
                List<UUID> result = new ArrayList<>();
                try (ResultSet rows = query.executeQuery()) { while (rows.next()) result.add(rows.getObject(1, UUID.class)); }
                return result;
            } finally {
                if (warehouseArray != null) warehouseArray.free();
                if (poolArray != null) poolArray.free();
            }
        }
    }

    private static List<UUID> sorted(UUID... ids) {
        return Arrays.stream(ids).sorted(Comparator.comparing(UUID::toString)).toList();
    }

    private static UUID department(String code) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')", id, code, code);
        return id;
    }

    private static UUID warehouse(String code, UUID parent) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,parent_id) VALUES(?,?,?,'使用',true,?)", id, code, code, parent);
        return id;
    }

    private static Actor actor(String tag, UUID department, boolean superAdmin) {
        Actor actor = new Actor(UUID.randomUUID(), UUID.randomUUID());
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",
                actor.employee(), "N-" + tag, "Notice " + tag, department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'synthetic-notice-test',false,?,'active')",
                actor.user(), actor.employee(), "notice-" + tag, superAdmin);
        return actor;
    }
}
