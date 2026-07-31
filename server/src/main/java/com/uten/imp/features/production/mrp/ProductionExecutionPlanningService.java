package com.uten.imp.features.production.mrp;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Loads and fingerprints the direct, single-level BOM snapshot used by
 * complete-kit execution planning.
 */
@Service
@RequiredArgsConstructor
public class ProductionExecutionPlanningService {

    private final EntityManager em;
    private static final String GOODS_SOURCE_PURCHASE = "\u91c7\u8d2d";
    private static final String GOODS_SOURCE_SELF_MADE = "\u81ea\u5236";
    private static final String GOODS_SOURCE_SUBCONTRACT = "\u59d4\u5916";

    private final CompleteKitAllocator allocator = new CompleteKitAllocator();

    @Transactional(readOnly = true)
    public Snapshot preview(UUID planId, UUID warehouseId) {
        return snapshot(planId, warehouseId, Map.of(), false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public Snapshot lockedSnapshot(
            UUID planId,
            UUID warehouseId,
            Map<CompleteKitAllocator.MaterialKey, String> routeOverrides) {
        return snapshot(planId, warehouseId, routeOverrides, true);
    }

    public CompleteKitAllocator.Allocation propose(Snapshot snapshot) {
        return allocator.allocate(snapshot.productLines(), snapshot.availability());
    }

    public CompleteKitAllocator.Allocation applyRequested(
            Snapshot snapshot,
            List<GeneratePlanningPackageRequest.ExecutionSegment> requested) {
        if (requested == null || requested.isEmpty()) {
            return propose(snapshot);
        }
        Map<UUID, CompleteKitAllocator.ProductLine> source = new HashMap<>();
        snapshot.productLines().forEach(line -> source.put(line.sourcePlanItemId(), line));
        Map<UUID, BigDecimal> totals = new HashMap<>();
        List<CompleteKitAllocator.RequestedSegment> edits =
                new ArrayList<>(requested.size());
        Set<String> keys = new java.util.HashSet<>();
        for (GeneratePlanningPackageRequest.ExecutionSegment edit : requested) {
            if (edit == null
                    || edit.getSourcePlanItemId() == null
                    || edit.getClientSegmentKey() == null
                    || edit.getClientSegmentKey().isBlank()
                    || !keys.add(edit.getClientSegmentKey().strip())) {
                throw validation("执行分段缺少来源行或客户端分段键重复");
            }
            CompleteKitAllocator.ProductLine line =
                    source.get(edit.getSourcePlanItemId());
            if (line == null) {
                throw validation("执行分段不属于当前生产计划");
            }
            if (!line.bomFingerprint().equalsIgnoreCase(edit.getBomFingerprint())) {
                throw conflict("执行分段 BOM 已变化，请刷新排产预览");
            }
            if (edit.getPlanBeginDate() != null
                    && edit.getPlanEndDate() != null
                    && edit.getPlanEndDate().isBefore(edit.getPlanBeginDate())) {
                throw validation("计划完工日期不能早于计划开工日期");
            }
            BigDecimal qty = scaleProduct(edit.getPlannedQty());
            totals.merge(line.sourcePlanItemId(), qty, BigDecimal::add);
            CompleteKitAllocator.ProductLine editedLine =
                    withAssignments(line, edit);
            edits.add(new CompleteKitAllocator.RequestedSegment(
                    edit.getClientSegmentKey().strip(),
                    editedLine,
                    edit.getRequestedStatus(),
                    qty));
        }
        for (CompleteKitAllocator.ProductLine line : snapshot.productLines()) {
            if (totals.getOrDefault(line.sourcePlanItemId(), BigDecimal.ZERO)
                    .compareTo(line.plannedQty()) != 0) {
                throw conflict(
                        "每个生产计划行的执行分段数量合计必须严格等于原计划数量");
            }
        }
        try {
            return allocator.allocateRequested(edits, snapshot.availability());
        } catch (CompleteKitAllocator.InsufficientKitException ex) {
            throw conflict("标记为 READY 的执行分段没有完整库存齐套支持");
        } catch (IllegalArgumentException ex) {
            throw validation("执行分段数量、状态或物料数据无效");
        }
    }

    public List<ExecutionSegmentPreview> toPreview(
            CompleteKitAllocator.Allocation allocation) {
        return allocation.segments().stream()
                .map(segment -> new ExecutionSegmentPreview(
                        segment.clientSegmentKey(),
                        segment.line().sourcePlanItemId(),
                        segment.line().lineNo(),
                        segment.line().productGoodsId(),
                        segment.line().productCode(),
                        segment.line().productName(),
                        segment.line().productColorId(),
                        segment.line().productUnitId(),
                        segment.plannedQty(),
                        segment.status(),
                        segment.line().defaultWorkshopDepartmentId(),
                        segment.line().defaultTeamDepartmentId(),
                        segment.line().defaultResponsibleEmployeeId(),
                        segment.line().planBeginDate(),
                        segment.line().planEndDate(),
                        segment.line().bomFingerprint(),
                        segment.materials().stream()
                                .map(material -> new ExecutionSegmentPreview.Material(
                                        material.goodsId(),
                                        material.colorId(),
                                        material.unitId(),
                                        material.perProductQty(),
                                        material.requiredQty(),
                                        material.availableBeforeQty(),
                                        material.candidateAllocatedQty(),
                                        material.shortageQty(),
                                        material.supplyRoute()))
                                .toList()))
                .toList();
    }

    private Snapshot snapshot(
            UUID planId,
            UUID warehouseId,
            Map<CompleteKitAllocator.MaterialKey, String> rawRoutes,
            boolean lock) {
        if (planId == null || warehouseId == null) {
            throw validation("生产计划和目标仓库不能为空");
        }
        Map<CompleteKitAllocator.MaterialKey, String> routes =
                rawRoutes == null ? Map.of() : Map.copyOf(rawRoutes);
        String lockClause = lock ? " FOR UPDATE OF i, b" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT i.id,
                                       COALESCE(i.line_no, 0),
                                       i.goods_id,
                                       i.color_id,
                                       i.unit_id,
                                       COALESCE(i.unit_rate, 1),
                                       i.qty,
                                       i.plan_begin_date,
                                       i.plan_end_date,
                                       p.department_id,
                                       p.worker_id,
                                       product.code,
                                       product.name,
                                       b.id,
                                       b.component_goods_id,
                                       resolved_color.id,
                                       component_unit.id,
                                       b.qty,
                                       COALESCE(
                                           NULLIF(b.color_legacy_id, 0),
                                           NULLIF(component.color_legacy_id, 0)),
                                       EXISTS (
                                           SELECT 1
                                           FROM goods_bom_items child
                                           WHERE child.goods_id =
                                                 b.component_goods_id
                                             AND child.is_deleted = FALSE
                                       ) AS component_has_bom,
                                       i.updated_at,
                                       b.updated_at,
                                       component.source_type
                                FROM production_plan_items i
                                JOIN production_plans p
                                  ON p.id = i.plan_id
                                 AND p.is_deleted = FALSE
                                JOIN goods product
                                  ON product.id = i.goods_id
                                 AND product.is_deleted = FALSE
                                JOIN units product_unit
                                  ON product_unit.id = i.unit_id
                                 AND product_unit.is_deleted = FALSE
                                JOIN goods_bom_items b
                                  ON b.goods_id = i.goods_id
                                 AND b.is_deleted = FALSE
                                JOIN goods component
                                  ON component.id = b.component_goods_id
                                 AND component.is_deleted = FALSE
                                LEFT JOIN colors resolved_color
                                  ON resolved_color.legacy_id = COALESCE(
                                      NULLIF(b.color_legacy_id, 0),
                                      NULLIF(component.color_legacy_id, 0))
                                 AND resolved_color.is_deleted = FALSE
                                LEFT JOIN units component_unit
                                  ON component_unit.legacy_id =
                                     component.unit_legacy_id
                                 AND component_unit.is_deleted = FALSE
                                WHERE i.plan_id = :planId
                                  AND i.is_deleted = FALSE
                                  AND COALESCE(i.qty, 0) > 0
                                ORDER BY COALESCE(i.plan_begin_date,
                                                  p.delivery_date) NULLS LAST,
                                         COALESCE(i.line_no, 0), i.id,
                                         b.sort_order, b.id
                                """ + lockClause)
                        .setParameter("planId", planId));
        long sourceCount = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_plan_items
                        WHERE plan_id = :planId
                          AND is_deleted = FALSE
                          AND COALESCE(qty, 0) > 0
                        """)
                .setParameter("planId", planId)
                .getSingleResult()).longValue();
        if (sourceCount == 0 || rows.isEmpty()) {
            throw conflict("生产计划没有可排产的成品行或有效 BOM");
        }

        Map<UUID, LineAccumulator> lines = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID sourceItemId = (UUID) row[0];
            UUID componentGoodsId = (UUID) row[14];
            UUID componentUnitId = (UUID) row[16];
            BigDecimal productRate = decimal(row[5]);
            BigDecimal bomQty = decimal(row[17]);
            if (productRate.signum() <= 0
                    || decimal(row[6]).signum() <= 0
                    || bomQty.signum() <= 0
                    || componentUnitId == null
                    || (row[18] != null && row[15] == null)) {
                throw conflict("BOM、颜色或基本单位数据不完整，禁止生成执行分段");
            }
            String componentSourceType =
                    normalizeSourceType((String) row[22]);
            String authoritativeRoute = supportedSupplyRoute(componentSourceType);
            if (Boolean.TRUE.equals(row[19])) {
                throw conflict(
                        "执行分段暂不支持多层 BOM；请先建立独立半成品生产计划");
            }
            BigDecimal perProduct = productRate.multiply(bomQty)
                    .setScale(CompleteKitAllocator.USAGE_SCALE, RoundingMode.CEILING);
            CompleteKitAllocator.MaterialKey key =
                    new CompleteKitAllocator.MaterialKey(
                            componentGoodsId, (UUID) row[15]);
            String route = routes.getOrDefault(
                    key, authoritativeRoute);
            if (!ProductionMaterialDemand.ROUTE_BUY.equals(route)
                    && !ProductionMaterialDemand.ROUTE_SUBCONTRACT.equals(route)) {
                throw conflict(
                        "当前执行分段只支持可追溯采购路线；委外和自制路线尚未接通，禁止提交");
            }
            LineAccumulator line = lines.computeIfAbsent(
                    sourceItemId,
                    ignored -> new LineAccumulator(row));
            line.add(
                    new CompleteKitAllocator.MaterialUsage(
                            componentGoodsId,
                            (UUID) row[15],
                            componentUnitId,
                            perProduct,
                            route),
                    String.join("|",
                            Objects.toString(row[13], ""),
                            componentGoodsId.toString(),
                            Objects.toString(row[15], ""),
                            componentUnitId.toString(),
                            decimalText(perProduct),
                            componentSourceType,
                            Objects.toString(row[21], "")));
        }
        if (lines.size() != sourceCount) {
            throw conflict("至少一个生产计划行没有有效 BOM，禁止部分生成执行分段");
        }
        List<CompleteKitAllocator.ProductLine> productLines = lines.values()
                .stream()
                .map(LineAccumulator::toProductLine)
                .toList();
        Map<CompleteKitAllocator.MaterialKey, BigDecimal> availability =
                warehouseAvailability(warehouseId, productLines);

