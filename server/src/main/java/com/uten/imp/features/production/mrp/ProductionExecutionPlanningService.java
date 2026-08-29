package com.uten.imp.features.production.mrp;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
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
    private static final Set<String> SUPPORTED_CONTROL_STAGES = Set.of(
            "START", "ASSEMBLY", "FINISH", "SHIP", "REFERENCE");
    private static final Set<String> PRODUCTION_CONTROL_STAGES = Set.of(
            "START", "ASSEMBLY", "FINISH");
    private static final Set<String> SUPPORTED_CONSUMPTION_BASES = Set.of(
            "PER_UNIT", "PER_PACKAGE", "FIXED_BATCH");
    private static final String CONSUMPTION_BASIS_PER_UNIT = "PER_UNIT";

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

    /**
     * 将客户端自定义分段叠加到快照上做齐套分配：每个来源计划行的分段数量合计须严格等于原计划数量，
     * 分段 BOM 指纹须未变；READY 段必须有完整齐套，仅 WAITING 段可设为暂缓放行。
     */
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
            if (edit.isDeferUntilManualRelease()
                    && !"WAITING".equals(edit.getRequestedStatus())) {
                throw validation(
                        "只有「等待」状态的执行分段才能设置为暂缓放行");
            }
            BigDecimal qty = scaleProduct(edit.getPlannedQty());
            totals.merge(line.sourcePlanItemId(), qty, BigDecimal::add);
            CompleteKitAllocator.ProductLine editedLine =
                    withAssignments(line, edit);
            edits.add(new CompleteKitAllocator.RequestedSegment(
                    edit.getClientSegmentKey().strip(),
                    editedLine,
                    edit.getRequestedStatus(),
                    qty,
                    edit.isDeferUntilManualRelease()));
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
        Map<UUID, String> productSpecs = productSpecs(allocation);
        return allocation.segments().stream()
                .map(segment -> new ExecutionSegmentPreview(
                        segment.clientSegmentKey(),
                        segment.line().sourcePlanItemId(),
                        segment.line().lineNo(),
                        segment.line().productGoodsId(),
                        segment.line().productCode(),
                        segment.line().productName(),
                        productSpecs.get(segment.line().productGoodsId()),
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
                        segment.materials().isEmpty()
                                ? ProductionExecutionSegment
                                        .MATERIAL_REQUIREMENT_MODE_ZERO
                                : ProductionExecutionSegment
                                        .MATERIAL_REQUIREMENT_MODE_DEMANDED,
                        segment.line().zeroMaterialReason(),
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
                                        material.supplyRoute(),
                                        material.requirementMode()))
                                .toList()))
                .toList();
    }

    private Map<UUID, String> productSpecs(
            CompleteKitAllocator.Allocation allocation) {
        List<UUID> goodsIds = allocation.segments().stream()
                .map(segment -> segment.line().productGoodsId())
                .distinct()
                .sorted()
                .toList();
        if (goodsIds.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, spec
                                FROM goods
                                WHERE id IN (:goodsIds)
                                  AND is_deleted = FALSE
                                ORDER BY id
                                """)
                        .setParameter("goodsIds", goodsIds));
        Map<UUID, String> result = new HashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], (String) row[1]);
        }
        return result;
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
                                       CASE
                                           WHEN preferred_workshop_parent.id IS NOT NULL
                                           THEN workshop_preference.workshop_department_id
                                           WHEN plan_workshop_parent.id IS NOT NULL
                                           THEN p.department_id
                                           ELSE NULL
                                       END,
                                       p.worker_id,
                                       product.code,
                                       product.name,
                                       b.id,
                                       b.component_goods_id,
                                       resolved_color.id,
                                       component_unit.id,
                                       b.qty,
                                       ((COALESCE(b.color_id, component.color_id) IS NOT NULL
                                         AND resolved_color.id IS NULL)
                                        OR (b.color_id IS NULL
                                            AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                                        OR (component.color_id IS NULL
                                            AND NULLIF(component.color_legacy_id, 0) IS NOT NULL))
                                           AS color_reference_invalid,
                                       EXISTS (
                                           SELECT 1
                                           FROM goods_bom_items child
                                           WHERE child.goods_id =
                                                 b.component_goods_id
                                             AND child.is_deleted = FALSE
                                       ) AS component_has_bom,
                                       i.updated_at,
                                       b.updated_at,
                                       component.source_type,
                                       analysis_material.confirmed_route,
                                       b.control_stage,
                                       b.hard_gate,
                                       b.consumption_basis,
                                       b.basis_output_qty,
                                       b.allow_partial_package
                                FROM production_plan_items i
                                JOIN production_plans p
                                  ON p.id = i.plan_id
                                 AND p.is_deleted = FALSE
                                JOIN goods product
                                  ON product.id = i.goods_id
                                 AND product.is_deleted = FALSE
                                 LEFT JOIN production_goods_workshop_preferences
                                      workshop_preference
                                   ON workshop_preference.goods_id = product.id
                                 LEFT JOIN departments preferred_workshop
                                   ON preferred_workshop.id =
                                      workshop_preference.workshop_department_id
                                  AND preferred_workshop.is_deleted = FALSE
                                 LEFT JOIN departments preferred_workshop_parent
                                   ON preferred_workshop_parent.id =
                                      preferred_workshop.parent_id
                                  AND preferred_workshop_parent.code = 'DEPT_PROD'
                                  AND preferred_workshop_parent.is_deleted = FALSE
                                 LEFT JOIN departments plan_workshop
                                   ON plan_workshop.id = p.department_id
                                  AND plan_workshop.is_deleted = FALSE
                                 LEFT JOIN departments plan_workshop_parent
                                   ON plan_workshop_parent.id =
                                      plan_workshop.parent_id
                                  AND plan_workshop_parent.code = 'DEPT_PROD'
                                  AND plan_workshop_parent.is_deleted = FALSE
                                JOIN units product_unit
                                  ON product_unit.id = i.unit_id
                                 AND product_unit.is_deleted = FALSE
                                JOIN goods_bom_items b
                                  ON b.goods_id = i.goods_id
                                 AND b.is_deleted = FALSE
                                LEFT JOIN production_material_analysis_materials
                                      analysis_material
                                  ON analysis_material.analysis_id = p.material_analysis_id
                                 AND analysis_material.analysis_item_id =
                                     p.material_analysis_item_id
                                 AND analysis_material.bom_item_id = b.id
                                 AND analysis_material.depth = 1
                                 AND analysis_material.active = TRUE
                                JOIN goods component
                                  ON component.id = b.component_goods_id
                                 AND component.is_deleted = FALSE
                                 LEFT JOIN colors resolved_color
                                   ON resolved_color.id = COALESCE(
                                          b.color_id, component.color_id)
                                  AND resolved_color.is_deleted = FALSE
                                 LEFT JOIN units component_unit
                                   ON component_unit.id = component.unit_id
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
        @SuppressWarnings("unchecked")
        List<UUID> allSourceItemIds = ((List<UUID>) em.createNativeQuery("""
                        SELECT id
                        FROM production_plan_items
                        WHERE plan_id = :planId
                          AND is_deleted = FALSE
                          AND COALESCE(qty, 0) > 0
                        """)
                .setParameter("planId", planId)
                .getResultList());
        if (allSourceItemIds.isEmpty()) {
            throw conflict("生产计划没有数量大于零的可排产成品行");
        }

        Map<UUID, LineAccumulator> lines = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID sourceItemId = (UUID) row[0];
            BigDecimal productRate = decimal(row[5]);
            BigDecimal plannedQty = decimal(row[6]);
            if (productRate.signum() <= 0 || plannedQty.signum() <= 0) {
                throw conflict("生产计划行缺少有效单位换算率或数量，禁止生成执行分段");
            }
            LineAccumulator line = lines.computeIfAbsent(
                    sourceItemId,
                    ignored -> new LineAccumulator(row));

            String controlStage = requiredBomEnum(
                    row[24], SUPPORTED_CONTROL_STAGES,
                    "BOM 管控阶段配置无效，禁止生成执行分段");
            boolean hardGate = requiredBomBoolean(row[25]);
            String consumptionBasis = requiredBomEnum(
                    row[26], SUPPORTED_CONSUMPTION_BASES,
                    "BOM 消耗计量配置无效，禁止生成执行分段");
            BigDecimal basisOutputQty = decimal(row[27]);
            if (basisOutputQty.signum() <= 0) {
                throw conflict("BOM 计量基数必须大于零，禁止生成执行分段");
            }
            boolean allowPartialPackage = requiredBomBoolean(row[28]);
            BigDecimal bomQty = decimal(row[17]);
            String componentSourceType =
                    normalizeSourceType((String) row[22]);
            String analysisRoute = row[23] == null ? null
                    : row[23].toString().strip().toUpperCase(java.util.Locale.ROOT);
            UUID componentGoodsId = (UUID) row[14];
            UUID componentUnitId = (UUID) row[16];
            if (componentUnitId == null || Boolean.TRUE.equals(row[18])) {
                throw conflict("BOM、颜色或基本单位数据不完整，禁止生成执行分段");
            }
            line.recordBomPart(String.join("|",
                    "BOM",
                    Objects.toString(row[13], ""),
                    Objects.toString(row[14], ""),
                    Objects.toString(row[15], ""),
                    Objects.toString(row[16], ""),
                    decimalText(bomQty),
                    componentSourceType,
                    Objects.toString(row[21], ""),
                    Objects.toString(analysisRoute, ""),
                    controlStage,
                    Boolean.toString(hardGate),
                    consumptionBasis,
                    decimalText(basisOutputQty),
                    Boolean.toString(allowPartialPackage)));

            boolean productionHardGate = hardGate
                    && PRODUCTION_CONTROL_STAGES.contains(controlStage);
            if (!productionHardGate) {
                // 发货包装、参考行和非硬门槛物料不是正式生产齐套或领料需求。
                // 该 BOM 行仍已进入指纹，且 LineAccumulator 保留合法零物料成品行。
                continue;
            }
            if (bomQty.signum() <= 0) {
                throw conflict("BOM、颜色或基本单位数据不完整，禁止生成执行分段");
            }
            String authoritativeRoute = analysisRoute == null
                    ? supportedSupplyRoute(componentSourceType) : analysisRoute;
            // 自制/多层 BOM 组件不再拒绝：route=MAKE 时参与齐套（消耗半成品现货），
            // 缺口由自制件派生内核生成子生产计划供给。
            BigDecimal perProduct = productRate.multiply(bomQty)
                    .divide(
                            CONSUMPTION_BASIS_PER_UNIT.equals(consumptionBasis)
                                    ? BigDecimal.ONE : basisOutputQty,
                            12,
                            RoundingMode.CEILING)
                    .setScale(CompleteKitAllocator.USAGE_SCALE, RoundingMode.CEILING);
            CompleteKitAllocator.MaterialKey key =
                    new CompleteKitAllocator.MaterialKey(
                            componentGoodsId, (UUID) row[15]);
            String route = routes.getOrDefault(
                    key, authoritativeRoute);
            if (!ProductionMaterialDemand.ROUTE_BUY.equals(route)
                    && !ProductionMaterialDemand.ROUTE_SUBCONTRACT.equals(route)
                    && !ProductionMaterialDemand.ROUTE_MAKE.equals(route)) {
                throw conflict(
                        "执行分段物料路线必须为采购、委外或自制");
            }
            line.add(
                    new CompleteKitAllocator.MaterialUsage(
                            componentGoodsId,
                            (UUID) row[15],
                            componentUnitId,
                            perProduct,
                            route,
                            List.of(new CompleteKitAllocator.ConsumptionRule(
                                    consumptionBasis,
                                    bomQty,
                                    basisOutputQty,
                                    allowPartialPackage))));
        }
        // 收集所有未维护 BOM 的正数量成品行；即使全部缺 BOM，也返回快照供前端精确提示。
        // 正式保存草案/审核下达由共享校验器 fail-closed，禁止形成不完整排产方案。
        List<UUID> rawNoBomPlanItemIds = allSourceItemIds.stream()
                .filter(id -> !lines.containsKey(id))
                .toList();
        List<CompleteKitAllocator.ProductLine> zeroMaterialLines =
                authorizedZeroMaterialLines(planId, rawNoBomPlanItemIds, lock);
        Set<UUID> authorizedZeroIds = zeroMaterialLines.stream()
                .map(CompleteKitAllocator.ProductLine::sourcePlanItemId)
                .collect(java.util.stream.Collectors.toSet());
        List<UUID> noBomPlanItemIds = rawNoBomPlanItemIds.stream()
                .filter(id -> !authorizedZeroIds.contains(id)).toList();
        List<CompleteKitAllocator.ProductLine> productLines = new ArrayList<>();
        lines.values().stream().map(LineAccumulator::toProductLine)
                .forEach(productLines::add);
        productLines.addAll(zeroMaterialLines);
        Map<CompleteKitAllocator.MaterialKey, BigDecimal> availability =
                warehouseAvailability(planId, warehouseId, productLines);

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
                Map.copyOf(availability),
                List.copyOf(noBomPlanItemIds));
    }

    private List<CompleteKitAllocator.ProductLine> authorizedZeroMaterialLines(
            UUID planId, List<UUID> noBomPlanItemIds, boolean lock) {
        if (noBomPlanItemIds.isEmpty()) return List.of();
        String lockClause = lock ? " FOR UPDATE OF i" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.id, COALESCE(i.line_no,0), i.goods_id, i.color_id,
                       i.unit_id, COALESCE(i.unit_rate,1), i.qty,
                       i.plan_begin_date, i.plan_end_date, p.worker_id,
                       g.code, g.name, i.updated_at,
                       p.material_analysis_id
                FROM production_plan_items i
                JOIN production_plans p ON p.id = i.plan_id
                                       AND p.is_deleted = FALSE
                JOIN goods g ON g.id = i.goods_id AND g.is_deleted = FALSE
                WHERE i.plan_id = :planId AND i.id IN (:ids)
                  AND i.is_deleted = FALSE AND COALESCE(i.qty,0) > 0
                ORDER BY COALESCE(i.plan_begin_date,p.delivery_date) NULLS LAST,
                         COALESCE(i.line_no,0), i.id
                """ + lockClause)
                .setParameter("planId", planId)
                .setParameter("ids", noBomPlanItemIds));
        List<CompleteKitAllocator.ProductLine> result = new ArrayList<>();
        for (Object[] row : rows) {
            if (row[13] == null) {
                continue; // legacy/history remains visible as unresolved no-BOM.
            }
            UUID itemId = (UUID) row[0];
            BigDecimal unitRate = decimal(row[5]);
            BigDecimal plannedQty = decimal(row[6]);
            if (row[4] == null || unitRate.signum() <= 0 || plannedQty.signum() <= 0) {
                throw conflict("无物料生产行缺少有效单位、换算率或数量");
            }
            LocalDate begin = date(row[7]);
            String fingerprint = PlanningPackageFingerprint.sha256(List.of(
                    "ZERO-MATERIAL-PRODUCT-V1", itemId.toString(), row[2].toString(),
                    Objects.toString(row[3], ""), row[4].toString(),
                    decimalText(unitRate), decimalText(plannedQty),
                    Objects.toString(row[13], ""),
                    Objects.toString(row[12], "")));
            result.add(new CompleteKitAllocator.ProductLine(
                    itemId, ((Number) row[1]).intValue(), (UUID) row[2], (UUID) row[3],
                    (UUID) row[4], unitRate.setScale(6, RoundingMode.UNNECESSARY),
                    plannedQty.setScale(4, RoundingMode.UNNECESSARY), begin, date(row[8]),
                    null, null, (UUID) row[9], Objects.toString(row[10], null),
                    Objects.toString(row[11], null),
                    new CompleteKitAllocator.Priority(
                            begin, ((Number) row[1]).intValue(), itemId),
                    List.of(), fingerprint,
                    ProductionExecutionSegment.ZERO_MATERIAL_REASON_DIRECT_MAKE,
                    (UUID) row[13],
                    null,
                    null));
        }
        return List.copyOf(result);
    }

    private Map<CompleteKitAllocator.MaterialKey, BigDecimal>
            warehouseAvailability(
                    UUID planId,
                    UUID warehouseId,
                    List<CompleteKitAllocator.ProductLine> lines) {
        if (lines.isEmpty()) {
            return Map.of();
        }
        List<UUID> goodsIds = lines.stream()
                .flatMap(line -> line.materials().stream())
                .map(CompleteKitAllocator.MaterialUsage::goodsId)
                .distinct()
                .sorted()
                .toList();
        if (goodsIds.isEmpty()) {
            return Map.of();
        }
        // V309：按当前 beneficiary entitlement 只还原到本计划 analysis item；
        // 历史 V298 无事件行仍按 owner 分析级池兼容。
        List<Object[]> analysisIdentity = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT material_analysis_id, material_analysis_item_id
                        FROM production_plans
                        WHERE id = :planId AND is_deleted = FALSE
                          AND material_analysis_id IS NOT NULL
                        """).setParameter("planId", planId));
        UUID analysisId = analysisIdentity.isEmpty()
                ? null : (UUID) analysisIdentity.getFirst()[0];
        UUID analysisItemId = analysisIdentity.isEmpty()
                ? null : (UUID) analysisIdentity.getFirst()[1];
        List<Object[]> values = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.goods_id, a.color_id,
                                       GREATEST(
                                           a.available_qty + COALESCE(own.own_qty, 0)
                                           - GREATEST(COALESCE(g.min_qty, 0), 0),
                                           0
                                       )
                                FROM v_stock_available a
                                JOIN goods g ON g.id = a.goods_id
                                LEFT JOIN LATERAL (
                                    SELECT SUM(CASE
                                        WHEN EXISTS (
                                            SELECT 1
                                            FROM preplan_stock_entitlement_events tracked
                                            WHERE tracked.stock_reservation_id = r.id
                                        ) THEN COALESCE((
                                            SELECT SUM(balance.effective_qty)
                                            FROM v_preplan_stock_entitlement_beneficiary_balance
                                                 balance
                                            JOIN production_material_analysis_materials
                                                 beneficiary
                                              ON beneficiary.id =
                                                 balance.beneficiary_analysis_material_id
                                             AND beneficiary.analysis_id =
                                                 balance.beneficiary_analysis_id
                                            WHERE balance.stock_reservation_id = r.id
                                              AND balance.beneficiary_analysis_id =
                                                  :analysisId
                                              AND beneficiary.analysis_item_id =
                                                  :analysisItemId
                                              AND beneficiary.active = TRUE
                                        ), 0)
                                        WHEN r.owner_id = :analysisId
                                        THEN r.qty - r.consumed_qty - r.released_qty
                                        ELSE 0
                                    END) AS own_qty
                                    FROM stock_reservations r
                                    WHERE r.is_deleted = FALSE
                                      AND r.status = 0
                                      AND r.owner_type = 'PREPLAN_ANALYSIS'
                                      AND r.warehouse_id = a.warehouse_id
                                      AND r.goods_id = a.goods_id
                                      AND r.color_id IS NOT DISTINCT FROM a.color_id
                                ) own ON TRUE
                                WHERE a.warehouse_id = :warehouseId
                                  AND a.goods_id IN (:goodsIds)
                                ORDER BY a.goods_id, a.color_id NULLS FIRST
                                """)
                        .setParameter("analysisId", analysisId)
                        .setParameter("analysisItemId", analysisItemId)
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
                line.bomFingerprint(),
                line.zeroMaterialReason(),
                line.zeroMaterialAnalysisId(),
                line.zeroMaterialExceptionReason(),
                line.zeroMaterialAuthorizedBy());
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
            // 自制件标记 MAKE 路线：参与齐套判定时可消耗半成品现货库存，
            // 缺口不生成采购/委外，由自制件派生内核（子生产计划）供给。
            return ProductionMaterialDemand.ROUTE_MAKE;
        }
        if (GOODS_SOURCE_SUBCONTRACT.equals(sourceType)) {
            return ProductionMaterialDemand.ROUTE_SUBCONTRACT;
        }
        throw conflict(
                "物料来源必须明确为「采购」「自制」或「委外」，请到货品资料中维护该货品的来源后再试");
    }

    private static String normalizeSourceType(String rawSourceType) {
        return rawSourceType == null ? "" : rawSourceType.strip();
    }

    private static String requiredBomEnum(
            Object rawValue, Set<String> allowed, String errorMessage) {
        if (rawValue == null) {
            throw conflict(errorMessage);
        }
        String value = rawValue.toString().strip()
                .toUpperCase(java.util.Locale.ROOT);
        if (!allowed.contains(value)) {
            throw conflict(errorMessage);
        }
        return value;
    }

    private static boolean requiredBomBoolean(Object rawValue) {
        if (!(rawValue instanceof Boolean value)) {
            throw conflict("BOM 管控配置不完整，禁止生成执行分段");
        }
        return value;
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
            Map<CompleteKitAllocator.MaterialKey, BigDecimal> availability,
            List<UUID> noBomPlanItemIds) {
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

        private void recordBomPart(String fingerprintPart) {
            bomParts.add(fingerprintPart);
        }

        private void add(CompleteKitAllocator.MaterialUsage material) {
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
                        material.supplyRoute(),
                        java.util.stream.Stream.concat(
                                        existing.consumptionRules().stream(),
                                        material.consumptionRules().stream())
                                .toList()));
            }
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
                    PlanningPackageFingerprint.sha256(bomParts),
                    materials.isEmpty()
                            ? ProductionExecutionSegment
                                    .ZERO_MATERIAL_REASON_NO_PRODUCTION_HARD_GATE
                            : null);
        }
    }
}
