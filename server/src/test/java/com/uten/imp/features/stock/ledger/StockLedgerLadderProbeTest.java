package com.uten.imp.features.stock.ledger;

import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.features.stock.StockCostMasker;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Opt-in measurement probe (2026-11-09 complete-read triage) against the real developer
 * database, READ ONLY: drives the production goods stock ledger
 * ({@code StockLedgerQueryService.ledger}, the goods detail 流水 tab's complete read) for
 * the goods with the most movements, through the shared progressive ladder exactly as the
 * client's fetchPageSized batches do. Every page recomputes the windowed balance and the
 * range summary; the printed rows/batches/total_ms/first_batch_ms show whether the ladder
 * clears the 3 s migration bar on real data.
 * Run: UTEN_LADDER_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_LADDER_PROBE", matches = "(?i)true")
class StockLedgerLadderProbeTest {

    @Test
    void stockLedgerCompleteLadderTiming() throws Exception {
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
            UUID goodsId;
            try (var statement = connection.createStatement();
                 var rows = statement.executeQuery(
                         "SELECT goods_id FROM stock_movements GROUP BY goods_id ORDER BY count(*) DESC LIMIT 1")) {
                assertThat(rows.next()).isTrue();
                goodsId = UUID.fromString(rows.getString(1));
            }
            var costMasker = mock(StockCostMasker.class);
            when(costMasker.canView()).thenReturn(false);
            var service = new StockLedgerQueryService(named, costMasker,
                    mock(StockLedgerSourceAccess.class));

            var plan = CompleteReadBatchPlan.PROGRESSIVE;
            long start = System.nanoTime(), firstBatchMs = -1;
            long seen = 0, total = -1;
            int batches = 0;
            while (true) {
                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                long b0 = System.nanoTime();
                var result = service.ledger(goodsId, null, null, false, null, null, null, null,
                        true, page, size);
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
                    "LADDER_PROBE stock_ledger rows=%d batches=%d total_ms=%d first_batch_ms=%d goods=%s%n",
                    total, batches, (System.nanoTime() - start) / 1_000_000, firstBatchMs, goodsId);
            connection.rollback();
        }
    }
}