        List<String> fingerprintParts = new ArrayList<>();
        fingerprintParts.add("EXECUTION-SEGMENT-V1");
        fingerprintParts.add("PLAN|" + planId);
        fingerprintParts.add("WAREHOUSE|" + warehouseId);
        for (CompleteKitAllocator.ProductLine line : productLines) {
            fingerprintParts.add(String.join("|",
                    "LINE",
                    line.sourcePlanItemId().toString(),
                    Objects.toString(line.lineNo(), ""),
                    line.productGoodsId().toString(),
                    Objects.toString(line.productColorId(), ""),
                    line.productUnitId().toString(),
                    decimalText(line.productUnitRate()),
                    decimalText(line.plannedQty()),
                    Objects.toString(line.planBeginDate(), ""),
                    Objects.toString(line.planEndDate(), ""),
                    line.bomFingerprint()));
        }
        availability.forEach((key, value) -> fingerprintParts.add(String.join("|",
                "AVAILABLE",
                key.goodsId().toString(),
                Objects.toString(key.colorId(), ""),
                decimalText(value))));
        return new Snapshot(
                planId,
                warehouseId,
                PlanningPackageFingerprint.sha256(fingerprintParts),
                List.copyOf(productLines),
                Map.copyOf(availability));
    }

    private Map<CompleteKitAllocator.MaterialKey, BigDecimal>
            warehouseAvailability(
                    UUID warehouseId,
                    List<CompleteKitAllocator.ProductLine> lines) {
        List<UUID> goodsIds = lines.stream()
                .flatMap(line -> line.materials().stream())
                .map(CompleteKitAllocator.MaterialUsage::goodsId)
                .distinct()
                .sorted()
                .toList();
        List<Object[]> values = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.goods_id, a.color_id,
                                       GREATEST(
                                           a.available_qty
                                           - GREATEST(COALESCE(g.min_qty, 0), 0),
                                           0
                                       )
                                FROM v_stock_available a
                                JOIN goods g ON g.id = a.goods_id
                                WHERE a.warehouse_id = :warehouseId
                                  AND a.goods_id IN (:goodsIds)
                                ORDER BY a.goods_id, a.color_id NULLS FIRST
                                """)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("goodsIds", goodsIds));
        Map<CompleteKitAllocator.MaterialKey, BigDecimal> result =
                new LinkedHashMap<>();
        for (Object[] row : values) {
            result.put(
                    new CompleteKitAllocator.MaterialKey(
                            (UUID) row[0], (UUID) row[1]),
                    decimal(row[2]).setScale(
                            CompleteKitAllocator.MATERIAL_SCALE,
                            RoundingMode.DOWN));
        }
        lines.stream().flatMap(line -> line.materials().stream())
                .map(CompleteKitAllocator.MaterialUsage::materialKey)
                .forEach(key -> result.putIfAbsent(key, BigDecimal.ZERO.setScale(4)));
        return result;
    }

    private static CompleteKitAllocator.ProductLine withAssignments(
            CompleteKitAllocator.ProductLine line,
            GeneratePlanningPackageRequest.ExecutionSegment edit) {
        return new CompleteKitAllocator.ProductLine(
                line.sourcePlanItemId(),
                line.lineNo(),
                line.productGoodsId(),
                line.productColorId(),
                line.productUnitId(),
                line.productUnitRate(),
                line.plannedQty(),
                edit.getPlanBeginDate(),
                edit.getPlanEndDate(),
                edit.getWorkshopDepartmentId(),
                edit.getTeamDepartmentId(),
                edit.getResponsibleEmployeeId(),
                line.productCode(),
                line.productName(),
                line.priority(),
                line.materials(),
                line.bomFingerprint());
    }

    private static BigDecimal scaleProduct(BigDecimal value) {
        if (value == null || value.signum() <= 0) {
            throw validation("执行分段数量必须大于零");
        }
        try {
            return value.setScale(
                    CompleteKitAllocator.PRODUCT_SCALE,
                    RoundingMode.UNNECESSARY);
        } catch (ArithmeticException ex) {
            throw validation("执行分段数量最多保留四位小数");
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static String decimalText(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        return ((java.sql.Date) value).toLocalDate();
    }

    static String supportedSupplyRoute(String rawSourceType) {
        String sourceType = normalizeSourceType(rawSourceType);
        if (GOODS_SOURCE_PURCHASE.equals(sourceType)) {
            return ProductionMaterialDemand.ROUTE_BUY;
        }
        if (GOODS_SOURCE_SELF_MADE.equals(sourceType)) {
            throw conflict(
                    "Self-made material supply is not supported by execution planning");
        }
        if (GOODS_SOURCE_SUBCONTRACT.equals(sourceType)) {
            return ProductionMaterialDemand.ROUTE_SUBCONTRACT;
        }
        throw conflict(
                "Material source_type must explicitly be purchase or subcontract");
    }

    private static String normalizeSourceType(String rawSourceType) {
        return rawSourceType == null ? "" : rawSourceType.strip();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    public record Snapshot(
            UUID planId,
            UUID warehouseId,
            String fingerprint,
            List<CompleteKitAllocator.ProductLine> productLines,
            Map<CompleteKitAllocator.MaterialKey, BigDecimal> availability) {
    }

    private static final class LineAccumulator {
        private final Object[] row;
        private final Map<CompleteKitAllocator.MaterialKey,
                CompleteKitAllocator.MaterialUsage> materials =
                new LinkedHashMap<>();
        private final List<String> bomParts = new ArrayList<>();

        private LineAccumulator(Object[] row) {
            this.row = row;
            bomParts.add("SOURCE|" + row[0] + "|" + Objects.toString(row[20], ""));
        }

        private void add(
                CompleteKitAllocator.MaterialUsage material,
                String fingerprintPart) {
            CompleteKitAllocator.MaterialKey key =
                    material.materialKey();
            CompleteKitAllocator.MaterialUsage existing =
                    materials.get(key);
            if (existing == null) {
                materials.put(key, material);
            } else {
                if (!Objects.equals(
                                existing.unitId(), material.unitId())
                        || !Objects.equals(
                                existing.supplyRoute(),
                                material.supplyRoute())) {
                    throw conflict(
                            "同一物料颜色维度的 BOM 行必须使用相同基本单位和供给路线");
                }
                materials.put(key, new CompleteKitAllocator.MaterialUsage(
                        material.goodsId(),
                        material.colorId(),
                        material.unitId(),
                        existing.perProductQty()
                                .add(material.perProductQty()),
                        material.supplyRoute()));
            }
            bomParts.add(fingerprintPart);
        }

        private CompleteKitAllocator.ProductLine toProductLine() {
            UUID sourceItemId = (UUID) row[0];
            int lineNo = ((Number) row[1]).intValue();
            LocalDate begin = date(row[7]);
            return new CompleteKitAllocator.ProductLine(
                    sourceItemId,
                    lineNo,
                    (UUID) row[2],
                    (UUID) row[3],
                    (UUID) row[4],
                    decimal(row[5]).setScale(6, RoundingMode.UNNECESSARY),
                    decimal(row[6]).setScale(4, RoundingMode.UNNECESSARY),
                    begin,
                    date(row[8]),
                    (UUID) row[9],
                    null,
                    (UUID) row[10],
                    (String) row[11],
                    (String) row[12],
                    new CompleteKitAllocator.Priority(begin, lineNo, sourceItemId),
                    List.copyOf(materials.values()),
                    PlanningPackageFingerprint.sha256(bomParts));
        }
    }
}
