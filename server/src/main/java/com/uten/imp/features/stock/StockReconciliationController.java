package com.uten.imp.features.stock;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 库存余额↔流水对账查询（只读，供运维/主管核查账实一致性）。
 *
 * <p>权限沿用 {@code stock:balance:adjust}（与授权余额调整同一受控人群）：能看对账差异的
 * 人就是有权走留痕纠偏的人。端点只返回差异事实，不提供任何修复动作。
 */
@RestController
@RequestMapping("/api/stock/reconciliation")
@RequiredArgsConstructor
public class StockReconciliationController {

    private final StockReconciliationService reconciliation;

    public record DriftRow(
            UUID goodsId,
            UUID warehouseId,
            UUID colorId,
            String goodsName,
            String goodsCode,
            String warehouseName,
            BigDecimal balanceQty,
            BigDecimal flowQty,
            BigDecimal diffQty) {
    }

    public record ReconciliationReport(long driftCount, List<DriftRow> rows, VerificationState verification) {
    }

    /** 分块完整核对游程（B2）：运维可见低峰滚动核对进度与漂移计数。 */
    public record VerificationState(
            java.time.OffsetDateTime lastRunAt,
            UUID lastVerifiedGoods,
            long lastChunkRows,
            long lastDriftCount,
            long fullCycles) {
    }

    @GetMapping
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public ReconciliationReport report(@RequestParam(defaultValue = "50") int limit) {
        // 单次查询同时取明细与总数（旧实现 countDrift+driftRows 各聚合一遍）。
        var report = reconciliation.driftReport(limit);
        List<DriftRow> rows = report.rows().stream()
                .map(r -> new DriftRow(
                        (UUID) r.get("goods_id"),
                        (UUID) r.get("warehouse_id"),
                        (UUID) r.get("color_id"),
                        (String) r.get("goods_name"),
                        (String) r.get("goods_code"),
                        (String) r.get("warehouse_name"),
                        toBd(r.get("balance_qty")),
                        toBd(r.get("flow_qty")),
                        toBd(r.get("balance_qty")).subtract(toBd(r.get("flow_qty")))))
                .toList();
        var state = reconciliation.verificationState();
        return new ReconciliationReport(report.total(), rows,
                state == null ? null : new VerificationState(
                        state.lastRunAt(), state.lastVerifiedGoods(),
                        state.lastChunkRows(), state.lastDriftCount(), state.fullCycles()));
    }

    private static BigDecimal toBd(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal bd) return bd;
        if (value instanceof Number n) return BigDecimal.valueOf(n.doubleValue());
        return new BigDecimal(value.toString());
    }
}
