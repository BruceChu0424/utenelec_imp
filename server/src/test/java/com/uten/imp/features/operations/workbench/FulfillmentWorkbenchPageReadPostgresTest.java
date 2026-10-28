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
import java.util.UUID;

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

    @Test void differenceHeaderFiltersWholeResultWithExactDecimalsAndExcludesUnknownOrGroupedFacts() throws Exception {
        insertRows();
        try(var statement=connection.createStatement()) { statement.execute("""
                UPDATE workbench_fixture SET difference_qty=CASE task_id::text
                  WHEN '00000000-0000-0000-0000-000000000001' THEN -9007199254740993.0001::numeric
                  WHEN '00000000-0000-0000-0000-000000000002' THEN -9007199254740993.0002::numeric
                  WHEN '00000000-0000-0000-0000-000000000004' THEN -0.1::numeric END,
                  visible_doc_no=CASE WHEN task_id::text='00000000-0000-0000-0000-000000000004'
                    THEN NULL ELSE visible_doc_no END
                """); }
        var exact = read("", Map.of("search.differenceQty", "=-9007199254740993.0001"), null, null, 0, 1);
        assertEquals(1L, ((Number) exact.getFirst()[50]).longValue());
        assertEquals(new BigDecimal("-9007199254740993.0001"), exact.getFirst()[49]);
        var second = read("", Map.of("search.differenceQty", "-9007199254740993.0002..-9007199254740993.0001"),
                null, null, 1, 1).getFirst();
        assertEquals(2L, ((Number) second[50]).longValue());
        assertEquals(new BigDecimal("-9007199254740993.0002"), second[49]);
        // SQL's unknown comparison excludes missing and unreadable values even for !=.
        assertEquals(2L, ((Number) read("", Map.of("search.differenceQty", "!=0"), null, null, 0, 20)
                .getFirst()[50]).longValue());
        try(var statement=connection.createStatement()) { statement.execute("""
                UPDATE workbench_fixture SET goods_count=2
                  WHERE task_id::text='00000000-0000-0000-0000-000000000001';
                UPDATE workbench_fixture SET action_item_ids=ARRAY['item1','item2']
                  WHERE task_id::text='00000000-0000-0000-0000-000000000002'
                """); }
        assertEquals(0L, ((Number) read("", Map.of("search.differenceQty", "<0"), null, null, 0, 20)
                .getFirst()[50]).longValue());
    }

    private List<Object[]> read(String status, Map<String, String> filters, LocalDate from, LocalDate to,
                                long offset, int limit) {
        var table = new FulfillmentWorkbenchTableQuery("needDate", "asc", filters, null, null, null, null);
        return read(status, from, to, offset, limit, "PURCHASE", table);
    }

    @Test void operationsQuantityQueriesUseVisibleSingleMaterialValuesWithoutTreatingGroupedLinesOrDiscoveryAsNumbers() throws Exception {
        insertRows();
        try(var statement=connection.createStatement()) {statement.execute("""
                UPDATE workbench_fixture SET required_qty=12.3456,allocated_qty=4.1234,fulfilled_qty=3.1111,open_qty=9.2345,
                  goods_count=1,open_line_count=1,action_doc_type='PURCHASE_ORDER',need_date='2026-10-28',expected_date='2026-10-29',
                  issued_at='2026-10-27T16:00:00Z';
                UPDATE workbench_fixture SET allocated_qty=5.1234 WHERE task_id::text='00000000-0000-0000-0000-000000000002';
                UPDATE workbench_fixture SET visible_doc_no=NULL WHERE task_id::text='00000000-0000-0000-0000-000000000001';
                UPDATE workbench_fixture SET goods_count=2,open_line_count=2,required_qty=1000,allocated_qty=1000,fulfilled_qty=1000,open_qty=1000
                  WHERE task_id::text='00000000-0000-0000-0000-000000000003';
                UPDATE workbench_fixture SET task_status='MATERIALS_TO_DEFINE',action_doc_type='MATERIAL_DISCOVERY',visible_doc_no=NULL,
                  required_qty=1000,allocated_qty=1000,fulfilled_qty=1000,open_qty=1000,need_date=NULL,expected_date=NULL
                  WHERE task_id::text='00000000-0000-0000-0000-000000000004';
                """);}
        var table=new FulfillmentWorkbenchTableQuery("allocatedQty","desc",Map.of("search.requiredQty","12.3456",
                "search.allocatedQty",">=4.1234","search.fulfilledQty","3.1111","search.openQty","9.2345"),null,null,null,null).forOperationsProjection();
        var first=read("",null,null,0,1,"PURCHASE",table).getFirst();
        var second=read("",null,null,1,1,"PURCHASE",table).getFirst();
        assertEquals(2L,((Number)first[50]).longValue());
        assertEquals(UUID.fromString("00000000-0000-0000-0000-000000000002"),first[1]);
        assertEquals(UUID.fromString("00000000-0000-0000-0000-000000000001"),second[1]);
        assertEquals(new BigDecimal("5.1234"),first[17]);
        var rawPending=new FulfillmentWorkbenchTableQuery(null,null,Map.of("search.requiredQty",">=999"),null,null,null,null);
        assertEquals(2L,((Number)read("",null,null,0,20,"PURCHASE",rawPending).getFirst()[50]).longValue());
        assertEquals(0L,((Number)read("",null,null,0,20,"PURCHASE",rawPending.forOperationsProjection()).getFirst()[50]).longValue());
    }

    @Test void typedWorkbenchDatesUseChineseInstantsAndLocalCalendarRangesWithoutChangingExactDateFacets() throws Exception {
        insertRows();
        try(var statement=connection.createStatement()) {statement.execute("""
                UPDATE workbench_fixture SET need_date='2026-10-28',expected_date='2026-11-02',issued_at='2026-10-27T16:00:00Z';
                UPDATE workbench_fixture SET issued_at='2026-10-28T16:00:00Z' WHERE task_id::text='00000000-0000-0000-0000-000000000004';
                """);}
        var table=new FulfillmentWorkbenchTableQuery("expectedDate","asc",Map.of("search.needDate","2026-10-28..2026-10-28",
                "search.expectedDate","2026-11","search.issuedAt","2026-10-28"),null,null,null,null).forOperationsProjection();
        assertEquals(3L,((Number)read("",null,null,0,1,"PURCHASE",table).getFirst()[50]).longValue());
        assertEquals(1,read("",null,null,2,1,"PURCHASE",table).size());
        var exact=new FulfillmentWorkbenchTableQuery(null,null,Map.of("needDate","2026-10-28"),null,null,null,null);
        assertEquals(4L,((Number)read("",null,null,0,20,"PURCHASE",exact).getFirst()[50]).longValue());
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                ()->new FulfillmentWorkbenchTableQuery(null,null,Map.of("search.expectedDate","2026-02-30"),null,null,null,null));
    }

    private List<Object[]> read(String status, LocalDate from, LocalDate to, long offset, int limit,
                                String department, FulfillmentWorkbenchTableQuery table) {
        String source = "(SELECT fixture.*,nextval('workbench_probe') AS probe FROM workbench_fixture fixture)";
        String sql = FulfillmentWorkbenchPageRead.sql(source, "department=:department",
                "(:status='' OR task_status=:status)", "(:exception='' OR exception_code=:exception)",
                "(CAST(:date_from AS date) IS NULL OR updated_at>=CAST(:date_from AS date))"
                        + " AND (CAST(:date_to AS date) IS NULL OR updated_at<CAST(:date_to AS date)+INTERVAL '1 day')",
                table==null?"need_date,task_id":table.orderSql(), department, table);
        var parameters = new MapSqlParameterSource().addValue("department", department)
                .addValue("status", status).addValue("exception", "").addValue("offset", offset).addValue("limit", limit)
                .addValue("date_from", from, Types.DATE).addValue("date_to", to, Types.DATE);
        Query bindings = mock(Query.class, invocation -> {
            if ("setParameter".equals(invocation.getMethod().getName()))
                parameters.addValue(invocation.getArgument(0), invocation.getArgument(1));
            return null;
        });
        if (table != null) {
            table.bind(bindings);
        }
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
