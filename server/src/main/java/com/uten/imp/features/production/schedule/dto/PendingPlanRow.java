package com.uten.imp.features.production.schedule.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 待排产订单行（调度工作台左侧列表）。
 *
 * <p>口径：已审未结案未中止订单中，链路行（chain_status>0）且
 * 待生产缺口 = qty − reserved − planned > 0 的明细行；按交货日期升序（越近越前）。
 */
public record PendingPlanRow(
        UUID orderItemId,
        UUID orderId,
        String orderBillNo,
        UUID clientId,
        String clientName,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String spec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal qty,
        BigDecimal reservedQty,
        BigDecimal plannedQty,
        BigDecimal needQty,
        LocalDate deliverDate,
        Short chainStatus,
        boolean urgent) {          // 距交货 ≤3 天（含逾期），前端红色醒目
}
