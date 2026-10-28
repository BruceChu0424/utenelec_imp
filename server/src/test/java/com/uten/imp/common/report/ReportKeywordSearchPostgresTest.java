package com.uten.imp.common.report;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.sales.report.SalesReportService;
import com.uten.imp.features.stock.report.StockReportService;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReportKeywordSearchPostgresTest {
    private static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");
    private static NamedParameterJdbcTemplate jdbc;
    private static final String DATA = """
            WITH doc(id,bill_no,goods_name,goods_code,owner_key,qty,year) AS (VALUES
              (1,'AX','螺丝','M3_20%','A',10,2000),
              (2,'AX-EXT','螺丝','M3_20%','A',20,2020),
              (3,'Z-AX-Z','螺丝','M3X20A','A',30,2026),
              (4,'AX','螺丝','M3_20%','OTHER',9999,2026),
              (5,'M3\\A','开关',NULL,'A',40,2026))
            """;

    @BeforeAll static void start() {
        DATABASE.start();
        jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
    }
    @AfterAll static void stop() { DATABASE.stop(); }

    private ReportQueryKit.WhereBuilder where(String text) {
        var where = new ReportQueryKit.WhereBuilder("WHERE owner_key='A'");
        where.search(text, "bill_no", "goods_name", "goods_code");
        return where;
    }

    @Test void relevanceIsAppliedBeforePagingAndRetainsTheApprovedSecondaryOrder() {
        var where = where("AX");
        var full = where.build(null);
        for (int page = 0; page < 3; page++) {
            var parameters = new HashMap<String, Object>(full.params());
            parameters.putAll(where.searchOrderParameters());
            parameters.put("offset", page);
            assertThat(jdbc.queryForList(DATA + "SELECT bill_no FROM doc " + full.sql()
                    + " ORDER BY " + where.orderBy("year DESC,id") + " LIMIT 1 OFFSET :offset",
                    parameters, String.class)).containsExactly(List.of("AX", "AX-EXT", "Z-AX-Z").get(page));
        }
    }

    @Test void multiWordLiteralSearchHasIdenticalRowsCountTotalsAndFacetScope() {
        var where = where("螺丝\u3000M3_20%");
        var full = where.build(null);
        var ranked = new HashMap<String, Object>(full.params());
        ranked.putAll(where.searchOrderParameters());
        assertThat(jdbc.queryForList(DATA + "SELECT id FROM doc " + full.sql()
                + " ORDER BY " + where.orderBy("id"), ranked, Integer.class)).containsExactly(1, 2);
        assertThat(jdbc.queryForObject(DATA + "SELECT count(*) FROM doc " + full.sql(), full.params(), Long.class)).isEqualTo(2);
        assertThat(jdbc.queryForObject(DATA + "SELECT sum(qty) FROM doc " + full.sql(), full.params(), BigDecimal.class))
                .isEqualByComparingTo("30");
        assertThat(jdbc.queryForList(DATA + "SELECT goods_code FROM doc " + full.sql()
                + " GROUP BY goods_code", full.params(), String.class)).containsExactly("M3_20%");
    }

    @Test void backslashAndNullColumnsKeepLiteralSearchAndNoQueryKeepsExistingOrder() {
        var full = where("M3\\A").build(null);
        assertThat(jdbc.queryForList(DATA + "SELECT id FROM doc " + full.sql(), full.params(), Integer.class)).containsExactly(5);
        var empty = where("  ");
        assertThat(empty.orderBy("year DESC,id")).isEqualTo("year DESC,id");
        assertThat(jdbc.queryForObject(DATA + "SELECT count(*) FROM doc " + empty.build(null).sql(),
                empty.build(null).params(), Long.class)).isEqualTo(4);
    }

    @Test void aCompletePhraseRanksAheadOfWordsSplitAcrossDifferentFieldsAndGroupedRows() {
        var where = where("Metric Screw");
        var full = where.build(null);
        var parameters = new HashMap<String, Object>(full.params());
        parameters.putAll(where.searchOrderParameters());
        String rows = "WITH doc(id,bill_no,goods_name,goods_code,owner_key) AS (VALUES "
                + "(1,'Metric','Screw','X','A'),(2,'B','Metric Screw','Y','A')) ";
        assertThat(jdbc.queryForList(rows + "SELECT id FROM doc " + full.sql()
                + " ORDER BY " + where.orderBy("id"), parameters, Integer.class)).containsExactly(2, 1);
        assertThat(jdbc.queryForList(rows + "SELECT goods_name FROM doc " + full.sql()
                + " GROUP BY goods_name ORDER BY " + where.groupedOrderBy("goods_name"), parameters, String.class))
                .containsExactly("Metric Screw", "Screw");
    }

    @Test void historicalReportSearchUsesFrozenLabelsAndNeverRenamedMasterNamesOrCodes() {
        String data = """
                WITH goods(id,code,name,model) AS (VALUES (1,'MASTER-NEW','主档新名称','仅规格')),
                o(id,bill_no,bill_date,status,owner_key) AS (VALUES
                  (1,'单号一',DATE '2026-01-01',1,'A'),
                  (2,'单号二',DATE '2026-01-02',1,'A'),
                  (3,'隐藏单号',DATE '2026-01-03',1,'OTHER')),
                i(id,document_id,goods_id,goods_name_snapshot,goods_code_snapshot,qty) AS (VALUES
                  (1,1,1,'旧名称螺丝','M3_20%\\A',10),
                  (2,2,1,'旧名称螺丝','M3X20AZA',20),
                  (3,3,1,'旧名称螺丝','M3_20%\\A',9999)),
                c(name) AS (VALUES ('客户甲'))
                """;
        String from = " FROM o JOIN i ON i.document_id=o.id CROSS JOIN c ";
        for (String report : List.of("purchase", "sales", "stock")) {
            var where = historicalWhere(report, "旧名称\u3000M3_20%\\A");
            var full = where.build(null);
            var ranked = new HashMap<String, Object>(full.params());
            ranked.putAll(where.searchOrderParameters());
            assertThat(jdbc.queryForList(data + "SELECT i.id" + from + full.sql()
                    + " ORDER BY " + where.orderBy("i.id"), ranked, Integer.class))
                    .as("%s historical identity and literal multi-word rows", report).containsExactly(1);
            assertThat(jdbc.queryForObject(data + "SELECT count(*)" + from + full.sql(), full.params(), Long.class))
                    .as("%s count retains the same historical and owner predicates", report).isEqualTo(1);
            assertThat(jdbc.queryForObject(data + "SELECT sum(i.qty)" + from + full.sql(), full.params(), BigDecimal.class))
                    .as("%s totals exclude the unauthorized historical row", report).isEqualByComparingTo("10");
            assertThat(jdbc.queryForList(data + "SELECT i.goods_code_snapshot" + from + full.sql()
                    + " GROUP BY i.goods_code_snapshot", full.params(), String.class)).containsExactly("M3_20%\\A");
            for (String missing : List.of("主档新名称", "MASTER-NEW", "旧名称 不存在")) {
                var absent = historicalWhere(report, missing).build(null);
                assertThat(jdbc.queryForObject(data + "SELECT count(*)" + from + absent.sql(), absent.params(), Long.class))
                        .as("%s cannot infer a historical label from the renamed master: %s", report, missing).isZero();
            }
            var crossField = historicalWhere(report, "单号一 旧名称").build(null);
            assertThat(jdbc.queryForObject(data + "SELECT count(*)" + from + crossField.sql(), crossField.params(), Long.class))
                    .as("%s words may cross document number and frozen labels", report).isEqualTo(1);
        }
    }

    private ReportQueryKit.WhereBuilder historicalWhere(String report, String keyword) {
        var where = new ReportQueryKit.WhereBuilder("WHERE o.owner_key='A'");
        switch (report) {
            case "purchase" -> ReportQueryKit.addCommonDocFilters(where, null, null, null,
                    null, null, null, keyword, "o.bill_no", "o.bill_date");
            case "sales" -> ReflectionTestUtils.invokeMethod(SalesReportService.class, "addCommonDocFilters",
                    where, null, null, null, null, null, null, keyword, "o.bill_no", "o.bill_date");
            case "stock" -> ReflectionTestUtils.invokeMethod(StockReportService.class, "addCommonFilters",
                    where, null, null, null, null, null, null, null, keyword, true, false);
            default -> throw new IllegalArgumentException(report);
        }
        return where;
    }
}
