package com.uten.imp.features.stock;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 库存月度汇总低峰分块完整核对（B2）。
 *
 * <p>每日 03:41（错开 03:17 审计归档）滚动核对一个货品区间：把
 * {@code stock_monthly_summaries} 与 {@code stock_movements} 原始事实逐月逐格比对，
 * 抓取绕过应用写入路径直接改写流水造成的投影漂移。只记录差异并告警，
 * 绝不自动修复——修复必须走重建函数或留痕业务途径，差异本身要保留追因。
 *
 * <p>游程状态（{@code stock_monthly_verification_state} 单行）记录最近核对区间、
 * 货品数、漂移数与完成圈数；核对完最后一个货品后从最小 id 重新开始并计数一圈。
 */
@Slf4j
@Component
@Profile("!cloud")
public class StockMonthlyVerificationScheduler {

    private static final UUID MIN_UUID = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final StockReconciliationService reconciliation;
    private final JdbcTemplate jdbc;
    private final int chunkSize;

    public StockMonthlyVerificationScheduler(
            StockReconciliationService reconciliation,
            JdbcTemplate jdbc,
            @Value("${uten.stock.monthly-verification.chunk-size:250}") int chunkSize) {
        this.reconciliation = reconciliation;
        this.jdbc = jdbc;
        this.chunkSize = Math.max(10, chunkSize);
    }

    @Scheduled(cron = "0 41 3 * * *", zone = "Asia/Shanghai")
    public void verifyChunk() {
        try {
            runOnce();
        } catch (Exception e) {
            jdbc.update("UPDATE stock_monthly_verification_state "
                    + "SET last_run_at=now(), last_error=? WHERE singleton", e.toString());
            log.warn("库存月度汇总分块核对失败(不影响业务): {}", e.toString());
        }
    }

    /** 核对一个货品区间并推进游程（核对只读、游程可重放，无跨语句原子性要求）；
     * 返回本区间发现的漂移单元格（测试/运维可直接调用）。 */
    public List<Map<String, Object>> runOnce() {
        UUID cursor = jdbc.queryForObject(
                "SELECT last_verified_goods FROM stock_monthly_verification_state WHERE singleton", UUID.class);
        List<UUID> chunk = goodsAfter(cursor);
        boolean wrapped = false;
        if (chunk.isEmpty()) {
            jdbc.update("UPDATE stock_monthly_verification_state "
                    + "SET full_cycles=full_cycles+1, last_verified_goods=NULL, last_error=NULL "
                    + "WHERE singleton");
            wrapped = true;
            chunk = goodsAfter(null);
            if (chunk.isEmpty()) {
                recordRun(null, 0, List.of());
                return List.of();
            }
        }
        UUID lo = chunk.get(0);
        UUID hi = chunk.get(chunk.size() - 1);
        List<Map<String, Object>> drift = reconciliation.verifyGoodsRange(lo, hi);
        recordRun(hi, chunk.size(), drift);
        if (wrapped) {
            log.info("库存月度汇总分块核对完成一圈，从最小货品重新开始");
        }
        if (!drift.isEmpty()) {
            log.warn("库存月度汇总完整核对：货品区间 [{}]..[{}] 发现 {} 个汇总↔流水漂移单元格"
                    + "（不自动修复，须核对 fn_rebuild_stock_monthly_summaries 与原始流水追因），前 10 格：",
                    lo, hi, drift.size());
            drift.stream().limit(10).forEach(cell -> log.warn("  [汇总漂移] {}", cell));
        }
        return drift;
    }

    private List<UUID> goodsAfter(UUID cursor) {
        return jdbc.queryForList(
                "SELECT id FROM goods WHERE id > ? ORDER BY id LIMIT " + chunkSize,
                UUID.class, cursor == null ? MIN_UUID : cursor);
    }

    private void recordRun(UUID lastGoods, int goodsCount, List<Map<String, Object>> drift) {
        jdbc.update("UPDATE stock_monthly_verification_state "
                        + "SET last_verified_goods=?, last_run_at=now(), last_chunk_rows=?, "
                        + "last_drift_count=?, last_error=NULL WHERE singleton",
                lastGoods, goodsCount, drift.size());
    }
}
