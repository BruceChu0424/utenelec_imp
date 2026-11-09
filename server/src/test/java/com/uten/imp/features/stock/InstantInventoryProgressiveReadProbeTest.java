package com.uten.imp.features.stock;

import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/**
 * Opt-in measurement probe (2026-11-08 progressive reads) against a real database, READ ONLY:
 * the old instant-inventory read (20 rows per request, totals + 4 header buckets recomputed on
 * every request) versus the new one (50 rows first with totals/buckets, then aligned 50/100/200
 * row continuations with rows + count only). Prints request counts, statement counts and timings
 * and checks the new batches join into the same rows in the same order without repeating a row.
 * Run: UTEN_PROGRESSIVE_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_PROGRESSIVE_PROBE", matches = "(?i)true")
class InstantInventoryProgressiveReadProbeTest {

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
                } finally {
                    counter.nanos += System.nanoTime() - start;
                }
            }
            if (call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }

    private record Read(PageResponse<InstantInventoryRow> page, long millis, int statements) { }

    private static Read read(StockQueryService service, Counter counter, ReportReadPlan plan, int page, int size) {
        int before = counter.statements.get();
        long start = System.nanoTime();
        PageResponse<InstantInventoryRow> result;
        try (var ignored = ReportReadPlan.open(plan)) {
            result = service.instantInventory(null, null, false, null, page, size, null, null);
        }
        return new Read(result, (System.nanoTime() - start) / 1_000_000, counter.statements.get() - before);
    }

    private static String key(InstantInventoryRow row) {
        return row.getGoodsId() + "/" + row.getColorId();
    }

    @Test
    void oldTwentyRowPagesVersusProgressiveBatches() throws Exception {
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
            StockCostMasker masker = mock(StockCostMasker.class);
            when(masker.canView()).thenReturn(false);
            var service = new StockQueryService(mock(StockBalanceRepository.class), em, masker);

            // New: 50 first (with totals/buckets), then aligned continuation batches (rows + count only).
            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            var rows = new ArrayList<String>();
            var seen = new HashSet<String>();
            long offset = 0, total = -1, newMillis = 0, firstMillis = 0;
            int newRequests = 0, newStatements = 0;
            do {
                int size = plan.sizeAt(offset), page = plan.pageAt(offset);
                var batch = read(service, counter, newRequests == 0 ? ReportReadPlan.ALL : new ReportReadPlan(true, false, false), page, size);
                if (newRequests == 0) { firstMillis = batch.millis(); total = batch.page().getTotal(); }
                assertThat(batch.page().getTotal()).isEqualTo(total);
                for (var row : batch.page().getItems()) {
                    assertThat(seen.add(key(row))).as("no row is read twice").isTrue();
                    rows.add(key(row));
                }
                offset += batch.page().getItems().size();
                newMillis += batch.millis();
                newStatements += batch.statements();
                newRequests++;
            } while (offset < total);
            assertThat(rows).hasSize((int) total);

            // Old: 20 rows per request, totals + buckets on every request. The full sequence is
            // ~total/20 requests; a spread sample is timed and the old prefix is compared row by row.
            int oldRequests = (int) ((total + 19) / 20);
            var samplePages = new TreeSet<Integer>(List.of(1, 2, 3));
            for (int i = 1; i <= 7; i++) samplePages.add(Math.max(1, (int) ((long) oldRequests * i / 8)));
            samplePages.add(oldRequests);
            long sampleMillis = 0, oldFirstMillis = 0;
            int sampleStatements = 0;
            for (int page : samplePages) {
                var old = read(service, counter, ReportReadPlan.ALL, page, 20);
                if (page == 1) oldFirstMillis = old.millis();
                sampleMillis += old.millis();
                sampleStatements += old.statements();
                var oldKeys = old.page().getItems().stream().map(InstantInventoryProgressiveReadProbeTest::key).toList();
                int from = (page - 1) * 20;
                assertThat(oldKeys).as("old page %d equals the same rows of the joined batches", page)
                        .containsExactlyElementsOf(rows.subList(from, Math.min(from + 20, rows.size())));
            }
            double oldAvgMillis = (double) sampleMillis / samplePages.size();
            double oldAvgStatements = (double) sampleStatements / samplePages.size();
            System.out.printf(Locale.ROOT,
                    "PROGRESSIVE_PROBE rows=%d%n"
                            + "PROGRESSIVE_PROBE old requests=%d first_request_ms=%d avg_request_ms=%.1f est_total_ms=%.0f statements_per_request=%.1f est_statements=%.0f%n"
                            + "PROGRESSIVE_PROBE new requests=%d first_request_ms=%d total_ms=%d statements=%d%n",
                    total, oldRequests, oldFirstMillis, oldAvgMillis, oldAvgMillis * oldRequests, oldAvgStatements,
                    oldAvgStatements * oldRequests, newRequests, firstMillis, newMillis, newStatements);
            connection.rollback();
        }
    }
}
