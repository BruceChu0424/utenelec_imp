package com.uten.imp.features.subcontract.draw;

import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
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
class SubcontractDrawHeaderDatePostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("draw_header_dates");
    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void exactColorAndFullScopeCandidatesSurvivePaginationAndAnEmptySelectedPage() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            String facts = """
                WITH facts(id,owner_id,color_name) AS (VALUES
                  (1,1,'浅灰'::text),(2,1,'浅灰'),(3,1,'梦幻金'),(4,1,'浅灰色'),
                  (5,2,'不应可见'),(6,1,NULL::text),(7,1,''::text))
                """;
            var selected = new SubcontractDrawTableQuery(null, null, Map.of("f.colorName", "浅灰"));
            assertThat(jdbc.queryForObject(facts + " SELECT COUNT(*) FROM facts WHERE owner_id=:owner" + selected.sql(true),
                    parameters(selected), Long.class)).isEqualTo(2L);
            assertThat(jdbc.queryForList(facts + " SELECT id FROM facts WHERE owner_id=:owner" + selected.sql(true)
                    + " ORDER BY id LIMIT 1 OFFSET 1", parameters(selected), Integer.class)).containsExactly(2);
            assertThat(jdbc.queryForList(facts + " SELECT DISTINCT NULLIF(color_name,'') FROM facts WHERE owner_id=:owner"
                    + selected.sql(true, "colorName") + " ORDER BY 1", parameters(selected), String.class))
                    .containsExactly("梦幻金", "浅灰", "浅灰色", null);
            var missing = new SubcontractDrawTableQuery(null, null, Map.of("f.colorName", "__null__"));
            assertThat(jdbc.queryForObject(facts + " SELECT COUNT(*) FROM facts WHERE owner_id=:owner" + missing.sql(true),
                    parameters(missing), Long.class)).isEqualTo(2L);
        }
    }

    @Test void completeLaneDateRangesKeepOwnerAndDifferencePredicatesBeforeCountAndPage() throws Exception {
        try (var connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            String facts = """
                WITH facts(id,owner_id,deliver_date,difference_qty) AS (VALUES
                  (1,1,'2026-10-01'::date,-0.0002::numeric),
                  (2,1,'2026-10-28'::date,-0.0001::numeric),
                  (3,1,'2026-10-29'::date,-0.0001::numeric),
                  (4,2,'2026-10-28'::date,-0.0001::numeric),
                  (5,1,NULL::date,-0.0001::numeric))
                """;
            var headers = new SubcontractDrawTableQuery(null, null, Map.of(
                    "search.needDate", "2026-10-01..2026-10-28", "search.differenceQty", "-0.0002..-0.0001"));
            String filtered = " FROM facts WHERE owner_id=:owner" + headers.sql(true);
            assertThat(jdbc.queryForObject(facts + " SELECT COUNT(*)" + filtered, parameters(headers), Long.class)).isEqualTo(2L);
            assertThat(jdbc.queryForList(facts + " SELECT id" + filtered + " ORDER BY id LIMIT 1 OFFSET 1",
                    parameters(headers), Integer.class)).containsExactly(2);
            var unknown = new SubcontractDrawTableQuery(null, null, Map.of("search.issuedAt", "2026"));
            assertThat(jdbc.queryForObject(facts + " SELECT COUNT(*) FROM facts WHERE owner_id=:owner" + unknown.sql(true),
                    parameters(unknown), Long.class)).isZero();
        }
    }

    private static MapSqlParameterSource parameters(SubcontractDrawTableQuery headers) {
        var parameters = new MapSqlParameterSource("owner", 1);
        Query query = mock(Query.class, invocation -> {
            if ("setParameter".equals(invocation.getMethod().getName()))
                parameters.addValue(invocation.getArgument(0), invocation.getArgument(1));
            return null;
        });
        headers.bind(query);
        return parameters;
    }
}
