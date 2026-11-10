package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production rd task list ({@code RdTaskService.list},
 * the 研发任务 page's complete read) through the shared progressive ladder exactly as the
 * client's fetchPageSized batches do. The service still caps its own page size at 200 and
 * recomputes COUNT per batch; the printed rows/batches/total_ms/first_batch_ms show
 * whether the ladder clears the 3 s migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class RdTaskLadderProbeTest {

    @Test
    void rdTaskCompleteLadderTiming() throws Exception {
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
            var jdbc = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            var service = new RdTaskService(jdbc, mock(BusinessEventPublisher.class),
                    mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class));

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                long b0 = System.nanoTime();
                var result = service.list("open", null, "", null, page, size, java.util.Map.of(), null, null);
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
                    "LADDER_PROBE rd_tasks rows=%d batches=%d total_ms=%d first_batch_ms=%d%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs);
            connection.rollback();
        }
    }
}
