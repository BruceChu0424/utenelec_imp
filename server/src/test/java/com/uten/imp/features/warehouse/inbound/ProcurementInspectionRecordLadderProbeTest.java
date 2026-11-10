package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionRecordContracts.InspectionDecisionRecordPage;
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
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production {@code ProcurementInspectionRecordQueryService.list}
 * (IQC decision records, the complete-read path of the quality records page) through the
 * shared progressive ladder exactly as the client's fetchPageSized batches do. Prints
 * rows/batches/total_ms/first_batch_ms plus statement counts — the service runs COUNT +
 * page + metrics on every batch, so the numbers show whether the whole ladder clears the
 * 3 s migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class ProcurementInspectionRecordLadderProbeTest {

    private static final class Counter {
        final AtomicInteger statements = new AtomicInteger();
        long nanos;
    }

    private static Query query(NamedParameterJdbcTemplate named, String sql, Counter counter) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        return mock(Query.class, call -> {
            String method = call.getMethod().getName();
            if (method.equals("setParameter")) { parameters.put(call.getArgument(0), call.getArgument(1)); return call.getMock(); }
            if (method.equals("getResultList") || method.equals("getSingleResult")) {
                counter.statements.incrementAndGet();
                long start = System.nanoTime();
                try {
                    if (method.equals("getSingleResult")) return named.queryForObject(sql, parameters, Object.class);
                    return named.query(sql, parameters, (rs, row) -> {
                        if (rs.getMetaData().getColumnCount() == 1) return rs.getObject(1);
                        Object[] values = new Object[rs.getMetaData().getColumnCount()];
                        for (int column = 0; column < values.length; column++) values[column] = rs.getObject(column + 1);
                        return values;
                    });
                } finally { counter.nanos += System.nanoTime() - start; }
            }
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }

    @Test
    void iqcRecordsCompleteLadderTiming() throws Exception {
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
            var counter = new Counter();
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> query(named, call.getArgument(0), counter));
            var service = new ProcurementInspectionRecordQueryService(em);

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0, statements = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                int before = counter.statements.get();
                long b0 = System.nanoTime();
                InspectionDecisionRecordPage result = service.list(null, null, null, null, null,
                        null, null, page, size, null, null, null, null);
                long b1 = System.nanoTime();
                if (seen == 0) {
                    total = result.total();
                    firstBatchMs = (b1 - b0) / 1_000_000;
                    assertThat(total).isGreaterThanOrEqualTo(0);
                } else {
                    assertThat(result.total()).isEqualTo(total);
                }
                seen += result.items().size();
                statements += counter.statements.get() - before;
                batches++;
                if (seen >= total) break;
            }
            assertThat(seen).isEqualTo(total);
            System.out.printf(java.util.Locale.ROOT,
                    "LADDER_PROBE iqc_records rows=%d batches=%d total_ms=%d first_batch_ms=%d statements=%d%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs, statements);
            connection.rollback();
        }
    }
}
