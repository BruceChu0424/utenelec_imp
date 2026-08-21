package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 计划前物料分析备料库存绑定（V298）。
 *
 * <p>收货 IQC 合格入库 / 自制成品入库时，把入库量按来源单据链溯源到物料分析，
 * 写 {@code owner_type='PREPLAN_ANALYSIS'} 软预留（供应锚点 = 采购申请行 /
 * 委外申请行 / 生产计划行）。统一可用量口径自动对其它分析、销售和 MRP 隐藏这批料；
 * 归属分析自己的可用量由 {@link MaterialAnalysisService} 加回。
 *
 * <p>对称反向：收货红冲按来源单据释放；分析取消/任务撤回按归属释放；
 * 计划包确认时按需求维度转移（释放回池，需求分配器同事务再为 demand 建行）。
 */
@Service
@RequiredArgsConstructor
public class PreplanAnalysisStockPegService implements PreplanAnalysisPegPort {

    public static final String OWNER_TYPE = "PREPLAN_ANALYSIS";
    public static final String PURPOSE = "PREPLAN_MATERIAL";
    /** stock_reservations.source：0下单现货 / 1生产入库 / 2计划包物料 / 3分析备料。 */
    public static final short SOURCE_PREPLAN_ANALYSIS = 3;

    private static final short STATUS_EFFECTIVE = 0;
    private static final short STATUS_DONE = 1;

    private static final String SUPPLY_PURCHASE_REQUEST_ITEM = "PURCHASE_REQUEST_ITEM";
    private static final String SUPPLY_SUBCONTRACT_APPLICATION_ITEM =
            "SUBCONTRACT_APPLICATION_ITEM";
    private static final String SUPPLY_PRODUCTION_PLAN_ITEM = "PRODUCTION_PLAN_ITEM";

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final InventoryMutationLock inventoryLock;

