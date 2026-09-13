package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
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
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/**
 * Executes the SQL captured from qualifiedOwnedStock, with actual non-empty
 * candidates. A 70k reference payload and generic prepared plan expose the
 * per-candidate array parsing path that an empty entitlement fixture misses.
 * This thin fixture isolates query admission/aggregation; qualification itself
 * is represented by stored evidence and retains its separate domain tests.
 */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisArrayMembershipPostgresTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");

    private static final UUID ANALYSIS = UUID.fromString("10000000-0000-4000-8000-000000000001");
    private static final UUID OTHER_ANALYSIS = UUID.fromString("10000000-0000-4000-8000-000000000002");
    private static final UUID PARENT_WAREHOUSE = UUID.fromString("20000000-0000-4000-8000-000000000001");
    private static final UUID WAREHOUSE = UUID.fromString("20000000-0000-4000-8000-000000000002");
    private static final UUID DELETED_WAREHOUSE = UUID.fromString("20000000-0000-4000-8000-000000000003");
    private static final UUID NON_ACCOUNTABLE = UUID.fromString("20000000-0000-4000-8000-000000000004");
    private static final UUID UNIT = UUID.fromString("30000000-0000-4000-8000-000000000001");
    private static final UUID COLOR = UUID.fromString("40000000-0000-4000-8000-000000000001");
    private static DriverManagerDataSource dataSource;
    private static Set<String> references;
    private static final Map<UUID, Integer> ORDINAL_BY_GOODS = new HashMap<>();

    @BeforeAll
    static void fixture() throws Exception {
        dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY,parent_id uuid,is_deleted boolean,is_accountable boolean)");
        jdbc.execute("""
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY,warehouse_id uuid,goods_id uuid,
                    color_id uuid,is_deleted boolean,status integer,owner_type text,qualified boolean)
                """);
        jdbc.execute("""
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,analysis_id uuid,
                    analysis_item_id uuid,node_key text,unit_id uuid)
                """);
        jdbc.execute("""
                CREATE TABLE entitlement_evidence(stock_reservation_id uuid,beneficiary_analysis_id uuid,
                    beneficiary_analysis_material_id uuid,effective_qty numeric(20,4))
                """);
        jdbc.execute("CREATE VIEW v_preplan_stock_entitlement_beneficiary_balance AS SELECT * FROM entitlement_evidence");
        jdbc.execute("""
                CREATE FUNCTION fn_preplan_reservation_has_qualified_origin(uuid) RETURNS boolean
                LANGUAGE sql STABLE AS $$ SELECT qualified FROM stock_reservations WHERE id=$1 $$
                """);
        jdbc.update("INSERT INTO warehouses VALUES (?,NULL,FALSE,TRUE),(?,?,FALSE,TRUE),(?,NULL,TRUE,TRUE),(?,NULL,FALSE,FALSE)",
                PARENT_WAREHOUSE, WAREHOUSE, PARENT_WAREHOUSE, DELETED_WAREHOUSE, NON_ACCOUNTABLE);
        jdbc.execute("""
                CREATE TABLE candidate_fixture AS
                SELECT i, CASE WHEN i%4=0 THEN 70000+i ELSE i*70 END AS ref_number,
                       md5('reservation-'||i)::uuid AS reservation_id,
                       md5('material-'||i)::uuid AS material_id,md5('goods-'||i)::uuid AS goods_id
                FROM generate_series(1,1000)g(i)
                """);
        jdbc.update("""
                INSERT INTO stock_reservations
                SELECT reservation_id,?,goods_id,CASE WHEN i%3=0 THEN CAST(? AS uuid) ELSE NULL END,
                       FALSE,0,'PREPLAN_ANALYSIS',TRUE FROM candidate_fixture
                """, WAREHOUSE, COLOR);
        jdbc.update("""
                INSERT INTO production_material_analysis_materials
                SELECT material_id,?,md5('stable-analysis-'||ref_number)::uuid,'root/'||ref_number,?
                FROM candidate_fixture
                """, ANALYSIS, UNIT);
        jdbc.update("""
                INSERT INTO entitlement_evidence
                SELECT reservation_id,?,material_id,(i/10.0+0.0001)::numeric(20,4) FROM candidate_fixture
                """, ANALYSIS);
        for (String guard : List.of("deleted", "inactive", "other-owner", "parent-warehouse",
                "deleted-warehouse", "non-accountable", "unqualified", "zero", "other-analysis", "material-mismatch")) {
            UUID reservation = fixtureId("guard-reservation-" + guard);
            UUID material = fixtureId("guard-material-" + guard);
            UUID warehouse = switch (guard) {
                case "parent-warehouse" -> PARENT_WAREHOUSE;
                case "deleted-warehouse" -> DELETED_WAREHOUSE;
                case "non-accountable" -> NON_ACCOUNTABLE;
                default -> WAREHOUSE;
            };
            jdbc.update("INSERT INTO stock_reservations VALUES (?,?,?,NULL,?,?,?,?)", reservation,
                    warehouse, fixtureId("goods-1"), guard.equals("deleted"), guard.equals("inactive") ? 1 : 0,
                    guard.equals("other-owner") ? "OTHER" : "PREPLAN_ANALYSIS", !guard.equals("unqualified"));
            UUID beneficiary = guard.equals("other-analysis") ? OTHER_ANALYSIS : ANALYSIS;
            jdbc.update("INSERT INTO production_material_analysis_materials VALUES (?,?,?,?,?)", material,
                    guard.equals("material-mismatch") ? OTHER_ANALYSIS : beneficiary,
                    fixtureId("stable-analysis-70"), "root/70", UNIT);
            jdbc.update("INSERT INTO entitlement_evidence VALUES (?,?,?,?)", reservation, beneficiary, material,
                    guard.equals("zero") ? BigDecimal.ZERO : new BigDecimal("9999.1234"));
        }
        references = new LinkedHashSet<>(jdbc.queryForList("""
                SELECT md5('stable-analysis-'||i)::uuid::text||'|root/'||i
                FROM generate_series(1,70000)g(i) ORDER BY i
                """, String.class));
        assertEquals(70000, references.size());
        for (int i = 1; i <= 1000; i++) ORDINAL_BY_GOODS.put(fixtureId("goods-" + i), i);
        for (String table : List.of("warehouses", "stock_reservations",
                "production_material_analysis_materials", "entitlement_evidence")) jdbc.execute("ANALYZE " + table);
    }

    @ParameterizedTest
    @ValueSource(strings = {"force_generic_plan", "auto"})
    void realQualifiedStockQueryKeepsIdentityQuantityAndTwoBindingsAcrossPreparedExecutions(String mode)
            throws Exception {
        Captured captured = captureProductionQuery();
        assertEquals(Set.of("analysisId", "nodeKeys"), captured.parameters().keySet());
        assertInstanceOf(String.class, captured.parameters().get("nodeKeys"));
        assertEquals(70000, ((String) captured.parameters().get("nodeKeys")).split(",").length);
        var parsed = NamedParameterUtils.parseSqlStatement(captured.sql());
        var source = new MapSqlParameterSource(captured.parameters());
        String jdbcSql = NamedParameterUtils.substituteNamedParameters(parsed, source).strip();
        Object[] values = NamedParameterUtils.buildValueArray(parsed, source, null);
        assertEquals(2, values.length, "Reference cardinality must not expand into JDBC parameters");

        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            connection.setReadOnly(true);
            try (var configuration = connection.createStatement()) {
                configuration.execute("SET LOCAL statement_timeout='10s'");
                configuration.execute("SET LOCAL jit=off");
                configuration.execute("SET LOCAL plan_cache_mode=" + mode);
            }
            try (var query = connection.prepareStatement(jdbcSql)) {
                query.unwrap(PGStatement.class).setPrepareThreshold(1);
                for (int run = 1; run <= 6; run++) {
                    query.setObject(1, values[0]);
                    query.setString(2, (String) values[1]);
                    Set<Integer> identities = new HashSet<>();
                    BigDecimal total = BigDecimal.ZERO;
                    try (var rows = query.executeQuery()) {
                        while (rows.next()) {
                            Integer ordinal = ORDINAL_BY_GOODS.get(rows.getObject(2, UUID.class));
                            assertNotNull(ordinal, "Unexpected goods identity admitted");
                            assertNotEquals(0, ordinal % 4, "A missing reference was admitted");
                            assertTrue(identities.add(ordinal), "A source identity was duplicated");
                            assertTrue(WAREHOUSE.equals(rows.getObject(1, UUID.class)), "Physical leaf warehouse changed");
                            UUID expectedColor = ordinal % 3 == 0 ? COLOR : null;
                            assertTrue(java.util.Objects.equals(expectedColor, rows.getObject(3, UUID.class)), "Color identity changed");
                            assertTrue(UNIT.equals(rows.getObject(4, UUID.class)), "Unit identity changed");
                            BigDecimal expectedQuantity = BigDecimal.valueOf(ordinal).movePointLeft(1)
                                    .add(new BigDecimal("0.0001"));
                            assertEquals(0, expectedQuantity.compareTo(rows.getBigDecimal(5)), "Exact qualified quantity changed");
                            total = total.add(rows.getBigDecimal(5));
                        }
                    }
                    assertEquals(750, identities.size());
                    assertEquals(0, new BigDecimal("37500.0750").compareTo(total));
                    assertEquals(2, query.getParameterMetaData().getParameterCount());
                }
            }
            try (var probe = connection.createStatement(); var rows = probe.executeQuery("""
                    SELECT generic_plans,custom_plans,cardinality(parameter_types)
                    FROM pg_prepared_statements
                    WHERE statement LIKE 'SELECT reservation.warehouse_id%'
                    """)) {
                assertTrue(rows.next(), "The driver must use an actual server prepared statement");
                assertEquals(2, rows.getInt(3));
                assertEquals(6, rows.getLong(1) + rows.getLong(2));
                if (mode.equals("force_generic_plan")) assertEquals(6, rows.getLong(1));
                else assertTrue(rows.getLong(1) >= 1, "The sixth auto execution must exercise a generic plan");
                assertFalse(rows.next());
            }
            connection.rollback();
        }
    }

    private static Captured captureProductionQuery() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        AtomicReference<String> text = new AtomicReference<>();
        Map<String, Object> parameters = new LinkedHashMap<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            assertNull(text.get(), "Large reference sets must use one SQL statement");
            text.set(call.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1));
            return query;
        });
        when(query.getResultList()).thenReturn(new ArrayList<>());
        MaterialAnalysisService service = mock(MaterialAnalysisService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "em", em);
        ReflectionTestUtils.invokeMethod(service, "qualifiedOwnedStock", ANALYSIS, references);
        assertNotNull(text.get());
        return new Captured(text.get(), parameters);
    }

    private record Captured(String sql, Map<String, Object> parameters) {}

    private static UUID fixtureId(String value) throws Exception {
        // Deterministic synthetic IDs matching PostgreSQL md5(text)::uuid.
        var bytes = ByteBuffer.wrap(MessageDigest.getInstance("MD5")
                .digest(value.getBytes(StandardCharsets.UTF_8)));
        return new UUID(bytes.getLong(), bytes.getLong());
    }
}
