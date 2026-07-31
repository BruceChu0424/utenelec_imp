package com.uten.imp.features.production.dailyreport.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 报工来源选择行。
 *
 * <p>有销售联动的合并排产按“计划行 × 订单行”展开，避免报工时猜测分摊；
 * 内部生产计划（从未关联销售订单）保留一行，orderItemId 为空。
 */
public record ReportablePlanLine(
        UUID planItemId,
        UUID executionSegmentId,
        UUID executionSegmentSalesAllocationId,
        String executionSegmentCode,
        String executionSegmentStatus,
        Long executionSegmentVersion,
        UUID orderItemId,
        String planNo,
        String productNo,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String goodsSpec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal unitRate,
        BigDecimal plannedQty,
        BigDecimal producedQty,
        BigDecimal remainingPlanQty,
        BigDecimal allocatedQty,
        BigDecimal linkedProducedQty,
        BigDecimal maxReportQty,
        String orderNo,
        BigDecimal orderQty,
        String clientName,
        UUID departmentId,
        String workshopName,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        LocalDate deliveryDate) {
}