    // ============================ 收货入库绑定 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void attributeInspectionPass(
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID dispositionEventId,
            BigDecimal passedBaseQty,
            UUID warehouseId) {
        tx.bind();
        if (passedBaseQty == null || passedBaseQty.signum() <= 0
                || inspectionItemId == null || warehouseId == null) {
            return;
        }
        boolean purchase = "PURCHASE".equals(receiptType);
        if (!purchase && !"SUBCONTRACT".equals(receiptType)) {
            return;
        }
        // 待检行 → 收货行 → 订货行 → 来源申请/委外申请明细（外部锚点）。
        List<Object[]> anchors = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT inspection.goods_id, inspection.color_id,
                               order_item.id, order_item.%s
                        FROM procurement_inspection_items inspection
                        JOIN %s receipt_item
                          ON receipt_item.id = inspection.receipt_item_id
                         AND receipt_item.is_deleted = FALSE
                        JOIN %s order_item
                          ON order_item.id = receipt_item.order_item_id
                         AND order_item.is_deleted = FALSE
                        WHERE inspection.id = :inspectionItemId
                          AND inspection.receipt_type = :receiptType
                          AND inspection.receipt_id = :receiptId
                        """.formatted(
                        purchase ? "request_item_id" : "application_item_id",
                        purchase ? "purchase_receipt_items" : "subcontract_receipt_items",
                        purchase ? "purchase_order_items" : "subcontract_order_items"))
                .setParameter("inspectionItemId", inspectionItemId)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId));
        if (anchors.isEmpty()) {
            return; // 无订货来源的行（不应存在：到货控制已强制逐行关联订货明细）
        }
        UUID goodsId = (UUID) anchors.getFirst()[0];
        UUID colorId = (UUID) anchors.getFirst()[1];
        UUID externalItemId = (UUID) anchors.getFirst()[3];
        if (externalItemId == null) {
            return; // 订货行无申请来源（历史/手工），不参与分析绑定
        }
        inventoryLock.lock(new InventoryKey(goodsId, colorId));
        String supplyType = purchase
                ? SUPPLY_PURCHASE_REQUEST_ITEM
                : SUPPLY_SUBCONTRACT_APPLICATION_ITEM;
        lockClaimantAnalyses(externalItemId, goodsId, colorId);

        // 精确归属候选：按供应行动分摊行（analysis_material_id）逐行锁定容量。
        // V307 之前只有 analysis_id 粒度；现在每次 PASS 建一条物理预留及其
        // 一对一 exact-peg 子账，避免同分析内相同物料的兄弟产品抢占。
        jakarta.persistence.Query claimantQuery = em.createNativeQuery("""
                        SELECT allocation.id, allocation.analysis_id,
                               allocation.analysis_material_id,
                               allocation.allocated_qty
                        FROM preplan_supply_action_allocations allocation
                        JOIN preplan_supply_actions action
                          ON action.id = allocation.action_id
                         AND action.status <> 'CANCELLED'
                        JOIN production_material_analyses analysis
                          ON analysis.id = allocation.analysis_id
                         AND analysis.is_deleted = FALSE
                         AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                        JOIN production_material_analysis_materials material
                          ON material.id = allocation.analysis_material_id
                         AND material.analysis_id = allocation.analysis_id
                         AND material.active = TRUE
                        WHERE allocation.external_item_id = :externalItemId
                          AND material.goods_id = :goodsId
                          AND material.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                        ORDER BY allocation.analysis_id,
                                 allocation.created_at, allocation.id
                        FOR UPDATE OF action, allocation
                        """)
                .setParameter("externalItemId", externalItemId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId);
        List<Object[]> claimants = NativeQueryResults.objectArrayRows(claimantQuery);

        BigDecimal remaining = passedBaseQty;
        Map<UUID, BigDecimal> legacyRemainingByAnalysis = new LinkedHashMap<>();
        for (Object[] claimant : claimants) {
            if (remaining.signum() <= 0) {
                break;
            }
            UUID allocationId = (UUID) claimant[0];
            UUID analysisId = (UUID) claimant[1];
            UUID analysisMaterialId = (UUID) claimant[2];
            BigDecimal allocatedCap = decimal(claimant[3]);
            BigDecimal exactAttributed = decimal(em.createNativeQuery("""
                            SELECT COALESCE(SUM(CASE
                                WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                                THEN peg.qty
                                ELSE reservation.qty - reservation.consumed_qty
                                    - reservation.released_qty
                            END), 0)
                            FROM preplan_analysis_stock_exact_pegs peg
                            JOIN stock_reservations reservation
                              ON reservation.id = peg.stock_reservation_id
                            WHERE peg.supply_action_allocation_id = :allocationId
                              AND reservation.is_deleted = FALSE
                              AND (reservation.status = :effective
                                   OR reservation.release_reason = 'TRANSFERRED_TO_PLAN')
                            """)
                    .setParameter("allocationId", allocationId)
                    .setParameter("effective", STATUS_EFFECTIVE)
                    .getSingleResult());
            // 历史 V298 预留没有 exact 子账。它们仍保留分析级池语义，但必须
            // 先按稳定顺序占用该分析的分摊容量，避免升级后重复绑定超量。
            BigDecimal legacyRemaining = legacyRemainingByAnalysis.computeIfAbsent(
                    analysisId, ignored -> legacyAttributed(
                            analysisId, supplyType, externalItemId));
            BigDecimal capacityAfterExact = allocatedCap.subtract(exactAttributed)
                    .max(BigDecimal.ZERO);
            BigDecimal legacyUse = capacityAfterExact.min(legacyRemaining);
            legacyRemainingByAnalysis.put(
                    analysisId, legacyRemaining.subtract(legacyUse));
            BigDecimal headroom = capacityAfterExact.subtract(legacyUse);
            BigDecimal take = remaining.min(headroom.max(BigDecimal.ZERO));
            if (take.signum() <= 0) {
                continue;
            }
            insertExactReservation(
                    allocationId, analysisId, analysisMaterialId,
                    warehouseId, goodsId, colorId, take,
                    supplyType, externalItemId, receiptType, receiptId,
                    dispositionEventId);
            remaining = remaining.subtract(take);
        }
        // 超出分析分摊量的部分（含财务特批超收）不绑定，按公共现货处理。
    }

    // ============================ 自制成品入库绑定 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void pegFinishedInbound(
            UUID stockDocumentId,
            UUID planId,
            UUID warehouseId,
            List<FinishedInboundSlice> lines) {
        tx.bind();
        if (lines == null || lines.isEmpty() || planId == null || warehouseId == null) {
            return;
        }
        List<UUID> analysisIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT material_analysis_id
                        FROM production_plans
                        WHERE id = :planId AND is_deleted = FALSE
                          AND material_analysis_id IS NOT NULL
                        """).setParameter("planId", planId), UUID.class);
        if (analysisIds.isEmpty()) {
            return; // 非物料分析来源计划：维持既有销售订单行预留口径
        }
        UUID analysisId = analysisIds.getFirst();
        List<String> liveStatus = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT status FROM production_material_analyses
                        WHERE id = :id AND is_deleted = FALSE
                        """).setParameter("id", analysisId), String.class);
        if (liveStatus.isEmpty()
                || !List.of("ACTIVE", "PARTIALLY_PLANNED").contains(liveStatus.getFirst())) {
            return; // 分析已取消/结束：产出回到公共现货
        }
        for (FinishedInboundSlice line : lines) {
            if (line.baseQty() == null || line.baseQty().signum() <= 0) {
                continue;
            }
            inventoryLock.lock(new InventoryKey(line.goodsId(), line.colorId()));
            insertReservation(
                    analysisId, warehouseId, line.goodsId(), line.colorId(),
                    line.baseQty(),
                    SUPPLY_PRODUCTION_PLAN_ITEM, line.planItemId(),
                    "PRODUCTION_INBOUND", stockDocumentId,
                    "PREPLAN-MAKE-IN:" + line.stockDocumentItemId());
        }
    }


    /** Global lock order for analysis-derived plan/package mutations: inventory first. */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID lockPlanningPackageInventoryDimensions(UUID planId) {
        tx.bind();
        if (planId == null) return null;
        List<?> sourceAnalyses = em.createNativeQuery("""
                        SELECT material_analysis_id
                        FROM production_plans
                        WHERE id = :planId
                          AND is_deleted = FALSE
                          AND material_analysis_id IS NOT NULL
                        """)
                .setParameter("planId", planId)
                .getResultList();
        if (sourceAnalyses.isEmpty()) return null;
        if (sourceAnalyses.size() != 1) {
            throw new IllegalStateException("生产计划存在多个来源物料分析身份");
        }
        UUID analysisId = (UUID) sourceAnalyses.getFirst();
        List<InventoryKey> dimensions = planningPackageInventoryKeys(analysisId);
        inventoryLock.lockAll(dimensions);
        List<?> lockedAnalyses = em.createNativeQuery("""
                        SELECT id
                        FROM production_material_analyses
                        WHERE id = :analysisId
                          AND is_deleted = FALSE
                        FOR UPDATE
                        """)
                .setParameter("analysisId", analysisId)
                .getResultList();
        if (lockedAnalyses.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "来源物料分析已删除，请刷新生产计划后重试");
        }
        if (!dimensions.equals(planningPackageInventoryKeys(analysisId))) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "来源物料分析的库存维度已并发变化，请刷新生产计划后重试");
        }
        return analysisId;
    }

    private List<InventoryKey> planningPackageInventoryKeys(UUID analysisId) {
        List<Object[]> dimensions = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT dimension.goods_id, dimension.color_id
                        FROM (
                            SELECT material.goods_id, material.color_id
                            FROM production_material_analysis_materials material
                            WHERE material.analysis_id = :analysisId
                              AND material.active = TRUE
                            UNION
                            SELECT reservation.goods_id, reservation.color_id
                            FROM stock_reservations reservation
                            WHERE reservation.owner_type = :ownerType
                              AND reservation.owner_id = :analysisId
                              AND reservation.is_deleted = FALSE
                              AND (
                                  (reservation.status = :effective
                                   AND GREATEST(reservation.qty
                                       - reservation.consumed_qty
                                       - reservation.released_qty, 0) > 0)
                                  OR reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                              )
                        ) dimension
                        ORDER BY dimension.goods_id, dimension.color_id NULLS FIRST
                        """)
                        .setParameter("analysisId", analysisId)
                        .setParameter("ownerType", OWNER_TYPE)
                        .setParameter("effective", STATUS_EFFECTIVE));
        return dimensions.stream()
                .map(row -> new InventoryKey((UUID) row[0], (UUID) row[1]))
                .toList();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requirePlanningPackageLifecycleReversible(UUID planId) {
        tx.bind();
        if (planId == null) return;
        List<UUID> transferred = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT reservation.id
                        FROM production_plans plan
                        JOIN stock_reservations reservation
                          ON reservation.owner_type = :ownerType
                         AND reservation.owner_id = plan.material_analysis_id
                         AND reservation.is_deleted = FALSE
                         AND reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                        WHERE plan.id = :planId
                          AND plan.is_deleted = FALSE
                          AND plan.material_analysis_id IS NOT NULL
                        ORDER BY reservation.id
                        FOR UPDATE OF reservation
                        """)
                .setParameter("ownerType", OWNER_TYPE)
                .setParameter("planId", planId), UUID.class);
        if (!transferred.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该计划来源分析已有库存归属转入正式需求；当前没有一对一可逆转移桥，"
                            + "禁止取消或红冲计划包，请提交受控异常处理");
        }
    }

    private void lockClaimantAnalyses(
            UUID externalItemId, UUID goodsId, UUID colorId) {
        em.createNativeQuery("""
                        SELECT analysis.id
                        FROM production_material_analyses analysis
                        WHERE analysis.is_deleted = FALSE
                          AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                          AND analysis.id IN (
                              SELECT allocation.analysis_id
                              FROM preplan_supply_action_allocations allocation
                              JOIN preplan_supply_actions action
                                ON action.id = allocation.action_id
                               AND action.status <> 'CANCELLED'
                              JOIN production_material_analysis_materials material
                                ON material.id = allocation.analysis_material_id
                               AND material.analysis_id = allocation.analysis_id
                               AND material.active = TRUE
                              WHERE allocation.external_item_id = :externalItemId
                                AND material.goods_id = :goodsId
                                AND material.color_id IS NOT DISTINCT FROM
                                    CAST(:colorId AS uuid)
                          )
                        ORDER BY analysis.id
                        FOR UPDATE OF analysis
                        """)
                .setParameter("externalItemId", externalItemId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .getResultList();
    }
    // ============================ 对称释放 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseForReceipt(String receiptType, UUID receiptId) {
        tx.bind();
        requireNoTransferredReservation(
                receiptType + "_RECEIPT", receiptId,
                "该收货的分析归属库存已转入正式生产需求；当前尚缺少收货到正式需求"
                        + "的一对一可逆转移链，禁止直接红冲，请提交受控异常处理");
        releaseRows(
                "r.source_doc_type = :sourceDocType AND r.source_doc_id = :sourceDocId",
                Map.of(
                        "sourceDocType", receiptType + "_RECEIPT",
                        "sourceDocId", receiptId),
                "PREPLAN_RECEIPT_REVERSED");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireFinishedInboundReversible(UUID stockDocumentId) {
        tx.bind();
        requireNoTransferredReservation(
                "PRODUCTION_INBOUND", stockDocumentId,
                "该成品入库的分析归属库存已转入正式生产需求；当前尚缺少成品入库到正式需求"
                        + "的一对一可逆转移链，禁止直接红冲，请提交受控异常处理");
    }

    private void requireNoTransferredReservation(
            String sourceDocType, UUID sourceDocId, String conflictMessage) {
        List<UUID> transferred = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT reservation.id
                FROM stock_reservations reservation
                WHERE reservation.is_deleted = FALSE
                  AND reservation.owner_type = :ownerType
                  AND reservation.source_doc_type = :sourceDocType
                  AND reservation.source_doc_id = :sourceDocId
                  AND reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                ORDER BY reservation.id
                FOR UPDATE
                """)
                .setParameter("ownerType", OWNER_TYPE)
                .setParameter("sourceDocType", sourceDocType)
                .setParameter("sourceDocId", sourceDocId), UUID.class);
        if (!transferred.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, conflictMessage);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseForAnalysis(UUID analysisId, String reason) {
        tx.bind();
        releaseRows(
                "r.owner_id = :analysisId",
                Map.of("analysisId", analysisId),
                normalizeReason(reason, "PREPLAN_ANALYSIS_CANCELLED"));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseForSupplyItems(
            UUID analysisId, Collection<UUID> externalItemIds, String reason) {
        tx.bind();
        if (externalItemIds == null || externalItemIds.isEmpty()) {
            return;
        }
        releaseRows(
                "r.owner_id = :analysisId AND r.supply_id IN (:supplyIds)",
                Map.of("analysisId", analysisId, "supplyIds", externalItemIds),
                normalizeReason(reason, "PREPLAN_ACTION_CANCELLED"));
    }

    // ============================ 下达计划包转移 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void transferToPlanDemands(
            UUID analysisId, UUID planId,
            UUID warehouseId, List<DemandSlice> demands) {
        tx.bind();
        if (analysisId == null || planId == null || warehouseId == null
                || demands == null || demands.isEmpty()) {
            return;
        }
        List<UUID> analysisItemIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT material_analysis_item_id
                        FROM production_plans
                        WHERE id = :planId
                          AND material_analysis_id = :analysisId
                          AND material_analysis_item_id IS NOT NULL
                          AND is_deleted = FALSE
                        """)
                        .setParameter("planId", planId)
                        .setParameter("analysisId", analysisId),
                UUID.class);
        if (analysisItemIds.size() != 1) {
            throw new IllegalStateException(
                    "正式计划缺少唯一物料分析产品行，不能安全转移精确到货归属");
        }
        UUID analysisItemId = analysisItemIds.getFirst();
        Map<String, BigDecimal> requiredByDimension = new LinkedHashMap<>();
        for (DemandSlice demand : demands) {
            if (demand.requiredQty() == null || demand.requiredQty().signum() <= 0) {
                continue;
            }
            requiredByDimension.merge(
                    dimensionKey(demand.goodsId(), demand.colorId()),
                    demand.requiredQty(),
                    BigDecimal::add);
        }
        if (requiredByDimension.isEmpty()) {
            return;
        }
        UUID actorId = currentUser.requireId();
        for (Map.Entry<String, BigDecimal> entry : requiredByDimension.entrySet()) {
            // dimensionKey = goodsId + '|' + (colorId 或空串)。不能用 split("\\|")：
            // Java split 会丢弃尾部空串，无颜色物料的 key 形如 "uuid|"，取 [1] 越界。
            String key = entry.getKey();
            int sep = key.indexOf('|');
            UUID goodsId = UUID.fromString(key.substring(0, sep));
            String colorText = key.substring(sep + 1);
            UUID colorId = colorText.isEmpty() ? null : UUID.fromString(colorText);
            inventoryLock.lock(new InventoryKey(goodsId, colorId));
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                            SELECT reservation.id, reservation.qty,
                                   reservation.consumed_qty,
                                   reservation.released_qty
                            FROM stock_reservations reservation
                            LEFT JOIN preplan_analysis_stock_exact_pegs exact_peg
                              ON exact_peg.stock_reservation_id = reservation.id
                            LEFT JOIN production_material_analysis_materials beneficiary
                              ON beneficiary.id = exact_peg.beneficiary_analysis_material_id
                             AND beneficiary.analysis_id =
                                 exact_peg.beneficiary_analysis_id
                            WHERE reservation.is_deleted = FALSE
                              AND reservation.status = :effective
                              AND reservation.owner_type = :ownerType
                              AND reservation.owner_id = :analysisId
                              AND reservation.warehouse_id = :warehouseId
                              AND reservation.goods_id = :goodsId
                              AND reservation.color_id IS NOT DISTINCT FROM
                                  CAST(:colorId AS uuid)
                              AND (
                                  exact_peg.id IS NULL
                                  OR
                                  (exact_peg.beneficiary_analysis_id = :analysisId
                                   AND beneficiary.analysis_item_id = :analysisItemId
                                   AND beneficiary.active = TRUE)
                              )
                            ORDER BY CASE WHEN exact_peg.id IS NULL THEN 1 ELSE 0 END,
                                     reservation.created_at, reservation.id
                            FOR UPDATE OF reservation
                            """)
                    .setParameter("effective", STATUS_EFFECTIVE)
                    .setParameter("ownerType", OWNER_TYPE)
                    .setParameter("analysisId", analysisId)
                    .setParameter("analysisItemId", analysisItemId)
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", goodsId)
                    .setParameter("colorId", colorId));
            BigDecimal remaining = entry.getValue();
            for (Object[] row : rows) {
                if (remaining.signum() <= 0) {
                    break;
                }
                UUID reservationId = (UUID) row[0];
                BigDecimal effective = decimal(row[1])
                        .subtract(decimal(row[2]))
                        .subtract(decimal(row[3]));
                BigDecimal take = effective.min(remaining);
                if (take.signum() <= 0) {
                    continue;
                }
                // 转移 = 释放分析占用（release_reason 留证），需求分配器同事务再为
                // demand 建正式预留；v_stock_available 口径在事务内不重复不漂移。
                em.createNativeQuery("""
                                UPDATE stock_reservations
                                SET released_qty = released_qty + :take,
                                    status = CASE
                                        WHEN consumed_qty + released_qty + :take >= qty
                                        THEN :done ELSE :effective END,
                                    release_reason = 'TRANSFERRED_TO_PLAN',
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :id
                                """)
                        .setParameter("take", take)
                        .setParameter("done", STATUS_DONE)
                        .setParameter("effective", STATUS_EFFECTIVE)
                        .setParameter("actorId", actorId)
                        .setParameter("id", reservationId)
                        .executeUpdate();
                remaining = remaining.subtract(take);
            }
        }
    }

    // ============================ 内部原语 ============================

    BigDecimal legacyAttributed(
            UUID analysisId, String supplyType, UUID externalItemId) {
        return decimal(em.createNativeQuery("""
                        SELECT COALESCE(SUM(CASE
                            WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                            THEN reservation.qty
                            ELSE reservation.qty - reservation.consumed_qty
                                - reservation.released_qty
                        END), 0)
                        FROM stock_reservations reservation
                        WHERE reservation.is_deleted = FALSE
                          AND (reservation.status = :effective
                               OR reservation.release_reason = 'TRANSFERRED_TO_PLAN')
                          AND reservation.owner_type = :ownerType
                          AND reservation.owner_id = :analysisId
                          AND reservation.supply_type = :supplyType
                          AND reservation.supply_id = :externalItemId
                          AND NOT EXISTS (
                              SELECT 1
                              FROM preplan_analysis_stock_exact_pegs peg
                              WHERE peg.stock_reservation_id = reservation.id)
                        """)
                .setParameter("effective", STATUS_EFFECTIVE)
                .setParameter("ownerType", OWNER_TYPE)
                .setParameter("analysisId", analysisId)
                .setParameter("supplyType", supplyType)
                .setParameter("externalItemId", externalItemId)
                .getSingleResult());
    }

    private void insertExactReservation(
            UUID allocationId,
            UUID analysisId,
            UUID analysisMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            BigDecimal qtyBase,
            String supplyType,
            UUID supplyId,
            String receiptType,
            UUID receiptId,
            UUID dispositionEventId) {
        String key = "PREPLAN-EXACT-PEG:" + dispositionEventId + ":" + allocationId;
        insertReservation(
                analysisId, warehouseId, goodsId, colorId, qtyBase,
                supplyType, supplyId, receiptType + "_RECEIPT", receiptId, key);
        UUID reservationId = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM stock_reservations
                        WHERE idempotency_key = :key
                          AND is_deleted = FALSE
                        """).setParameter("key", key), UUID.class).stream()
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "exact peg reservation was not persisted"));
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                        INSERT INTO preplan_analysis_stock_exact_pegs (
                            id, stock_reservation_id,
                            supply_action_allocation_id,
                            origin_analysis_id, origin_analysis_material_id,
                            beneficiary_analysis_id, beneficiary_analysis_material_id,
                            qty, source_receipt_type, source_receipt_id,
                            source_disposition_event_id, beneficiary_reason,
                            idempotency_key, created_by, updated_by
                        ) VALUES (
                            :id, :reservationId,
                            :allocationId,
                            :analysisId, :analysisMaterialId,
                            :analysisId, :analysisMaterialId,
                            :qty, :receiptType, :receiptId,
                            :eventId, 'ORIGIN_RECEIPT',
                            :key, :actorId, :actorId
                        )
                        ON CONFLICT (idempotency_key) DO NOTHING
                        """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("reservationId", reservationId)
                .setParameter("allocationId", allocationId)
                .setParameter("analysisId", analysisId)
                .setParameter("analysisMaterialId", analysisMaterialId)
                .setParameter("qty", qtyBase)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .setParameter("eventId", dispositionEventId)
                .setParameter("key", key)
                .setParameter("actorId", actorId)
                .executeUpdate();
    }

    private void insertReservation(
            UUID analysisId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            BigDecimal qtyBase,
            String supplyType,
            UUID supplyId,
            String sourceDocType,
            UUID sourceDocId,
            String idempotencyKey) {
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                        INSERT INTO stock_reservations (
                            id, order_item_id, goods_id, color_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_at, updated_at, created_by, updated_by,
                            is_deleted, lock_version
                        ) VALUES (
                            :id, NULL, :goodsId, :colorId, :warehouseId,
                            :qty, 0, 0, :status, :source,
                            :sourceDocType, :sourceDocId,
                            :ownerType, :ownerId, :purpose, NULL,
                            :supplyType, :supplyId, :key,
                            now(), now(), :actorId, :actorId,
                            FALSE, 0
                        )
                        ON CONFLICT (idempotency_key)
                        WHERE idempotency_key IS NOT NULL
                        DO NOTHING
                        """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("qty", qtyBase)
                .setParameter("status", STATUS_EFFECTIVE)
                .setParameter("source", SOURCE_PREPLAN_ANALYSIS)
                .setParameter("sourceDocType", sourceDocType)
                .setParameter("sourceDocId", sourceDocId)
                .setParameter("ownerType", OWNER_TYPE)
                .setParameter("ownerId", analysisId)
                .setParameter("purpose", PURPOSE)
                .setParameter("supplyType", supplyType)
                .setParameter("supplyId", supplyId)
                .setParameter("key", idempotencyKey)
                .setParameter("actorId", actorId)
                .executeUpdate();
    }

    /** 对称释放：先锁定完整作用域；任何部分/全部正式转移都使整次释放失败关闭。 */
    private void releaseRows(
            String whereClause,
            Map<String, Object> params,
            String releaseReason) {
        jakarta.persistence.Query query = em.createNativeQuery("""
                SELECT r.id, r.qty, r.consumed_qty, r.released_qty,
                       r.goods_id, r.color_id, r.status, r.release_reason
                FROM stock_reservations r
                WHERE r.is_deleted = FALSE
                  AND (r.status = :effective
                       OR r.release_reason = 'TRANSFERRED_TO_PLAN')
                  AND r.owner_type = :ownerType
                  AND %s
                ORDER BY r.created_at, r.id
                FOR UPDATE OF r
                """.formatted(whereClause))
                .setParameter("effective", STATUS_EFFECTIVE)
                .setParameter("ownerType", OWNER_TYPE);
        params.forEach(query::setParameter);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        if (rows.stream().anyMatch(row ->
                "TRANSFERRED_TO_PLAN".equals(row[7]))) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该分析归属库存已部分或全部转入正式生产需求；当前没有一对一可逆"
                            + "转移桥，禁止取消或释放归属，请提交受控异常处理");
        }
        applyRelease(rows, releaseReason);
    }

    private void applyRelease(List<Object[]> rows, String releaseReason) {
        UUID actorId = currentUser.requireId();
        for (Object[] row : rows) {
            UUID reservationId = (UUID) row[0];
            BigDecimal qty = decimal(row[1]);
            BigDecimal consumed = decimal(row[2]);
            BigDecimal released = decimal(row[3]);
            BigDecimal effective = qty.subtract(consumed).subtract(released);
            if (effective.signum() <= 0) {
                continue;
            }
            inventoryLock.lock(new InventoryKey((UUID) row[4], (UUID) row[5]));
            em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET released_qty = qty,
                                status = :done,
                                release_reason = :reason,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                            """)
                    .setParameter("done", STATUS_DONE)
                    .setParameter("reason", releaseReason)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
        }
    }

    private static String normalizeReason(String reason, String fallback) {
        return reason == null || reason.isBlank() ? fallback : reason.strip();
    }

    private static String dimensionKey(UUID goodsId, UUID colorId) {
        return goodsId + "|" + Objects.toString(colorId, "");
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }
}
