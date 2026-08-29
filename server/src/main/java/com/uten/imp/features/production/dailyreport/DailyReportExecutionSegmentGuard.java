package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeSet;
import java.util.UUID;

/**
 * Exact execution-segment ownership and cumulative quantity guard for reports.
 */
@Service
@RequiredArgsConstructor
public class DailyReportExecutionSegmentGuard {

    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;

    @Transactional(propagation = Propagation.MANDATORY)
    public void validateDraft(
            UUID reportId, List<DailyReportItemLine> lines) {
        List<ReportLine> normalized = lines == null
                ? List.of()
                : lines.stream()
                .map(line -> new ReportLine(
                        null,
                        line.getFqcRecoveryAuthorizationId(),
                        line.getExecutionSegmentId(),
                        line.getExecutionSegmentSalesAllocationId(),
                        line.getSalesOrderItemId(),
                        line.getPlanItemId(),
                        line.getGoodsId(),
                        line.getColorId(),
                        line.getUnitId(),
                        line.getUnitRate(),
                        line.getQty()))
                .toList();
        validateAndLock(reportId, normalized, "DRAFT");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void approve(
            UUID reportId, List<ProductionDailyReportItem> items) {
        List<ReportLine> lines = items.stream()
                .map(item -> new ReportLine(
                        item.getId(),
                        item.getFqcRecoveryAuthorizationId(),
                        item.getExecutionSegmentId(),
                        item.getExecutionSegmentSalesAllocationId(),
                        item.getSalesOrderItemId(),
                        item.getPlanItemId(),
                        item.getGoodsId(),
                        item.getColorId(),
                        item.getUnitId(),
                        item.getUnitRate(),
                        item.getQty()))
                .toList();
        validateAndLock(reportId, lines, "APPROVED");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverse(List<ProductionDailyReportItem> items) {
        List<ReportLine> lines = items.stream()
                .map(item -> new ReportLine(
                        item.getId(),
                        item.getFqcRecoveryAuthorizationId(),
                        item.getExecutionSegmentId(),
                        item.getExecutionSegmentSalesAllocationId(),
                        item.getSalesOrderItemId(),
                        item.getPlanItemId(),
                        item.getGoodsId(),
                        item.getColorId(),
                        item.getUnitId(),
                        item.getUnitRate(),
                        item.getQty()))
                .toList();
        lockAndValidateIdentity(lines, true);
        for (ReportLine line : lines) {
            validateSalesAllocation(line);
        }
    }

    private List<UUID> validateAndLock(
            UUID reportId,
            List<ReportLine> lines,
            String countedStatus) {
        Map<UUID, BigDecimal> requested = new LinkedHashMap<>();
        Map<UUID, BigDecimal> salesRequested = new LinkedHashMap<>();
        Map<UUID, BigDecimal> salesCapacities = new LinkedHashMap<>();
        List<ReportLine> recoveryLines = new ArrayList<>();
        for (ReportLine line : lines) {
            requireSegmentWhenNeeded(line);
            if (line.executionSegmentId() == null) continue;
            if (line.qty() == null || line.qty().signum() <= 0) {
                throw validation("执行段报工数量必须大于 0");
            }
            if (line.recoveryAuthorizationId() == null) {
                requested.merge(
                        line.executionSegmentId(), line.qty(), BigDecimal::add);
            } else {
                recoveryLines.add(line);
            }
        }
        Map<UUID, SegmentSnapshot> segments =
                lockAndValidateIdentity(lines, false);
        for (ReportLine recoveryLine : recoveryLines) {
            validateRecoveryAuthorization(recoveryLine);
        }
        for (ReportLine line : lines) {
            BigDecimal capacity = validateSalesAllocation(line);
            if (line.executionSegmentSalesAllocationId() != null
                    && line.recoveryAuthorizationId() == null) {
                salesRequested.merge(
                        line.executionSegmentSalesAllocationId(),
                        line.qty(),
                        BigDecimal::add);
                salesCapacities.put(
                        line.executionSegmentSalesAllocationId(),
                        capacity);
            }
        }
        for (Map.Entry<UUID, BigDecimal> entry : requested.entrySet()) {
            SegmentSnapshot segment = segments.get(entry.getKey());
            BigDecimal existing = existingQuantity(
                    entry.getKey(), reportId, countedStatus);
            if (existing.add(entry.getValue())
                    .compareTo(segment.plannedQty()) > 0) {
                throw conflict(
                        "执行段累计报工超过计划数量："
                                + segment.segmentCode());
            }
        }
        for (Map.Entry<UUID, BigDecimal> entry :
                salesRequested.entrySet()) {
            BigDecimal existing = existingSalesQuantity(
                    entry.getKey(), reportId, countedStatus);
            BigDecimal capacity =
                    salesCapacities.get(entry.getKey());
            if (existing.add(entry.getValue())
                    .compareTo(capacity) > 0) {
                throw conflict(
                        "执行分段报工数量超出所选销售订单分摊");
            }
        }
        return List.copyOf(new TreeSet<>(requested.keySet()));
    }

    private Map<UUID, SegmentSnapshot> lockAndValidateIdentity(
            List<ReportLine> lines, boolean allowTerminalPackage) {
        validateLegacyPlanItemAccess(lines);
        TreeSet<UUID> ids = lines.stream()
                .map(ReportLine::executionSegmentId)
                .filter(Objects::nonNull)
                .collect(
                        TreeSet::new,
                        TreeSet::add,
                        TreeSet::addAll);
        Map<UUID, SegmentSnapshot> result = new LinkedHashMap<>();
        for (UUID id : ids) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT s.id, s.source_plan_item_id,
                                           s.product_goods_id,
                                           s.product_color_id,
                                           s.product_unit_id,
                                           s.product_unit_rate,
                                           s.planned_qty, s.status,
                                           s.segment_code, package.status,
                                           plan.maker_id
                                    FROM production_execution_segments s
                                    JOIN production_planning_packages package
                                      ON package.id = s.package_id
                                     AND package.is_deleted = FALSE
                                    JOIN production_plans plan
                                      ON plan.id = s.plan_id
                                     AND plan.is_deleted = FALSE
                                    WHERE s.id = :id
                                      AND s.is_deleted = FALSE
                                    FOR UPDATE OF s
                                    """)
                            .setParameter("id", id));
            if (rows.isEmpty()) {
                throw conflict("报工关联的执行段不存在");
            }
            Object[] row = rows.getFirst();
            SegmentSnapshot snapshot = new SegmentSnapshot(
                    (UUID) row[0],
                    (UUID) row[1],
                    (UUID) row[2],
                    (UUID) row[3],
                    (UUID) row[4],
                    decimal(row[5]),
                    decimal(row[6]),
                    (String) row[7],
                    (String) row[8],
                    (String) row[9],
                    (UUID) row[10]);
            access.requireReadable(
                    snapshot.planMakerId(),
                    "报工关联的执行段不存在");
            if (!allowTerminalPackage
                    && !"CONFIRMED".equals(snapshot.packageStatus())) {
                throw conflict("执行段所属计划包已经终止");
            }
            if (!ProductionExecutionSegment.STATUS_IN_PROGRESS
                    .equals(snapshot.status())) {
                throw conflict("执行段必须完成仓库发料并正式开工后才能报工");
            }
            result.put(id, snapshot);
        }
        for (ReportLine line : lines) {
            if (line.executionSegmentId() == null) continue;
            SegmentSnapshot segment = result.get(line.executionSegmentId());
            BigDecimal reportRate =
                    line.unitRate() == null ? BigDecimal.ONE : line.unitRate();
            if (!Objects.equals(
                            line.planItemId(), segment.sourcePlanItemId())
                    || !Objects.equals(
                            line.goodsId(), segment.productGoodsId())
                    || !Objects.equals(
                            line.colorId(), segment.productColorId())
                    || !Objects.equals(
                            line.unitId(), segment.productUnitId())
                    || reportRate.compareTo(segment.productUnitRate()) != 0) {
                throw conflict("报工明细与执行段的计划行或产品维度不一致");
            }
        }
        return result;
    }

    private void validateLegacyPlanItemAccess(List<ReportLine> lines) {
        TreeSet<UUID> planItemIds = lines.stream()
                .filter(line -> line.executionSegmentId() == null)
                .map(ReportLine::planItemId)
                .filter(Objects::nonNull)
                .collect(
                        TreeSet::new,
                        TreeSet::add,
                        TreeSet::addAll);
        for (UUID planItemId : planItemIds) {
            List<?> owners = em.createNativeQuery("""
                            SELECT plan.maker_id
                            FROM production_plan_items item
                            JOIN production_plans plan
                              ON plan.id = item.plan_id
                             AND plan.is_deleted = FALSE
                            WHERE item.id = :planItemId
                              AND item.is_deleted = FALSE
                            """)
                    .setParameter("planItemId", planItemId)
                    .getResultList();
            if (owners.isEmpty()) {
                throw conflict("报工关联的生产计划行不存在");
            }
            access.requireReadable(
                    (UUID) owners.getFirst(),
                    "报工关联的生产计划行不存在");
        }
    }

    private BigDecimal validateSalesAllocation(ReportLine line) {
        if (line.executionSegmentId() == null) {
            if (line.executionSegmentSalesAllocationId() != null) {
                throw conflict(
                        "旧式报工行不能引用执行分段销售分摊");
            }
            return null;
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.id,
                                       allocation.sales_order_item_id,
                                       allocation.allocated_qty
                                FROM execution_segment_sales_allocations allocation
                                WHERE allocation.execution_segment_id = :segmentId
                                ORDER BY allocation.id
                                """)
                        .setParameter(
                                "segmentId",
                                line.executionSegmentId()));
        if (rows.isEmpty()) {
            if (line.executionSegmentSalesAllocationId() != null
                    || line.salesOrderItemId() != null) {
                throw conflict(
                        "内部执行分段不能引用销售订单行");
            }
            return null;
        }
        if (line.executionSegmentSalesAllocationId() == null
                || line.salesOrderItemId() == null) {
            throw validation(
                    "销售关联的执行分段必须指定其精确的销售分摊");
        }
        for (Object[] row : rows) {
            if (Objects.equals(
                            line.executionSegmentSalesAllocationId(),
                            row[0])
                    && Objects.equals(
                            line.salesOrderItemId(), row[1])) {
                return decimal(row[2]);
            }
        }
        throw conflict(
                "所选销售分摊不属于该执行分段");
    }

