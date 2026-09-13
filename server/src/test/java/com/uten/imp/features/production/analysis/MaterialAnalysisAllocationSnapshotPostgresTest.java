package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.postgresql.PGStatement;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/**
 * Executes the allocation writer's actual captured SQL against its relevant
 * indexes. Statistics describe an old analysis; 49k new nodes are then inserted
 * in the still-open refresh transaction. This deliberately isolates access-plan
 * admission from the full business-chain tests and does not replace them.
 */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisAllocationSnapshotPostgresTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static DriverManagerDataSource dataSource;
    private static final UUID ACTOR = id("actor");
    private static final BigDecimal ZERO = BigDecimal.ZERO;
    private static final LocalDate DATE = LocalDate.of(2026, 9, 12);
    private static final String TABLE = "production_material_analysis_materials";

    @BeforeAll
    static void fixture() {
        dataSource = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("""
                CREATE TABLE production_material_analysis_materials(
                  id uuid PRIMARY KEY,analysis_id uuid NOT NULL,analysis_item_id uuid NOT NULL,node_key varchar NOT NULL,
                  goods_id uuid,color_id uuid,unit_id uuid,parent_node_key varchar,depth integer,
                  confirmed_route varchar,route_confirmed_at timestamptz,created_at timestamptz DEFAULT now(),
                  active boolean NOT NULL DEFAULT TRUE,
                  required_qty numeric NOT NULL DEFAULT 0,allocated_available_qty numeric NOT NULL DEFAULT 0,
                  allocated_start_qty numeric NOT NULL DEFAULT 0,allocated_finish_qty numeric NOT NULL DEFAULT 0,
                  allocated_ship_qty numeric NOT NULL DEFAULT 0,shortage_qty numeric NOT NULL DEFAULT 0,
                  lower_level_pending boolean NOT NULL DEFAULT FALSE,available_qty numeric NOT NULL DEFAULT 0,
                  reserved_qty numeric NOT NULL DEFAULT 0,safety_stock_qty numeric NOT NULL DEFAULT 0,
                  inbound_qty numeric NOT NULL DEFAULT 0,expected_ready_date date,updated_at timestamptz,updated_by uuid,
                  UNIQUE(analysis_id,id),UNIQUE(analysis_item_id,node_key))
                """);
        for (String definition : List.of(
                "route_history ON " + TABLE + "(goods_id,color_id,unit_id,route_confirmed_at DESC,id) WHERE confirmed_route IS NOT NULL",
                "active_tree ON " + TABLE + "(analysis_item_id,parent_node_key,depth) WHERE active=TRUE",
                "active_dimension ON " + TABLE + "(analysis_id,goods_id,color_id,unit_id,expected_ready_date) WHERE active=TRUE",
                "last_route ON " + TABLE + "(goods_id,color_id,unit_id,route_confirmed_at DESC,created_at DESC,id DESC) WHERE confirmed_route IS NOT NULL AND active")) {
            jdbc.execute("CREATE INDEX " + definition);
        }
        jdbc.update(seedSql(), "old", id("old"), "old", 10000);
        jdbc.execute("ANALYZE " + TABLE);
    }

    @ParameterizedTest
    @CsvSource({"100,force_custom_plan", "100,force_generic_plan", "100,auto",
            "500,force_custom_plan", "500,force_generic_plan", "500,auto"})
    void newAnalysisKeepsExactSnapshotAndPreparedPlanAdmission(int count, String mode) throws Exception {
        Captured captured = capture(id("new"), "new", count);
        assertEquals(2, captured.values().length, "All row identities and exact quantities use one typed JSON parameter plus the actor");
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (var config = connection.createStatement()) {
                config.execute("SET LOCAL jit=off");
                config.execute("SET LOCAL statement_timeout='10s'");
                config.execute("SET LOCAL plan_cache_mode=" + mode);
            }
            seed(connection, "new", 49000);
            try (PreparedStatement statement = connection.prepareStatement(captured.sql())) {
                statement.unwrap(PGStatement.class).setPrepareThreshold(1);
                bind(statement, captured.values());
                assertEquals(count, statement.executeUpdate());
                for (int run = 1; run < 6; run++) assertEquals(0, statement.executeUpdate(), "Equal snapshots must not rewrite rows");
            }
            try (var statement = connection.createStatement(); var prepared = statement.executeQuery("""
                    SELECT generic_plans,custom_plans FROM pg_prepared_statements
                    WHERE statement LIKE 'UPDATE production_material_analysis_materials AS material%'
                    """)) {
                assertTrue(prepared.next());
                assertEquals(6, prepared.getLong(1) + prepared.getLong(2));
                if (mode.equals("force_generic_plan")) assertEquals(6, prepared.getLong(1));
                assertFalse(prepared.next());
            }
            assertRows(connection, count);
            // A custom plan is the important regression: the original global
            // analysis constant estimates one row and repeatedly scans all 49k.
            if (count == 100 && mode.equals("force_custom_plan")) {
                try (var explain = connection.prepareStatement("EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) " + captured.sql())) {
                    bind(explain, captured.values());
                    try (var result = explain.executeQuery()) {
                        assertTrue(result.next());
                        JsonNode plan = new ObjectMapper().readTree(result.getString(1)).get(0).get("Plan");
                        assertBoundedTargetReads(plan, count * 2L);
                    }
                }
            }
            connection.rollback();
        }
    }

    @Test
    void scopeActiveAndEachAtomicFieldRemainAuthoritative() throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            seed(connection, "new", 2);
            assertEquals(0, execute(connection, capture(id("wrong-analysis"), "new", 1)));
            try (var statement = connection.createStatement()) {
                statement.executeUpdate("UPDATE " + TABLE + " SET active=FALSE WHERE analysis_id='" + id("new") + "'");
            }
            assertEquals(0, execute(connection, capture(id("new"), "new", 1)));
            try (var statement = connection.createStatement()) {
                statement.executeUpdate("UPDATE " + TABLE + " SET active=TRUE WHERE analysis_id='" + id("new") + "'");
            }
            Captured captured = capture(id("new"), "new", 1);
            assertEquals(1, execute(connection, captured));
            for (String column : List.of("required_qty", "allocated_available_qty", "allocated_start_qty",
                    "allocated_finish_qty", "allocated_ship_qty", "shortage_qty", "available_qty",
                    "reserved_qty", "safety_stock_qty", "inbound_qty", "lower_level_pending", "expected_ready_date")) {
                String replacement = column.equals("lower_level_pending") ? "FALSE"
                        : column.equals("expected_ready_date") ? "NULL" : column + "+0.0001";
                try (var statement = connection.prepareStatement("UPDATE " + TABLE + " SET " + column + "=" + replacement + " WHERE id=?")) {
                    statement.setObject(1, id("new-node-0"));
                    assertEquals(1, statement.executeUpdate());
                }
                assertEquals(1, execute(connection, captured), "Changed field must be restored: " + column);
                assertEquals(0, execute(connection, captured), "Restored row must be stable: " + column);
            }
            assertRows(connection, 1);
            connection.rollback();
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"inactive", "moved-analysis"})
    void waitingUpdateRechecksScopeAndActiveAgainstCommittedRow(String change) throws Exception {
        String label = "waiting-" + UUID.randomUUID();
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.update(seedSql(), label, id(label), label, 1);
        Captured captured = capture(id(label), label, 1);
        var worker = Executors.newSingleThreadExecutor();
        var backendPid = new LinkedBlockingQueue<Integer>();
        try (Connection writer = dataSource.getConnection()) {
            writer.setAutoCommit(false);
            try {
                String assignment = change.equals("inactive") ? "active=FALSE" : "analysis_id='" + id("moved") + "'";
                try (var statement = writer.prepareStatement("UPDATE " + TABLE + " SET " + assignment + " WHERE id=?")) {
                    statement.setObject(1, id(label + "-node-0"));
                    assertEquals(1, statement.executeUpdate());
                }
                var update = worker.submit(() -> {
                    try (Connection connection = dataSource.getConnection()) {
                        try (var statement = connection.createStatement(); var row = statement.executeQuery("SELECT pg_backend_pid()")) {
                            assertTrue(row.next());
                            backendPid.add(row.getInt(1));
                        }
                        try (var statement = connection.prepareStatement(captured.sql())) {
                            statement.setQueryTimeout(10);
                            bind(statement, captured.values());
                            return statement.executeUpdate();
                        }
                    }
                });
                Integer pid = backendPid.poll(5, TimeUnit.SECONDS);
                assertNotNull(pid);
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
                boolean blocked = false;
                while (System.nanoTime() < deadline) {
                    blocked = Boolean.TRUE.equals(jdbc.queryForObject(
                            "SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=?", Boolean.class, pid));
                    if (blocked) break;
                    assertFalse(update.isDone(), "The writer must encounter the row locked by the other transaction");
                    Thread.sleep(10);
                }
                assertTrue(blocked, "Observe a real PostgreSQL row-lock wait before committing the conflicting change");
                writer.commit();
                assertEquals(0, update.get(5, TimeUnit.SECONDS), "EPQ must reject the now-inactive or out-of-scope row");
            } finally {
                writer.rollback();
            }
        } finally {
            worker.shutdownNow();
            assertTrue(worker.awaitTermination(15, TimeUnit.SECONDS));
            jdbc.update("DELETE FROM " + TABLE + " WHERE id=?", id(label + "-node-0"));
        }
    }

    private static void assertRows(Connection connection, int count) throws Exception {
        try (var query = connection.prepareStatement("""
                SELECT required_qty,allocated_available_qty,allocated_start_qty,allocated_finish_qty,
                       allocated_ship_qty,shortage_qty,lower_level_pending,available_qty,reserved_qty,
                       safety_stock_qty,inbound_qty,expected_ready_date,updated_by
                FROM production_material_analysis_materials WHERE analysis_id=? AND updated_at IS NOT NULL
                """)) {
            query.setObject(1, id("new"));
            int actual = 0;
            try (var rows = query.executeQuery()) {
                while (rows.next()) {
                    actual++;
                    for (int col : List.of(1,2,3,4,5,6,8,9,10,11)) {
                        BigDecimal expected = switch (col) {
                            case 1 -> new BigDecimal("10.0001");
                            case 2 -> new BigDecimal("2.0001");
                            case 6 -> new BigDecimal("8.0000");
                            default -> ZERO;
                        };
                        assertEquals(0, expected.compareTo(rows.getBigDecimal(col)), "Exact field " + col);
                    }
                    assertTrue(rows.getBoolean(7));
                    assertEquals(DATE, rows.getObject(12, LocalDate.class));
                    assertEquals(ACTOR, rows.getObject(13, UUID.class));
                }
            }
            assertEquals(count, actual);
        }
        try (var query = connection.createStatement(); var rows = query.executeQuery(
                "SELECT count(*) FROM " + TABLE + " WHERE analysis_id='" + id("old") + "' AND updated_at IS NOT NULL")) {
            assertTrue(rows.next());
            assertEquals(0, rows.getInt(1), "Existing analyses must remain untouched");
        }
    }

    private static void assertBoundedTargetReads(JsonNode plan, long maximum) {
        if (TABLE.equals(plan.path("Relation Name").asText())) {
            long examined = (plan.path("Actual Rows").asLong() + plan.path("Rows Removed by Filter").asLong())
                    * plan.path("Actual Loops").asLong();
            assertTrue(examined <= maximum, "Stale statistics caused an analysis-wide scan: " + plan);
        }
        for (JsonNode child : plan.path("Plans")) assertBoundedTargetReads(child, maximum);
    }

    private static int execute(Connection connection, Captured captured) throws Exception {
        try (var statement = connection.prepareStatement(captured.sql())) {
            bind(statement, captured.values());
            return statement.executeUpdate();
        }
    }

    private static void bind(PreparedStatement statement, Object[] values) throws Exception {
        for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
    }

    private static void seed(Connection connection, String label, int count) throws Exception {
        try (var statement = connection.prepareStatement(seedSql())) {
            statement.setString(1, label);
            statement.setObject(2, id(label));
            statement.setString(3, label);
            statement.setInt(4, count);
            assertEquals(count, statement.executeUpdate());
        }
    }

    private static String seedSql() {
        return """
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,goods_id,unit_id,depth)
                SELECT md5(?||'-node-'||i)::uuid,?,md5(?||'-item-'||(i/98))::uuid,
                       'root/'||(i%98),md5('goods-'||i)::uuid,md5('unit')::uuid,1
                FROM generate_series(0,?-1)g(i)
                """;
    }

    private static Captured capture(UUID analysis, String label, int count) throws Exception {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        AtomicReference<String> text = new AtomicReference<>();
        Map<String, Object> parameters = new LinkedHashMap<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            assertNull(text.get(), "This input must stay in one bounded statement");
            text.set(call.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1));
            return query;
        });
        MaterialAnalysisService service = mock(MaterialAnalysisService.class, CALLS_REAL_METHODS);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.setField(service, "currentUser", currentUser);
        var constructor = Class.forName(MaterialAnalysisService.class.getName() + "$NodeAllocationRow")
                .getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        List<Object> rows = new ArrayList<>();
        for (int i = 0; i < count; i++) rows.add(constructor.newInstance(id(label + "-item-" + i / 98),
                "root/" + i % 98, new BigDecimal("10.0001"), new BigDecimal("2.0001"),
                ZERO, ZERO, ZERO, new BigDecimal("8.0000"), true, ZERO, ZERO, ZERO, ZERO, DATE));
        ReflectionTestUtils.invokeMethod(service, "updateNodeAllocations", analysis, rows);
        assertEquals(java.util.Set.of("actorId", "snapshots"), parameters.keySet());
        assertEquals(ACTOR, parameters.get("actorId"));
        JsonNode input = new ObjectMapper().readTree((String) parameters.get("snapshots"));
        assertTrue(input.isArray());
        assertEquals(count, input.size());
        for (int i = 0; i < count; i++) {
            JsonNode row = input.get(i);
            assertEquals(16, row.size(), "The complete 15-column snapshot plus stable ordinal is explicit");
            assertEquals(analysis.toString(), row.path("analysis_id").asText(), "Every row retains the caller's analysis scope");
            assertEquals(id(label + "-item-" + i / 98).toString(), row.path("analysis_item_id").asText());
            assertEquals("root/" + i % 98, row.path("node_key").asText());
            assertEquals(i, row.path("_position").asInt());
            assertTrue(row.path("required_qty").isNumber());
            assertEquals(0, new BigDecimal("10.0001").compareTo(row.path("required_qty").decimalValue()));
            assertTrue(row.path("lower_level_pending").asBoolean());
            assertEquals(DATE.toString(), row.path("expected_ready_date").asText());
        }
        var parsed = NamedParameterUtils.parseSqlStatement(text.get());
        var source = new MapSqlParameterSource(parameters);
        return new Captured(NamedParameterUtils.substituteNamedParameters(parsed, source).strip(),
                NamedParameterUtils.buildValueArray(parsed, source, null));
    }

    private record Captured(String sql, Object[] values) {}

    private static UUID id(String value) {
        try {
            var bytes = ByteBuffer.wrap(MessageDigest.getInstance("MD5").digest(value.getBytes(StandardCharsets.UTF_8)));
            return new UUID(bytes.getLong(), bytes.getLong());
        } catch (Exception error) {
            throw new IllegalStateException(error);
        }
    }
}
