package com.uten.imp.features.production.schedule;

import com.uten.imp.common.web.CompleteReadBatchPlan;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production schedule pending list
 * ({@code ProductionScheduleService.pending}, the 生产看板待排产 tab's complete read)
 * through the shared progressive ladder exactly as the client's fetchPageSized batches
 * do. Each batch recomputes the pending COUNT and the LATERAL analysis projection; the
 * printed rows/batches/total_ms/first_batch_ms show whether the ladder clears the 3 s
 * migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class ProductionScheduleLadderProbeTest {

    private static Query query(NamedParameterJdbcTemplate named, String sql) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        return mock(Query.class, call -> {
            String method = call.getMethod().getName();
            if (method.equals("setParameter")) { parameters.put(call.getArgument(0), call.getArgument(1)); return call.getMock(); }
            if (method.equals("getResultList") || method.equals("getSingleResult")) {
                if (method.equals("getSingleResult")) return named.queryForObject(sql, parameters, Object.class);
                return named.query(sql, parameters, (rs, row) -> {
                    if (rs.getMetaData().getColumnCount() == 1) return rs.getObject(1);
                    Object[] values = new Object[rs.getMetaData().getColumnCount()];
                    for (int column = 0; column < values.length; column++) values[column] = rs.getObject(column + 1);
                    return values;
                });
            }
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }

    @Test
    void productionSchedulePendingLadderTiming() throws Exception {
        try (Connection connection = DriverManager.getConnection(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"))) {
            connection.setAutoCommit(false);
            connection.setReadOnly(true);
            try (var statement = connection.createStatement()) {
                statement.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY");
                statement.execute("SET LOCAL statement_timeout = '180s'");
                statement.execute("SET LOCAL lock_timeout = '2s'");
                statement.execute("SET LOCAL jit = off");
            }
            var named = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> query(named, call.getArgument(0)));
            var service = new ProductionScheduleService(em, null, null);

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                long b0 = System.nanoTime();
                var result = service.pending(page, size, "", null, null, null, null, null, null);
                long b1 = System.nanoTime();
                if (seen == 0) {
                    total = result.getTotal();
                    firstBatchMs = (b1 - b0) / 1_000_000;
                    assertThat(total).isGreaterThanOrEqualTo(0);
                } else {
                    assertThat(result.getTotal()).isEqualTo(total);
                }
                seen += result.getItems().size();
                batches++;
                if (seen >= total) break;
            }
            assertThat(seen).isEqualTo(total);
            System.out.printf(java.util.Locale.ROOT,
                    "LADDER_PROBE production_schedule_pending rows=%d batches=%d total_ms=%d first_batch_ms=%d%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs);
            connection.rollback();
        }
    }
}
