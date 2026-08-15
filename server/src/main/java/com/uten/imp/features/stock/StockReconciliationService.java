package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

/**
 * 库存余额 ↔ 流水对账（只读校验，绝不自动改账）。
 *
 * <p>权威口径：{@code stock_balances.qty} 与 {@code Σ stock_movements.qty × direction}
 * 按（仓库 × 货品 × 颜色）逐维度必须相等。两者由 {@code StockService.recordMovement}
 * 同一事务写入，正常路径不会漂移；漂移只可能来自历史迁移误差、手工改库或未来 bug。
 * 本对账是发现这些漂移的唯一机制：每日调度扫描（{@link StockReconciliationScheduler}）
 * + 受控端点按需查询。发现漂移只告警记账，修复必须走 CHECK 盘点/授权调整单等留痕途径。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class StockReconciliationService {

    /** 对账维度 SQL：余额与流水的 FULL OUTER JOIN 差异（双方全 0 的维度不算漂移）。 */
    private static final String DRIFT_SQL = """
            WITH flow AS (
                SELECT m.goods_id, m.color_id, m.warehouse_id,
                       SUM(m.qty * m.direction) AS flow_qty
                FROM stock_movements m
                GROUP BY m.goods_id, m.color_id, m.warehouse_id
            )
            SELECT b.goods_id AS goods_id, b.warehouse_id AS warehouse_id, b.color_id AS color_id,
                   COALESCE(b.qty, 0) AS balance_qty, COALESCE(f.flow_qty, 0) AS flow_qty,
                   g.name AS goods_name, g.code AS goods_code, w.name AS warehouse_name
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

    private final JdbcTemplate jdbc;

    /** 差异维度数（不限量）；0 = 账实（账账）一致。 */
    @Transactional(readOnly = true)
    public long countDrift() {
        Long count = jdbc.queryForObject(
                "SELECT COUNT(*) FROM (" + DRIFT_SQL + ") d", Long.class);
        return count == null ? 0 : count;
    }

    /** 差异明细（最多 limit 行），含货品/仓名便于定位。 */
    @Transactional(readOnly = true)
    public List<Map<String, Object>> driftRows(int limit) {
        return jdbc.queryForList(DRIFT_SQL + " ORDER BY goods_name NULLS LAST, warehouse_name NULLS LAST LIMIT ?",
                Math.min(Math.max(limit, 1), 500));
    }

    /** 调度入口：扫描并告警（只读，异常吞掉只记日志，绝不影响业务）。 */
    public void scanAndWarn() {
        List<Map<String, Object>> rows = driftRows(20);
        if (rows.isEmpty()) {
            log.info("库存对账通过：余额与流水逐维度一致");
            return;
        }
        long total = countDrift();
        log.warn("库存对账发现 {} 个维度余额≠流水（余额=当前库存表，流水=Σ出入库带方向），"
                + "禁止手工改库修复，须走 CHECK 盘点/授权调整单留痕纠偏。前 {} 条明细：", total, rows.size());
        for (Map<String, Object> row : rows) {
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
        if (value instanceof Number n) return BigDecimal.valueOf(n.doubleValue());
        return new BigDecimal(value.toString());
    }
}
