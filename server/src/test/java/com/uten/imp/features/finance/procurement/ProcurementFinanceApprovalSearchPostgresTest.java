package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.util.TaskKeywordSearch;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Executes the actual shared approval WHERE/parameters on an isolated SQL fixture. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementFinanceApprovalSearchPostgresTest {
    static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine").withReuse(false);
    static JdbcTemplate jdbc;
    static final String FIXTURE = """
            WITH c(id,order_type,bill_no_snapshot,display_snapshot) AS (VALUES
                (1,'PURCHASE','PO_100%\\X','{"supplierName":"钢材供应商"}'::jsonb),
                (2,'PURCHASE','POX100AZX','{"supplierName":"钢材供应商"}'::jsonb),
                (3,'SUBCONTRACT','PO_100%\\X','{"supplierName":"钢材供应商"}'::jsonb)),
            supplier(name) AS (VALUES ('改名主档')),
            submitter(full_name) AS (VALUES ('张三'))
            """;
    static final String FROM = " FROM c CROSS JOIN supplier CROSS JOIN submitter WHERE TRUE ";

    @BeforeAll static void start() {
        DATABASE.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
    }
    @AfterAll static void stop() { DATABASE.stop(); }

    @Test void wordsCrossFieldsWhileLiteralWildcardsTypeAndFrozenSupplierStayAuthoritative() {
        var filter = filter("PURCHASE", "钢材\u3000PO_100%\\X 张", null);
        assertEquals(List.of(1), jdbc.queryForList(FIXTURE + "SELECT c.id" + FROM + filter.sql(), Integer.class, filter.args()));
        assertEquals(1L, jdbc.queryForObject(FIXTURE + "SELECT count(*)" + FROM + filter.sql(), Long.class, filter.args()));
        assertEquals(List.of("PO_100%\\X"), jdbc.queryForList(FIXTURE + "SELECT c.bill_no_snapshot" + FROM
                + filter.sql() + " GROUP BY c.bill_no_snapshot", String.class, filter.args()));
        var absent = filter("PURCHASE", "改名主档 PO_100%\\X", null);
        assertEquals(List.of(), jdbc.queryForList(FIXTURE + "SELECT c.id" + FROM + absent.sql(), Integer.class, absent.args()));
    }

    @Test void singleCharacterBlankAndExactBillColumnKeepTheOriginalCandidateRange() {
        var single = filter("PURCHASE", "张", null);
        assertEquals(List.of(1, 2), jdbc.queryForList(FIXTURE + "SELECT c.id" + FROM + single.sql()
                + " ORDER BY c.id", Integer.class, single.args()));
        var exactColumn = filter("", "钢材", " PO_100%\\X ");
        assertEquals(List.of(1, 3), jdbc.queryForList(FIXTURE + "SELECT c.id" + FROM + exactColumn.sql()
                + " ORDER BY c.id", Integer.class, exactColumn.args()));
        var blank = filter("PURCHASE", "\u00a0\u3000", null);
        assertEquals(2L, jdbc.queryForObject(FIXTURE + "SELECT count(*)" + FROM + blank.sql(), Long.class, blank.args()));
    }

    @Test void defaultSearchRelevancePrecedesTheBusinessOrderBeforePaging() {
        String fixture = """
                WITH c(id,order_type,bill_no_snapshot,display_snapshot,submitted_at) AS (VALUES
                  (1,'PURCHASE','XPOX','{"supplierName":"供应商"}'::jsonb,1),
                  (2,'PURCHASE','PO-EXT','{"supplierName":"供应商"}'::jsonb,2),
                  (3,'PURCHASE','PO','{"supplierName":"供应商"}'::jsonb,3)),
                supplier(name) AS (VALUES ('供应商')),
                submitter(full_name) AS (VALUES ('张三'))
                """;
        var filter = filter("PURCHASE", "po", null);
        List<Object> args = new ArrayList<>(List.of(filter.args()));
        String[] fields = ReflectionTestUtils.getField(ProcurementFinanceApprovalService.class, "TASK_SEARCH_FIELDS")
                instanceof String[] values ? values : new String[0];
        String ranking = TaskKeywordSearch.rankPositional("po", fields);
        TaskKeywordSearch.appendRank(args, "po", fields.length);
        assertEquals(List.of(3, 2, 1), jdbc.queryForList(fixture + "SELECT c.id" + FROM + filter.sql()
                + " ORDER BY " + ranking + ",c.submitted_at,c.id", Integer.class, args.toArray()));
    }

    private Filter filter(String type, String input, String billNo) {
        String normalized = ReflectionTestUtils.invokeMethod(ProcurementFinanceApprovalService.class, "normalizeKeyword", input);
        Object filter = ReflectionTestUtils.invokeMethod(ProcurementFinanceApprovalService.class, "taskFilters", type, normalized, billNo);
        String sql = ReflectionTestUtils.invokeMethod(filter, "sql");
        List<?> args = ReflectionTestUtils.invokeMethod(filter, "args");
        return new Filter(sql, args.toArray());
    }

    private record Filter(String sql, Object[] args) {}
}
