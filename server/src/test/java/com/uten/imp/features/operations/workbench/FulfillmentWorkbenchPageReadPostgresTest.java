package com.uten.imp.features.operations.workbench;

import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Types;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/** Real PostgreSQL semantics plus a volatile probe proving one source evaluation per request. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentWorkbenchPageReadPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("workbench_page_read").withReuse(false);
    private static final String GOODS_A = "00000000-0000-0000-0000-00000000000a";
    private static final String GOODS_B = "00000000-0000-0000-0000-00000000000b";
    private Connection connection;
    private NamedParameterJdbcTemplate jdbc;

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @AfterEach void close() throws Exception { if (connection != null) connection.close(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
        Set<String> ids = Set.of("task_id", "package_id", "plan_id", "warehouse_id", "goods_id", "color_id",
                "unit_id", "action_doc_id", "action_item_id");
        Set<String> quantities = Set.of("required_qty", "allocated_qty", "fulfilled_qty", "supply_pegged_qty",
                "open_qty", "orderable_qty", "difference_qty");
        Set<String> dates = Set.of("need_date", "expected_date");
        Set<String> timestamps = Set.of("updated_at", "issued_at");
        Set<String> booleans = Set.of("can_create_order", "materials_defined");
        Set<String> arrays = Set.of("action_item_ids", "bom_missing_item_ids");
        String columns = Arrays.stream(FulfillmentWorkbenchPageRead.ROW_COLUMNS.split(",")).map(String::strip)
                .map(name -> name + " " + (ids.contains(name) ? "uuid" : quantities.contains(name) ? "numeric"
                        : dates.contains(name) ? "date" : timestamps.contains(name) ? "timestamptz"
                        : booleans.contains(name) ? "boolean" : arrays.contains(name) ? "text[]"
                        : "lines".equals(name) ? "jsonb" : name.endsWith("_count") ? "bigint" : "text"))
                .collect(java.util.stream.Collectors.joining(","));
        try(var statement=connection.createStatement()) { statement.execute("CREATE TEMP TABLE workbench_fixture(" + columns + ",visible_doc_no text)"); }
        try(var statement=connection.createStatement()) { statement.execute("CREATE TEMP SEQUENCE workbench_probe"); }
    }

    @Test void emptySourceReturnsMetadataAndNeverEvaluatesAProbeRow() throws Exception {
        var rows = read("COMPLETED", Map.of(), null, null, 0, 20);
        assertEquals(1, rows.size());
        assertNull(rows.getFirst()[0]);
        assertEquals(0L, ((Number) rows.getFirst()[50]).longValue());
        assertTrue(FulfillmentWorkbenchPageRead.counts(rows.getFirst()[54]).isEmpty());
        assertFalse(jdbc.queryForObject("SELECT is_called FROM workbench_probe", Map.of(), Boolean.class));
    }

    @Test void emptySelectedCategoryKeepsFullCountsAndEvaluatesEachSourceOnlyOnce() throws Exception {
        insertRows();
        var rows = read("DOES_NOT_EXIST", Map.of(), null, null, 0, 20);
        Object[] metadata = rows.getFirst();
        assertEquals(1, rows.size());
        assertNull(metadata[0]);
        assertEquals(0L, ((Number) metadata[50]).longValue());
        var statuses = FulfillmentWorkbenchPageRead.counts(metadata[54]);
        assertEquals(2L, statuses.get("WAITING_ORDER"));
        assertEquals(1L, statuses.get("COMPLETED"));
        assertEquals(3L, ((Number) metadata[56]).longValue());
        assertTrue(FulfillmentWorkbenchPageRead.facets(metadata[57]).values().isEmpty());
        assertEquals(4L, jdbc.queryForObject("SELECT last_value FROM workbench_probe", Map.of(), Long.class));
    }

    @Test void dateAndColumnFiltersKeepExclusiveFacetsAndExactQuantities() throws Exception {
        insertRows();
        var rows = read("WAITING_ORDER", Map.of("goods", GOODS_A, "planNo", "P1"),
                LocalDate.of(2026, 10, 1), LocalDate.of(2026, 10, 2), 0, 20);
        Object[] metadata = rows.getFirst();
        assertEquals(1, rows.size());
        assertEquals(GOODS_A, metadata[7].toString());
        assertEquals(new BigDecimal("123456789012345.123456789012345"), metadata[53]);
        assertEquals(1L, ((Number) metadata[50]).longValue());
        assertEquals(3L, ((Number) metadata[56]).longValue());
        assertEquals(2L, FulfillmentWorkbenchPageRead.counts(metadata[54]).get("WAITING_ORDER"));
        assertEquals(2L, FulfillmentWorkbenchPageRead.counts(metadata[55]).get("OVERDUE"));
        var facets = FulfillmentWorkbenchPageRead.facets(metadata[57]);
        assertEquals(List.of(GOODS_A, GOODS_B), facets.values().get("goods").stream()
                .map(FulfillmentWorkbenchPage.Facet::value).toList());
        assertEquals(List.of("P1"), facets.values().get("planNo").stream()
                .map(FulfillmentWorkbenchPage.Facet::value).toList());
        assertEquals(4L, jdbc.queryForObject("SELECT last_value FROM workbench_probe", Map.of(), Long.class));
    }

    @Test void laterAndOutOfRangePagesStillReturnTheirMetadata() throws Exception {
        insertRows();
        Object[] second = read("WAITING_ORDER", Map.of(), null, null, 1, 1).getFirst();
        assertEquals(GOODS_B, second[7].toString());
        assertEquals(2L, ((Number) second[50]).longValue());
        assertEquals(2L, FulfillmentWorkbenchPageRead.counts(second[54]).get("WAITING_ORDER"));
        Object[] beyond = read("WAITING_ORDER", Map.of(), null, null, 3, 1).getFirst();
        assertNull(beyond[0]);
        assertEquals(2L, ((Number) beyond[50]).longValue());
        assertEquals(2L, FulfillmentWorkbenchPageRead.counts(beyond[54]).get("WAITING_ORDER"));
    }

    @Test void warehouseDocumentFacetsRespectIssuedAndNeedDateRanges() throws Exception {
        insertRows();
        try(var statement=connection.createStatement()) { statement.execute("UPDATE workbench_fixture SET department='WAREHOUSE',issued_at=updated_at"); }
        LocalDate day = LocalDate.of(2026, 10, 1);
        for (var table : List.of(
                new FulfillmentWorkbenchTableQuery("needDate", "asc", Map.of(), day, day, null, null),
                new FulfillmentWorkbenchTableQuery("needDate", "asc", Map.of(), null, null, day, day))) {
            Object[] metadata = read("WAITING_ORDER", null, null, 0, 20, "WAREHOUSE", table).getFirst();
            assertEquals(1L, ((Number) metadata[50]).longValue());
            assertEquals(List.of("D1"), FulfillmentWorkbenchPageRead.facets(metadata[57]).values().get("docNo")
                    .stream().map(FulfillmentWorkbenchPage.Facet::value).toList());
        }
    }

    private List<Object[]> read(String status, Map<String, String> filters, LocalDate from, LocalDate to,
                                long offset, int limit) {
        var table = new FulfillmentWorkbenchTableQuery("needDate", "asc", filters, null, null, null, null);
        return read(status, from, to, offset, limit, "PURCHASE", table);
    }

    private List<Object[]> read(String status, LocalDate from, LocalDate to, long offset, int limit,
                                String department, FulfillmentWorkbenchTableQuery table) {
        String source = "(SELECT fixture.*,nextval('workbench_probe') AS probe FROM workbench_fixture fixture)";
        String sql = FulfillmentWorkbenchPageRead.sql(source, "department=:department",
                "(:status='' OR task_status=:status)", "(:exception='' OR exception_code=:exception)",
                "(CAST(:date_from AS date) IS NULL OR updated_at>=CAST(:date_from AS date))"
                        + " AND (CAST(:date_to AS date) IS NULL OR updated_at<CAST(:date_to AS date)+INTERVAL '1 day')",
                "need_date,task_id", department, table);
        var parameters = new MapSqlParameterSource().addValue("department", department)
                .addValue("status", status).addValue("exception", "").addValue("offset", offset).addValue("limit", limit)
                .addValue("date_from", from, Types.DATE).addValue("date_to", to, Types.DATE);
        Query bindings = mock(Query.class, invocation -> {
            if ("setParameter".equals(invocation.getMethod().getName()))
                parameters.addValue(invocation.getArgument(0), invocation.getArgument(1));
            return null;
        });
        table.bind(bindings);
        return jdbc.query(sql, parameters, (rs, index) -> {
            Object[] row = new Object[58];
            for (int column = 0; column < row.length; column++) row[column] = rs.getObject(column + 1);
            return row;
        });
    }

    private void insertRows() throws Exception {
        try(var statement=connection.createStatement()) { statement.execute("""
                INSERT INTO workbench_fixture(department,task_id,goods_id,goods_code,goods_name,plan_no,
                    task_status,display_stage,exception_code,updated_at,need_date,open_qty,open_line_count,visible_doc_no)
                VALUES
                ('PURCHASE','00000000-0000-0000-0000-000000000001','%s','A','货品甲','P1',
                    'WAITING_ORDER','WAITING_ORDER','OVERDUE','2026-10-01','2026-10-01',123456789012345.123456789012345,1,'D1'),
                ('PURCHASE','00000000-0000-0000-0000-000000000002','%s','B','货品乙','P1',
                    'WAITING_ORDER','WAITING_ORDER','OVERDUE','2026-10-02','2026-10-02',0.000000000000001,1,'D2'),
                ('PURCHASE','00000000-0000-0000-0000-000000000003','%s','A','货品甲','P2',
                    'COMPLETED','COMPLETED',NULL,'2026-09-01','2026-09-01',0,0,NULL),
                ('PURCHASE','00000000-0000-0000-0000-000000000004','%s','A','货品甲','P3',
                    'FINANCE_APPROVED','FINANCE_APPROVED','OTHER','2026-10-03','2026-10-03',2,1,'D3')
                """.formatted(GOODS_A, GOODS_B, GOODS_A, GOODS_A)); }
    }
}
