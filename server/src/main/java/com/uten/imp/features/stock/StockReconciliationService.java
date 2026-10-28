package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 库存余额 ↔ 流水对账（只读校验，绝不自动改账）。B2 起分两层：
 *
 * <p><b>日常层（变化维度优先）</b>：{@code stock_balances.qty} 与
 * {@code Σ stock_monthly_summaries.qty_net} 按（仓库 × 货品 × 颜色）逐维度核对。
 * 汇总表由 V949 触发器与流水同事务增量维护并整体可重建，粒度远小于流水表，
 * 日常扫描不再对全量 {@code stock_movements} 无窗 SUM；发现漂移只告警记账，
 * 修复必须走 CHECK 盘点/授权调整单等留痕途径。
 *
 * <p><b>完整层（低峰分块）</b>：{@link #verifyGoodsRange} 按货品区间把
 * {@code stock_monthly_summaries} 与 {@code stock_movements} 原始事实逐月核对，
 * 由 {@link StockMonthlyVerificationScheduler} 每天低峰滚动一个区间，
 * 抓取直接改写流水（绕过应用写入路径）造成的投影漂移；同样只记录、不修复。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class StockReconciliationService {

    /**
     * 对账维度 SQL：余额与月度汇总的 FULL OUTER JOIN 差异（双方全 0 的维度不算漂移）。
     * COUNT(*) OVER() 在 WHERE 之后、LIMIT 之前求值，一次查询同时取明细与总数，
     * 替代旧的 countDrift+driftRows 各自全量聚合两遍。
     */
    private static final String DRIFT_SQL = """
            WITH flow AS (
                SELECT s.goods_id, s.color_id, s.warehouse_id,
                       SUM(s.qty_net) AS flow_qty
                FROM stock_monthly_summaries s
                GROUP BY s.goods_id, s.color_id, s.warehouse_id
            )
            SELECT b.goods_id AS goods_id, b.warehouse_id AS warehouse_id, b.color_id AS color_id,
                   COALESCE(b.qty, 0) AS balance_qty, COALESCE(f.flow_qty, 0) AS flow_qty,
                   g.name AS goods_name, g.code AS goods_code, w.name AS warehouse_name,
                   COUNT(*) OVER() AS total_count
            FROM stock_balances b
            FULL OUTER JOIN flow f
                ON f.goods_id = b.goods_id
               AND f.color_id IS NOT DISTINCT FROM b.color_id
               AND f.warehouse_id IS NOT DISTINCT FROM b.warehouse_id
            LEFT JOIN goods g ON g.id = COALESCE(b.goods_id, f.goods_id)
            LEFT JOIN warehouses w ON w.id = COALESCE(b.warehouse_id, f.warehouse_id)
            WHERE COALESCE(b.qty, 0) <> COALESCE(f.flow_qty, 0)
              AND (COALESCE(b.qty, 0) <> 0 OR COALESCE(f.flow_qty, 0) <> 0)
            """;

    /** 分块完整核对：货品闭区间内，月度汇总 ↔ 原始流水逐单元格 FULL OUTER JOIN。 */
    private static final String VERIFY_RANGE_SQL = """
            WITH ledger AS (
                SELECT date_trunc('month', m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE
                           AS month_start,
                       m.movement_type, m.goods_id, m.warehouse_id, m.color_id,
                       SUM(m.qty * m.direction) AS qty_net,
                       SUM(COALESCE(m.amount_local, 0) * m.direction) AS amt_local_net,
                       COUNT(*) AS movement_count,
                       MIN(m.ledger_seq) AS first_ledger_seq,
                       MAX(m.ledger_seq) AS last_ledger_seq
                FROM stock_movements m
                WHERE m.goods_id >= ? AND m.goods_id <= ?
                GROUP BY date_trunc('month', m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE,
                         m.movement_type, m.goods_id, m.warehouse_id, m.color_id
            ), summary AS (
                SELECT month_start, movement_type, goods_id, warehouse_id, color_id,
                       qty_net, amt_local_net, movement_count, first_ledger_seq, last_ledger_seq
                FROM stock_monthly_summaries
                WHERE goods_id >= ? AND goods_id <= ?
            )
            SELECT COALESCE(l.month_start, s.month_start) AS month_start,
                   COALESCE(l.movement_type, s.movement_type) AS movement_type,
                   COALESCE(l.goods_id, s.goods_id) AS goods_id,
                   COALESCE(l.warehouse_id, s.warehouse_id) AS warehouse_id,
                   l.color_id AS ledger_color_id, s.color_id AS summary_color_id,
                   l.qty_net AS ledger_qty_net, s.qty_net AS summary_qty_net,
                   l.amt_local_net AS ledger_amt_local_net, s.amt_local_net AS summary_amt_local_net,
                   l.movement_count AS ledger_movement_count, s.movement_count AS summary_movement_count,
                   l.first_ledger_seq AS ledger_first_ledger_seq, s.first_ledger_seq AS summary_first_ledger_seq,
                   l.last_ledger_seq AS ledger_last_ledger_seq, s.last_ledger_seq AS summary_last_ledger_seq
            FROM ledger l
            FULL OUTER JOIN summary s
              ON s.month_start = l.month_start
             AND s.movement_type IS NOT DISTINCT FROM l.movement_type
             AND s.goods_id IS NOT DISTINCT FROM l.goods_id
             AND s.warehouse_id IS NOT DISTINCT FROM l.warehouse_id
             AND s.color_id IS NOT DISTINCT FROM l.color_id
            WHERE l.month_start IS NULL OR s.month_start IS NULL
               OR l.qty_net <> s.qty_net
               OR l.amt_local_net <> s.amt_local_net
               OR l.movement_count <> s.movement_count
               OR l.first_ledger_seq IS DISTINCT FROM s.first_ledger_seq
               OR l.last_ledger_seq IS DISTINCT FROM s.last_ledger_seq
            """;

    private final JdbcTemplate jdbc;

    /** 差异明细 + 总数（一次查询）；0 差异 = 余额与汇总口径一致。 */
    @Transactional(readOnly = true)
    public DriftReport driftReport(int limit) {
        int safeLimit = Math.min(Math.max(limit, 1), 500);
        List<Map<String, Object>> rows = jdbc.queryForList(
                DRIFT_SQL + " ORDER BY goods_name NULLS LAST, warehouse_name NULLS LAST LIMIT ?",
                safeLimit);
        long total = rows.isEmpty() ? 0
                : ((Number) rows.get(0).get("total_count")).longValue();
        return new DriftReport(total, rows.stream().map(r -> {
            Map<String, Object> copy = new HashMap<>(r);
            copy.remove("total_count");
            return (Map<String, Object>) copy;
        }).toList());
    }

    /**
     * 分块完整核对（只读）：把闭区间 [lo, hi] 内货品的月度汇总与原始流水逐单元格核对，
     * 返回漂移单元格（空 = 一致）。绝不自动修复——差异必须暴露并追因。
     */
    @Transactional(readOnly = true)
    public List<Map<String, Object>> verifyGoodsRange(UUID lo, UUID hi) {
        return jdbc.queryForList(VERIFY_RANGE_SQL, lo, hi, lo, hi);
    }

    /** 调度入口：扫描并告警（只读，异常吞掉只记日志，绝不影响业务）。 */
    public void scanAndWarn() {
        DriftReport report = driftReport(20);
        if (report.total() == 0) {
            log.info("库存对账通过：余额与月度汇总逐维度一致");
            return;
        }
        log.warn("库存对账发现 {} 个维度余额≠流水(余额=当前库存表，流水=Σ月度汇总带方向)，"
                + "禁止手工改库修复，须走 CHECK 盘点/授权调整单留痕纠偏。前 {} 条明细：",
                report.total(), report.rows().size());
        for (Map<String, Object> row : report.rows()) {
            log.warn("  [库存漂移] 仓={} 货品={}({}) 颜色={} 余额={} 流水合计={} 差额={}",
                    row.get("warehouse_name"),
                    row.get("goods_name"),
                    row.get("goods_code"),
                    row.get("color_id"),
                    toPlain(row.get("balance_qty")),
                    toPlain(row.get("flow_qty")),
                    diff(row));
        }
    }

    /** 余额↔汇总日常对账结果（total=漂移维度数，rows≤limit 明细）。 */
    public record DriftReport(long total, List<Map<String, Object>> rows) {
    }

    private static String toPlain(Object value) {
        if (value == null) return "0";
        if (value instanceof BigDecimal bd) return bd.stripTrailingZeros().toPlainString();
        return value.toString();
    }

    private static String diff(Map<String, Object> row) {
        BigDecimal balance = toBd(row.get("balance_qty"));
        BigDecimal flow = toBd(row.get("flow_qty"));
        return balance.subtract(flow).stripTrailingZeros().toPlainString();
    }

    private static BigDecimal toBd(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal bd) return bd;
        if (value instanceof Long || value instanceof Integer || value instanceof Short) {
            return BigDecimal.valueOf(((Number) value).longValue());
        }
        if (value instanceof Number n) {
            // 数量只来自 numeric 列; 浮点会让差异核对出现假差异, 直接暴露。
            throw new IllegalStateException("库存数量列类型不精确: " + n.getClass().getName());
        }
        return new BigDecimal(value.toString());
    }

    /** 分块核对游程状态（stock_monthly_verification_state 单行的投影）。 */
    public record VerificationState(OffsetDateTime lastRunAt, UUID lastVerifiedGoods,
                                    long lastChunkRows, long lastDriftCount, long fullCycles) {
    }

    /** 读取分块核对游程状态（运维可见：最近核对到哪个货品、发现多少漂移）。 */
    @Transactional(readOnly = true)
    public VerificationState verificationState() {
        return jdbc.queryForObject(
                "SELECT last_run_at, last_verified_goods, last_chunk_rows, last_drift_count, full_cycles "
                        + "FROM stock_monthly_verification_state WHERE singleton",
                (rs, i) -> new VerificationState(
                        rs.getObject("last_run_at", OffsetDateTime.class),
                        rs.getObject("last_verified_goods", UUID.class),
                        rs.getLong("last_chunk_rows"),
                        rs.getLong("last_drift_count"),
                        rs.getLong("full_cycles")));
    }
}
