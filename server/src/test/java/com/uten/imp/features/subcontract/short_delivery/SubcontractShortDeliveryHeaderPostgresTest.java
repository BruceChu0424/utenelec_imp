package com.uten.imp.features.subcontract.short_delivery;

import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.DriverManager;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class SubcontractShortDeliveryHeaderPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("short_header");
    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void headerPredicatesKeepOwnerScopeExactDecimalsBeijingDatesAndWholeResultPagination() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            var headers = new SubcontractShortDeliveryTableQuery(Map.of(
                    "search.shortfallQty", "0.0001..0.0002", "search.goodsName", "毛坯", "search.detectedAt", "2026-10-28"));
            String fixture = """
                    WITH c(id,owner_employee_id,goods_name_snapshot,shortfall_qty,detected_at) AS (VALUES
                      (1,1,'毛坯甲',0.0001::numeric,'2026-10-27 18:00+00'::timestamptz),
                      (2,1,'毛坯乙',0.0002::numeric,'2026-10-27 18:01+00'::timestamptz),
                      (3,2,'毛坯丙',0.0001::numeric,'2026-10-27 18:02+00'::timestamptz),
                      (4,1,'毛坯丁',NULL::numeric,'2026-10-27 18:03+00'::timestamptz)),
                    goods AS (SELECT 'fallback'::text AS name)
                    """;
            var parameters = parameters(headers);
            String from = " FROM c CROSS JOIN goods WHERE c.owner_employee_id=:owner" + headers.sql(null);
            assertThat(jdbc.queryForObject(fixture + " SELECT COUNT(*)" + from, parameters, Long.class)).isEqualTo(2L);
            assertThat(jdbc.queryForList(fixture + " SELECT c.id" + from + " ORDER BY "
                    + SubcontractShortDeliveryTableQuery.orderBy("shortfallQty", "asc", "c.id") + " LIMIT 1 OFFSET 1",
                    parameters, Integer.class)).containsExactly(2);
            var nonzero = new SubcontractShortDeliveryTableQuery(Map.of("search.shortfallQty", "!=0"));
            assertThat(jdbc.queryForObject(fixture + " SELECT COUNT(*) FROM c WHERE c.owner_employee_id=:owner"
                    + nonzero.sql(null), parameters(nonzero), Long.class)).isEqualTo(2L);
        }
    }

    @Test void calendarAndInstantHeadersShareClosedChineseDayRangesWithoutTruncatingTheLastSecond() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            var headers = new SubcontractShortDeliveryTableQuery(Map.of(
                    "search.detectedAt", "2026-10-28..2026-10-29", "search.closedAt", "2026-10-29",
                    "search.expectedCompleteBy", "2026-10-28..2026-10-29"));
            String fixture = """
                WITH c(id,owner_employee_id,detected_at,closed_at,expected_complete_by) AS (VALUES
                  (1,1,'2026-10-27 16:00+00'::timestamptz,'2026-10-29 15:59:59.999999+00'::timestamptz,'2026-10-29'::date),
                  (2,1,'2026-10-29 16:00+00'::timestamptz,'2026-10-29 15:59:59+00'::timestamptz,'2026-10-29'::date),
                  (3,1,'2026-10-28 16:00+00'::timestamptz,NULL::timestamptz,'2026-10-29'::date),
                  (4,2,'2026-10-27 16:00+00'::timestamptz,'2026-10-29 15:59:59+00'::timestamptz,'2026-10-29'::date),
                  (5,1,'2026-10-28 16:00+00'::timestamptz,'2026-10-29 15:59:59+00'::timestamptz,'2026-10-30'::date))
                SELECT c.id FROM c WHERE c.owner_employee_id=:owner
                """;
            assertThat(jdbc.queryForList(fixture + headers.sql(null), parameters(headers), Integer.class)).containsExactly(1);
            assertThat(headers.sql("detectedAt")).doesNotContain("c.detected_at >=").contains("c.closed_at >=");
        }
    }

    private static MapSqlParameterSource parameters(SubcontractShortDeliveryTableQuery headers) {
        var parameters = new MapSqlParameterSource("owner", 1);
        Query bindings = mock(Query.class, invocation -> {
            if ("setParameter".equals(invocation.getMethod().getName()))
                parameters.addValue(invocation.getArgument(0), invocation.getArgument(1));
            return null;
        });
        headers.bind(bindings, null);
        return parameters;
    }
}
