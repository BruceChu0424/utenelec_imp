package com.uten.imp.features.production.dailyreport.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 报工来源选择行。
 *
 * <p>有销售联动的合并排产按“计划行 × 订单行”展开，避免报工时猜测分摊；
 * 执行段未分摊给销售的批准数量保留独立内部来源，orderItemId 与销售分摊 ID 均为空；
 * 它既包括纯内部生产，也包括同一工单中超出销售分摊的公共备货。
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
        LocalDate deliveryDate,
        UUID fqcRecoveryAuthorizationId,
        String fqcRecoveryDispositionCode,
        BigDecimal fqcRecoveryAvailableQty,
        UUID fqcSourceInspectionId,
        UUID fqcSourceReportItemId,
        String fqcSourceReportNo,
        boolean fqcRecoveryRequiresMaterial,
        UUID planId) {
}
