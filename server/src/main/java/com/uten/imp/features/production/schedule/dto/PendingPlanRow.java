package com.uten.imp.features.production.schedule.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 待排产订单行（调度工作台左侧列表）。
 *
 * <p>口径：已审未结案未中止订单中，链路行（chain_status 1..8）且新增排产缺口大于 0。
 * 新增排产缺口 = max(订单量 − 已发 + 已退 − 核销 − 当前预留
 * − max(已排产 − 已产, 0), 0)；已产且已入库预留的数量不会重复扣减。
 * 列表按交货日期升序（越近越前）。
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
        boolean urgent,            // 距交货 ≤3 天（含逾期），前端红色醒目
        UUID materialAnalysisId,
        UUID materialAnalysisLineId,
        String materialAnalysisStatus,
        Long materialAnalysisVersion,
        OffsetDateTime materialAnalyzedAt,
        BigDecimal analyzedQty,
        BigDecimal submittedPlanQty,
        BigDecimal approvedPlannedQty,
        BigDecimal readyNowQty,
        BigDecimal readyByDateQty,
        BigDecimal readinessRatio) {
}
