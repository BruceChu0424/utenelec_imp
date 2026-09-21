package com.uten.imp.features.sales.shipment.warehouse;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 某一出库行可选的发出仓（V631）：该仓对本行的可发量（已扣安全库存、其它硬预留与来源承诺，
 * 同仓同货多行按行序递减）与是否足够本行数量。表头仓不再是唯一发出仓。
 */
public record WarehouseSalesOutboundWarehouseChoice(
        UUID warehouseId,
        String warehouseName,
        BigDecimal availableQty,
        BigDecimal requiredQty,
        boolean canFulfill) {
}