    private void requireSegmentWhenNeeded(ReportLine line) {
        if (line.executionSegmentId() != null) {
            return;
        }
        if (line.reportItemId() != null) {
            Number legacy = (Number) em.createNativeQuery("""
                            SELECT COUNT(*)
                            FROM production_fqc_legacy_exemptions
                            WHERE source_report_item_id = :reportItemId
                            """)
                    .setParameter("reportItemId", line.reportItemId())
                    .getSingleResult();
            if (legacy.longValue() == 1) return;
        }
        throw validation("V414 后新增报工必须选择已开工执行段；无段历史仅允许显式豁免行");
    }

    private void validateRecoveryAuthorization(ReportLine line) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT recovery_auth.source_plan_item_id,
                                       recovery_auth.execution_segment_id,
                                       recovery_auth.execution_segment_sales_allocation_id,
                                       recovery_auth.goods_id,
                                       recovery_auth.color_id,
                                       recovery_auth.unit_id,
                                       recovery_auth.unit_rate,
                                       recovery_auth.disposition_code,
                                       balance.available_qty,
                                       balance.cancelled,
                                       fn_fqc_replenishment_material_ready(
                                           recovery_auth.id) AS material_ready
                                FROM production_fqc_recovery_authorizations recovery_auth
                                JOIN v_production_fqc_recovery_balance balance
                                  ON balance.authorization_id = recovery_auth.id
                                WHERE recovery_auth.id = :authorizationId
                                FOR UPDATE OF recovery_auth
                                """)
                        .setParameter(
                                "authorizationId",
                                line.recoveryAuthorizationId()));
        if (rows.size() != 1) {
            throw conflict("FQC 返工/补产授权不存在");
        }
        Object[] row = rows.getFirst();
        BigDecimal reportRate = line.unitRate() == null
                ? BigDecimal.ONE : line.unitRate();
        boolean materialReady = Boolean.TRUE.equals(row[10]);
        if (Boolean.TRUE.equals(row[9])
                || (!"REWORK".equals(row[7]) && !materialReady)) {
            throw conflict(
                    "SCRAP/REJECT 必须先由计划部确认补产 BOM，完成仓库领料实发后才能报工");
        }
        if (!Objects.equals(line.planItemId(), row[0])
                || !Objects.equals(line.executionSegmentId(), row[1])
                || !Objects.equals(
                        line.executionSegmentSalesAllocationId(), row[2])
                || !Objects.equals(line.goodsId(), row[3])
                || !Objects.equals(line.colorId(), row[4])
                || !Objects.equals(line.unitId(), row[5])
                || reportRate.compareTo(decimal(row[6])) != 0
                || line.qty().compareTo(decimal(row[8])) > 0) {
            throw conflict("FQC 返工授权与报工身份、单位或开放数量不一致");
        }
    }

    private BigDecimal existingQuantity(
            UUID segmentId, UUID excludedReportId, String countedStatus) {
        String statuses = "APPROVED".equals(countedStatus)
                ? "report.status = 1"
                : "report.status IN (0, 1)";
        Object value = em.createNativeQuery("""
                        SELECT COALESCE(SUM(item.qty), 0)
                        FROM production_daily_report_items item
                        JOIN production_daily_reports report
                          ON report.id = item.report_id
                        WHERE item.execution_segment_id = :segmentId
                          AND item.fqc_recovery_authorization_id IS NULL
                          AND item.report_id <> :reportId
                          AND item.is_deleted = FALSE
                          AND report.is_deleted = FALSE
                          """ + " AND " + statuses)
                .setParameter("segmentId", segmentId)
                .setParameter("reportId", excludedReportId)
                .getSingleResult();
        return decimal(value);
    }

    private BigDecimal existingSalesQuantity(
            UUID allocationId,
            UUID excludedReportId,
            String countedStatus) {
        String statuses = "APPROVED".equals(countedStatus)
                ? "report.status = 1"
                : "report.status IN (0, 1)";
        Object value = em.createNativeQuery("""
                        SELECT COALESCE(SUM(item.qty), 0)
                        FROM production_daily_report_items item
                        JOIN production_daily_reports report
                          ON report.id = item.report_id
                        WHERE item.execution_segment_sales_allocation_id =
                              :allocationId
                          AND item.fqc_recovery_authorization_id IS NULL
                          AND item.report_id <> :reportId
                          AND item.is_deleted = FALSE
                          AND report.is_deleted = FALSE
                          """ + " AND " + statuses)
                .setParameter("allocationId", allocationId)
                .setParameter("reportId", excludedReportId)
                .getSingleResult();
        return decimal(value);
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record ReportLine(
            UUID reportItemId,
            UUID recoveryAuthorizationId,
            UUID executionSegmentId,
            UUID executionSegmentSalesAllocationId,
            UUID salesOrderItemId,
            UUID planItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal qty) {
    }

    private record SegmentSnapshot(
            UUID id,
            UUID sourcePlanItemId,
            UUID productGoodsId,
            UUID productColorId,
            UUID productUnitId,
            BigDecimal productUnitRate,
            BigDecimal plannedQty,
            String status,
            String segmentCode,
            String packageStatus,
            UUID planMakerId) {
    }
}
