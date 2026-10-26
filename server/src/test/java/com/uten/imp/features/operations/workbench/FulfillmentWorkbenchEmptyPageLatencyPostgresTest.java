package com.uten.imp.features.operations.workbench;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.MountableFile;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Measures real generated SQL against a dump of this run's empty, isolated migration template. */
@EnabledIfEnvironmentVariable(named = "UTEN_EMPTY_BENCHMARK_DUMP", matches = ".+")
class FulfillmentWorkbenchEmptyPageLatencyPostgresTest {
    @Test void compareSixReadQueriesWithOneSharedProjectionOnAnEmptyBusinessDatabase() throws Exception {
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("workbench_latency")
                .withReuse(false).withCopyFileToContainer(MountableFile.forHostPath(
                        System.getenv("UTEN_EMPTY_BENCHMARK_DUMP")), "/tmp/empty-baseline.dump")) {
            postgres.start();
            var restored = postgres.execInContainer("pg_restore", "-U", postgres.getUsername(),
                    "-d", postgres.getDatabaseName(), "--no-owner", "--no-privileges", "/tmp/empty-baseline.dump");
            assertEquals(0, restored.getExitCode(), restored.getStderr());
            try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                var jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
                var parameters = new MapSqlParameterSource();
                String optimized = generatedSql(parameters);
                List<String> legacy = equivalentSixReads(optimized);
                assertEquals(6, legacy.size());
                for (String table : List.of("purchase_request_items", "purchase_order_items", "subcontract_order_items"))
                    assertEquals(0L, jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Map.of(), Long.class));
                var result = jdbc.queryForList(optimized, parameters);
                assertEquals(1, result.size());
                assertEquals(0L, ((Number) result.getFirst().get("page_total")).longValue());
                assertTrue(jdbc.queryForList(legacy.getFirst(), parameters).isEmpty());
                assertEquals(0L, ((Number) jdbc.queryForList(legacy.get(1), parameters).getFirst().get("total")).longValue());
                for (int warmup = 0; warmup < 2; warmup++) {
                    duration(jdbc, legacy, parameters);
                    duration(jdbc, List.of(optimized), parameters);
                }
                var sixSamples = new ArrayList<Double>();
                var oneSamples = new ArrayList<Double>();
                for (int sample = 0; sample < 9; sample++) {
                    if (sample % 2 == 0) {
                        sixSamples.add(duration(jdbc, legacy, parameters));
                        oneSamples.add(duration(jdbc, List.of(optimized), parameters));
                    } else {
                        oneSamples.add(duration(jdbc, List.of(optimized), parameters));
                        sixSamples.add(duration(jdbc, legacy, parameters));
                    }
                }
                var report = new LinkedHashMap<String, Object>();
                report.put("database", "isolated PostgreSQL " + postgres.getDockerImageName());
                report.put("schemaVersion", jdbc.queryForObject("SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1", Map.of(), String.class));
                report.put("scope", "PURCHASE / COMPLETED / all dates / no column filters / empty business database");
                report.put("comparison", "Former six equivalent row/summary/status/exception/pending/facet SQL reads reconstructed from the same current authorized projection versus the new single SQL; same connected JDBC session; two warmups and nine alternating trials");
                report.put("legacySqlPerRequest", 6);
                report.put("optimizedSqlPerRequest", 1);
                report.put("legacyMedianMs", median(sixSamples));
                report.put("optimizedMedianMs", median(oneSamples));
                report.put("medianSpeedup", median(sixSamples) / median(oneSamples));
                report.put("legacySamplesMs", sixSamples);
                report.put("optimizedSamplesMs", oneSamples);
                String json = new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(report);
                Path output = Path.of(System.getenv().getOrDefault("UTEN_LOADING_BENCHMARK_REPORT",
                        "target/category-loading-empty-latency.json"));
                Files.createDirectories(output.toAbsolutePath().getParent());
                Files.writeString(output, json + System.lineSeparator());
                System.out.println("Empty workbench SQL benchmark: " + json);
            }
        }
    }

    private static String generatedSql(MapSqlParameterSource parameters) {
        var em = mock(EntityManager.class);
        var captured = new ArrayList<String>();
        Object[] empty = new Object[58];
        empty[50] = 0L; empty[51] = 0L; empty[52] = 0L; empty[53] = BigDecimal.ZERO;
        empty[54] = "{}"; empty[55] = "{}"; empty[56] = 0L; empty[57] = "[]";
        Query query = mock(Query.class, invocation -> {
            if ("setParameter".equals(invocation.getMethod().getName())) {
                String name = invocation.getArgument(0);
                Object value = invocation.getArgument(1);
                if (name.startsWith("date_")) parameters.addValue(name, value, Types.DATE);
                else parameters.addValue(name, value);
                return null;
            }
            return "getResultList".equals(invocation.getMethod().getName())
                    ? Collections.singletonList(empty) : null;
        });
        when(em.createNativeQuery(anyString())).thenAnswer(call -> { captured.add(call.getArgument(0)); return query; });
        var access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canCreatePurchaseOrder()).thenReturn(true);
        when(access.documentAccess(anyString(), anyString()))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));
        new FulfillmentWorkbenchQueryService(em, access).query("PURCHASE", "COMPLETED", "", "", null, null, 1, 20,
                new FulfillmentWorkbenchTableQuery("needDate", "asc", Map.of(), null, null, null, null));
        assertEquals(1, captured.size());
        return captured.getFirst();
    }

    private static List<String> equivalentSixReads(String optimized) {
        Map<String, String> ctes = ctes(optimized);
        String base = "WITH candidates AS NOT MATERIALIZED (" + ctes.get("candidates") + ")";
        String selected = base + ",selected_rows AS NOT MATERIALIZED (" + ctes.get("selected_rows") + ") ";
        String page = ctes.get("page_rows").replaceFirst("(?s), ROW_NUMBER\\(\\) OVER \\(ORDER BY .*?\\) AS page_position", "");
        String selectedFilter = ctes.get("selected_rows").split("WHERE", 2)[1];
        String facets = "WITH candidates AS MATERIALIZED (" + ctes.get("candidates") + " AND " + selectedFilter
                + ") " + ctes.get("facet_rows");
        return List.of(selected + page, selected + ctes.get("page_summary"), base + ctes.get("status_rows"),
                base + ctes.get("exception_rows"), base + ctes.get("pending_count"), facets);
    }

    private static Map<String, String> ctes(String sql) {
        var result = new LinkedHashMap<String, String>();
        var pattern = Pattern.compile("\\s*(?:WITH|,)\\s+(\\w+)\\s+AS\\s+(?:MATERIALIZED\\s+)?\\(");
        int cursor = 0;
        while (cursor < sql.length()) {
            var match = pattern.matcher(sql).region(cursor, sql.length());
            if (!match.lookingAt()) break;
            int start = match.end(), index = start, depth = 1;
            boolean quoted = false;
            while (depth > 0) {
                char value = sql.charAt(index++);
                if (value == '\'') {
                    if (quoted && index < sql.length() && sql.charAt(index) == '\'') index++;
                    else quoted = !quoted;
                } else if (!quoted) {
                    if (value == '(') depth++;
                    else if (value == ')') depth--;
                }
            }
            result.put(match.group(1), sql.substring(start, index - 1));
            cursor = index;
        }
        assertEquals(11, result.size());
        return result;
    }

    private static double duration(NamedParameterJdbcTemplate jdbc, List<String> queries, MapSqlParameterSource parameters) {
        long start = System.nanoTime();
        queries.forEach(sql -> jdbc.queryForList(sql, parameters));
        return (System.nanoTime() - start) / 1_000_000.0;
    }

    private static double median(List<Double> samples) {
        var sorted = new ArrayList<>(samples);
        Collections.sort(sorted);
        return sorted.get(sorted.size() / 2);
    }
}
