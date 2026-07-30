package com.uten.imp.features.sales.order.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 批量发货可发行（SOP §一9）：已审未结案订单中 reserved_qty>0 的明细行。
 * 归属隔离与订单列表同口径（sales:view:all 豁免）。
 */
public record OrderShippableLine(
        UUID orderItemId,
        UUID orderId,
        String billNo,
        UUID clientId,
        LocalDate deliverDate,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal qty,
        BigDecimal shippedQty,
        BigDecimal reservedQty,
        BigDecimal price
) {}
