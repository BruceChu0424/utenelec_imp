package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.order.dto.PlanProgressLine.PreparationProgress;
import com.uten.imp.features.sales.order.dto.PlanProgressLine.SupplySource;
import java.math.BigDecimal;
import java.util.List;

/** Physical preparation is independent of the manufacturing route and shipment permission. */
final class SalesOrderPreparationProgress {
    private SalesOrderPreparationProgress() {}

    static PreparationProgress of(BigDecimal qty, BigDecimal flagged, BigDecimal shipped,
            BigDecimal returned, BigDecimal physicalStock, List<SupplySource> sources) {
        BigDecimal target = nz(qty).subtract(nz(flagged)).max(BigDecimal.ZERO);
        BigDecimal netShipped = nz(shipped).subtract(nz(returned)).max(BigDecimal.ZERO);
        BigDecimal stock = nz(physicalStock).max(BigDecimal.ZERO);
        return new PreparationProgress(target, netShipped.add(stock).min(target), stock,
                netShipped, List.copyOf(sources));
    }

    private static BigDecimal nz(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }
}
