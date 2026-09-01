package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.beans.factory.ObjectProvider;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
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
    private final PreplanStockEntitlementService entitlement;
    private final ObjectProvider<PreplanOriginEntitlementHook> originHooks;

    // ============================ 收货入库绑定 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void attributeInspectionStockIn(
            String receiptType,
            UUID receiptId,
            UUID inspectionItemId,
            UUID dispositionEventId,
            UUID warehouseStockInItemId,
            BigDecimal stockedBaseQty,
            UUID warehouseId) {
        tx.bind();
        if (stockedBaseQty == null || stockedBaseQty.signum() <= 0
                || inspectionItemId == null || dispositionEventId == null
                || warehouseStockInItemId == null || warehouseId == null) {
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

        BigDecimal remaining = stockedBaseQty;
        Map<UUID, BigDecimal> legacyRemainingByAnalysis = new LinkedHashMap<>();
        for (Object[] claimant : claimants) {
            if (remaining.signum() <= 0) {
                break;
            }
            UUID allocationId = (UUID) claimant[0];
            UUID analysisId = (UUID) claimant[1];
            UUID analysisMaterialId = (UUID) claimant[2];
            BigDecimal allocatedCap = decimal(claimant[3]);
            BigDecimal exactAttributed = exactAttributed(allocationId);
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
                    dispositionEventId, warehouseStockInItemId);
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
        if (lines == null || lines.isEmpty() || planId == null
                || warehouseId == null || stockDocumentId == null) {
            return;
        }
        List<Object[]> contexts = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT plan.material_analysis_id,
                               plan.material_analysis_item_id,
                               item.source_type,
                               item.parent_analysis_material_id,
                               analysis.status
                        FROM production_plans plan
                        JOIN production_material_analyses analysis
                          ON analysis.id = plan.material_analysis_id
                         AND analysis.is_deleted = FALSE
                        JOIN production_material_analysis_items item
                          ON item.id = plan.material_analysis_item_id
                         AND item.analysis_id = plan.material_analysis_id
                         AND item.is_deleted = FALSE
                        WHERE plan.id = :planId
                          AND plan.is_deleted = FALSE
                          AND plan.material_analysis_id IS NOT NULL
                          AND plan.material_analysis_item_id IS NOT NULL
                        FOR UPDATE OF analysis, item
                        """).setParameter("planId", planId));
        if (contexts.isEmpty()) {
            return;
        }
        Object[] context = contexts.getFirst();
        UUID analysisId = (UUID) context[0];
        UUID analysisItemId = (UUID) context[1];
        UUID parentAnalysisMaterialId = (UUID) context[3];
        String sourceType = Objects.toString(context[2], "");
        String analysisStatus = Objects.toString(context[4], "");
        if (!List.of("ACTIVE", "PARTIALLY_PLANNED").contains(analysisStatus)) {
            return;
        }
        if ("SUBCONTRACT_PREPARATION".equals(sourceType)) {
            // ProductionCompletionReverseService invokes the neutral
            // SubcontractPreparationInventoryPort later in this same
            // FINISHED_IN transaction. That port creates the single dedicated
            // reservation; PREPLAN_ANALYSIS must not reserve the same stock.
            return;
        }
        if (!"MAKE_COMPONENT".equals(sourceType)) {
            // Preserve the historical analysis-pool behavior for non-MAKE
            // analysis products. Only PREPLAN_MAKE_TASK output has an exact
            // parent material allocation that V309 can prove.
            for (FinishedInboundSlice line : lines) {
                if (line.baseQty() == null || line.baseQty().signum() <= 0) continue;
                inventoryLock.lock(new InventoryKey(
                        line.goodsId(), line.colorId()));
                insertReservation(
                        analysisId, warehouseId, line.goodsId(), line.colorId(),
                        line.baseQty(), SUPPLY_PRODUCTION_PLAN_ITEM,
                        line.planItemId(), "PRODUCTION_INBOUND", stockDocumentId,
                        "PREPLAN-MAKE-IN:" + line.stockDocumentItemId());
            }
            return;
        }

        Map<UUID, BigDecimal> formalRemainingByPlanItem = new HashMap<>();
        Map<UUID, BigDecimal> legacyRemainingByAnalysis = new HashMap<>();
        for (FinishedInboundSlice line : lines) {
            if (line.baseQty() == null || line.baseQty().signum() <= 0) continue;
            inventoryLock.lock(new InventoryKey(line.goodsId(), line.colorId()));
            BigDecimal formalRemaining = formalRemainingByPlanItem.computeIfAbsent(
                    line.planItemId(), this::activeFormalMakeCommitment);
            BigDecimal formalUse = line.baseQty().min(formalRemaining);
            formalRemainingByPlanItem.put(
                    line.planItemId(), formalRemaining.subtract(formalUse));
            BigDecimal remaining = line.baseQty().subtract(formalUse);
            if (remaining.signum() <= 0) continue;

            List<Object[]> allocations = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                            SELECT allocation.id, allocation.analysis_id,
                                   allocation.analysis_material_id,
                                   allocation.allocated_qty
                            FROM preplan_supply_action_allocations allocation
                            JOIN preplan_supply_actions action
                              ON action.id = allocation.action_id
                             AND action.analysis_id = allocation.analysis_id
                             AND action.route = 'MAKE'
                             AND action.status <> 'CANCELLED'
                             AND action.external_document_type =
                                 'PREPLAN_MAKE_TASK'
                            JOIN production_material_analysis_materials material
                              ON material.id = allocation.analysis_material_id
                             AND material.analysis_id = allocation.analysis_id
                             AND material.active = TRUE
                            WHERE allocation.analysis_id = :analysisId
                              AND allocation.external_item_id = :analysisItemId
                              AND allocation.analysis_material_id =
                                  :parentMaterialId
                              AND material.goods_id = :goodsId
                              AND material.color_id IS NOT DISTINCT FROM
                                  CAST(:colorId AS uuid)
                            ORDER BY allocation.created_at, allocation.id
                            FOR UPDATE OF action, allocation
                            """)
                            .setParameter("analysisId", analysisId)
                            .setParameter("analysisItemId", analysisItemId)
                            .setParameter("goodsId", line.goodsId())
                            .setParameter("parentMaterialId", parentAnalysisMaterialId)
                            .setParameter("colorId", line.colorId()));
            for (Object[] allocation : allocations) {
                if (remaining.signum() <= 0) break;
                UUID allocationId = (UUID) allocation[0];
                UUID materialId = (UUID) allocation[2];
                BigDecimal exactAttributed = exactAttributed(allocationId);
                BigDecimal capacity = decimal(allocation[3])
                        .subtract(exactAttributed).max(BigDecimal.ZERO);
                BigDecimal legacyRemaining = legacyRemainingByAnalysis
                        .computeIfAbsent(analysisId, ignored ->
                                legacyMakeAttributed(analysisId, analysisItemId));
                BigDecimal legacyUse = capacity.min(legacyRemaining);
                legacyRemainingByAnalysis.put(
                        analysisId, legacyRemaining.subtract(legacyUse));
                BigDecimal take = capacity.subtract(legacyUse)
                        .max(BigDecimal.ZERO).min(remaining);
                if (take.signum() <= 0) continue;
                insertExactMakeReservation(
                        allocationId, analysisId, materialId,
                        warehouseId, line.goodsId(), line.colorId(), take,
                        line.planItemId(), stockDocumentId,
                        line.stockDocumentItemId());
                remaining = remaining.subtract(take);
            }
            // Any output beyond the proven PREPLAN_MAKE_TASK allocation is
            // intentionally left as public stock.
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
        inventoryLock.lockAll(dimensions.stream()
                .map(row -> new InventoryKey((UUID) row[0], (UUID) row[1]))
                .toList());
        return analysisId;
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
                         AND NOT EXISTS (
                             SELECT 1
                             FROM preplan_analysis_stock_exact_pegs exact_peg
                             WHERE exact_peg.stock_reservation_id =
                                 reservation.id)
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
        prepareEntitlementRelease("PRODUCTION_INBOUND", stockDocumentId);
    }

    private void prepareEntitlementRelease(
            String sourceDocType, UUID sourceDocId) {
        List<UUID> reservationIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT reservation.id
                        FROM stock_reservations reservation
                        WHERE reservation.is_deleted = FALSE
                          AND reservation.status = :effective
                          AND reservation.owner_type = :ownerType
                          AND reservation.source_doc_type = :sourceDocType
                          AND reservation.source_doc_id = :sourceDocId
                          AND reservation.qty - reservation.consumed_qty
                              - reservation.released_qty > 0
                        ORDER BY reservation.id
                        FOR UPDATE OF reservation
                        """)
                        .setParameter("effective", STATUS_EFFECTIVE)
                        .setParameter("ownerType", OWNER_TYPE)
                        .setParameter("sourceDocType", sourceDocType)
                        .setParameter("sourceDocId", sourceDocId),
                UUID.class);
        requireReservationsReallocationSafe(
                reservationIds, "成品入库红冲");
        for (UUID reservationId : reservationIds) {
            entitlement.appendReleaseForReservation(
                    reservationId, sourceDocId,
                    "PREPLAN-RELEASE:" + reservationId);
        }
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
    public void releaseForAnalysis(
            UUID analysisId,
            String reason,
            String cancellationIdempotencyKey) {
        tx.bind();
        String cancellationKey = Objects.requireNonNull(
                cancellationIdempotencyKey,
                "cancellationIdempotencyKey").strip();
        if (cancellationKey.isEmpty()) {
            throw new IllegalArgumentException(
                    "cancellationIdempotencyKey must not be blank");
        }
        String releaseReason =
                normalizeReason(reason, "PREPLAN_ANALYSIS_CANCELLED");
        entitlement.requireNoActiveFormalizationForBeneficiary(
                analysisId, true);
        requireAnalysisCancellationSafe(analysisId);
        String eventPrefix = "PREPLAN-ANALYSIS-CANCEL:"
                + PlanningPackageFingerprint.sha256(List.of(
                        analysisId.toString(), cancellationKey));
        List<PreplanStockEntitlementService.ReservationRelease> slices =
                entitlement.appendReleaseForBeneficiaryAnalysis(
                        analysisId, analysisId, eventPrefix);
        applyBeneficiaryReleaseSlices(slices, releaseReason);
        releaseRows(
                """
                r.owner_id = :analysisId
                AND NOT EXISTS (
                    SELECT 1
                    FROM preplan_stock_entitlement_events event
                    WHERE event.stock_reservation_id = r.id)
                """,
                Map.of("analysisId", analysisId),
                releaseReason);
        closeFulfilledReallocations(
                analysisId, releaseReason, cancellationKey);
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
    public List<PreparedPlanTransfer> transferToPlanDemands(
            UUID analysisId, UUID planId,
            UUID warehouseId, List<DemandSlice> demands) {
        tx.bind();
        if (analysisId == null || planId == null || warehouseId == null
                || demands == null || demands.isEmpty()) {
            return List.of();
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
                    "Formal plan lacks one material-analysis item identity");
        }
        UUID analysisItemId = analysisItemIds.getFirst();
        List<DemandSlice> orderedDemands = demands.stream()
                .filter(demand -> demand != null
                        && demand.demandId() != null
                        && demand.goodsId() != null
                        && demand.requiredQty() != null
                        && demand.requiredQty().signum() > 0)
                .sorted(Comparator
                        .comparing(DemandSlice::goodsId)
                        .thenComparing(demand ->
                                Objects.toString(demand.colorId(), ""))
                        .thenComparing(DemandSlice::demandId))
                .toList();
        if (orderedDemands.isEmpty()) {
            return List.of();
        }

        List<PreparedPlanTransfer> prepared = new ArrayList<>();
        Map<UUID, BigDecimal> preparedByEntitlementLot = new HashMap<>();
        for (DemandSlice demand : orderedDemands) {
            inventoryLock.lock(new InventoryKey(
                    demand.goodsId(), demand.colorId()));
            BigDecimal remaining = demand.requiredQty();
            List<UUID> materialIds = NativeQueryResults.typedRows(
                    em.createNativeQuery("""
                            SELECT id
                            FROM production_material_analysis_materials
                            WHERE analysis_id = :analysisId
                              AND analysis_item_id = :analysisItemId
                              AND goods_id = :goodsId
                              AND color_id IS NOT DISTINCT FROM
                                  CAST(:colorId AS uuid)
                              AND active = TRUE
                            ORDER BY path, id
                            """)
                            .setParameter("analysisId", analysisId)
                            .setParameter("analysisItemId", analysisItemId)
                            .setParameter("goodsId", demand.goodsId())
                            .setParameter("colorId", demand.colorId()),
                    UUID.class);
            for (UUID materialId : materialIds) {
                if (remaining.signum() <= 0) break;
                List<PreplanStockEntitlementService.AvailableLot> lots =
                        entitlement.listAvailableBeneficiaryLots(
                                analysisId, materialId, warehouseId,
                                demand.goodsId(), demand.colorId(), true);
                for (PreplanStockEntitlementService.AvailableLot lot : lots) {
                    if (remaining.signum() <= 0) break;
                    BigDecimal alreadyPrepared = preparedByEntitlementLot
                            .getOrDefault(lot.entitlementEventId(), BigDecimal.ZERO);
                    BigDecimal available = lot.remainingQty()
                            .subtract(alreadyPrepared).max(BigDecimal.ZERO);
                    BigDecimal take = available.min(remaining);
                    if (take.signum() <= 0) continue;
                    entitlement.consumePhysicalForFormalize(
                            lot.stockReservationId(), take);
                    prepared.add(new PreparedPlanTransfer(
                            lot.entitlementEventId(), lot.stockReservationId(),
                            lot.beneficiaryAnalysisId(),
                            lot.beneficiaryAnalysisMaterialId(),
                            demand.demandId(), take));
                    preparedByEntitlementLot.merge(
                            lot.entitlementEventId(), take, BigDecimal::add);
                    remaining = remaining.subtract(take);
                }
            }

            // Historical V298 rows deliberately have no entitlement event.
            // Preserve their analysis-pool behavior, but do not invent a
            // reversible event lineage for them.
            if (remaining.signum() > 0) {
                List<Object[]> legacyRows = NativeQueryResults.objectArrayRows(
                        em.createNativeQuery("""
                                SELECT reservation.id,
                                       reservation.qty
                                           - reservation.consumed_qty
                                           - reservation.released_qty
                                FROM stock_reservations reservation
                                WHERE reservation.is_deleted = FALSE
                                  AND reservation.status = :effective
                                  AND reservation.owner_type = :ownerType
                                  AND reservation.owner_id = :analysisId
                                  AND reservation.warehouse_id = :warehouseId
                                  AND reservation.goods_id = :goodsId
                                  AND reservation.color_id IS NOT DISTINCT FROM
                                      CAST(:colorId AS uuid)
                                  AND NOT EXISTS (
                                      SELECT 1
                                      FROM preplan_analysis_stock_exact_pegs exact_peg
                                      WHERE exact_peg.stock_reservation_id =
                                          reservation.id)
                                  AND NOT EXISTS (
                                      SELECT 1
                                      FROM preplan_stock_entitlement_events event
                                      WHERE event.stock_reservation_id =
                                          reservation.id)
                                ORDER BY reservation.created_at, reservation.id
                                FOR UPDATE OF reservation
                                """)
                                .setParameter("effective", STATUS_EFFECTIVE)
                                .setParameter("ownerType", OWNER_TYPE)
                                .setParameter("analysisId", analysisId)
                                .setParameter("warehouseId", warehouseId)
                                .setParameter("goodsId", demand.goodsId())
                                .setParameter("colorId", demand.colorId()));
                for (Object[] row : legacyRows) {
                    if (remaining.signum() <= 0) break;
                    BigDecimal take = decimal(row[1]).max(BigDecimal.ZERO)
                            .min(remaining);
                    if (take.signum() <= 0) continue;
                    entitlement.consumePhysicalForFormalize((UUID) row[0], take);
                    remaining = remaining.subtract(take);
                }
            }
        }
        return List.copyOf(prepared);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void formalizePlanDemandTransfers(
            UUID packageId,
            List<PreparedPlanTransfer> prepared,
            List<FormalReservationSlice> formalReservations) {
        tx.bind();
        if (prepared == null || prepared.isEmpty()) return;
        Map<UUID, FormalReservationSlice> formalByDemand = new LinkedHashMap<>();
        if (formalReservations != null) {
            for (FormalReservationSlice formal : formalReservations) {
                if (formal != null && formal.stockReservationId() != null) {
                    FormalReservationSlice previous = formalByDemand.put(
                            formal.demandId(), formal);
                    if (previous != null) {
                        throw new IllegalStateException(
                                "One demand has multiple formal stock reservations");
                    }
                }
            }
        }
        Map<UUID, BigDecimal> preparedByDemand = new LinkedHashMap<>();
        prepared.forEach(slice -> preparedByDemand.merge(
                slice.demandId(), slice.qty(), BigDecimal::add));
        for (Map.Entry<UUID, BigDecimal> entry : preparedByDemand.entrySet()) {
            FormalReservationSlice formal = formalByDemand.get(entry.getKey());
            if (formal == null || formal.qty().compareTo(entry.getValue()) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "Formal allocation does not cover prepared analysis stock");
            }
        }
        UUID eventGroupId = packageId;
        for (PreparedPlanTransfer slice : prepared) {
            FormalReservationSlice formal = formalByDemand.get(slice.demandId());
            entitlement.appendFormalize(
                    eventGroupId,
                    slice.sourceEntitlementEventId(),
                    slice.sourceStockReservationId(),
                    slice.beneficiaryAnalysisId(),
                    slice.beneficiaryAnalysisMaterialId(),
                    slice.qty(), packageId, slice.demandId(),
                    formal.stockReservationId(),
                    "PREPLAN-FORMALIZE:" + packageId + ":"
                            + slice.demandId() + ":"
                            + slice.sourceEntitlementEventId());
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void restorePlanDemandTransfers(
            Collection<UUID> formalReservationIds, String reason) {
        tx.bind();
        List<PreplanStockEntitlementService.Formalization> formalizations =
                entitlement.listActiveFormalizations(
                        formalReservationIds, true);
        for (PreplanStockEntitlementService.Formalization formalization
                : formalizations) {
            entitlement.appendRestore(
                    formalization.targetPackageId(), formalization,
                    "PREPLAN-RESTORE:" + formalization.formalizeEventId());
            entitlement.restorePhysicalAfterFormalRelease(
                    formalization.sourceStockReservationId(),
                    formalization.qty());
        }
    }

    // ============================ 内部原语 ============================

    private BigDecimal activeFormalMakeCommitment(UUID planItemId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(GREATEST(
                    peg.allocated_qty - peg.consumed_qty - peg.released_qty,
                    0)), 0)
                FROM production_material_supply_pegs peg
                WHERE peg.supply_type = 'PRODUCTION_PLAN_ITEM'
                  AND peg.supply_item_id = :planItemId
                  AND peg.status <> 'REVERSED'
                """).setParameter("planItemId", planItemId).getSingleResult());
    }

    BigDecimal exactAttributed(UUID allocationId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(peg.qty), 0)
                FROM preplan_analysis_stock_exact_pegs peg
                LEFT JOIN procurement_inspection_events disposition
                  ON disposition.id = peg.source_disposition_event_id
                LEFT JOIN procurement_inspection_items inspection
                  ON inspection.id = disposition.inspection_item_id
                LEFT JOIN stock_documents stock_document
                  ON stock_document.id = peg.source_stock_document_id
                WHERE peg.supply_action_allocation_id = :allocationId
                  AND (
                      (
                          peg.source_receipt_type IN ('PURCHASE', 'SUBCONTRACT')
                          AND disposition.id IS NOT NULL
                          AND inspection.id IS NOT NULL
                          AND inspection.status <> 'REVERSED'
                      )
                      OR
                      (
                          peg.source_receipt_type = 'MAKE'
                          AND stock_document.id IS NOT NULL
                          AND stock_document.status = 1
                          AND stock_document.is_deleted = FALSE
                      )
                  )
                """)
                .setParameter("allocationId", allocationId)
                .getSingleResult());
    }

    BigDecimal legacyMakeAttributed(UUID analysisId, UUID analysisItemId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE
                    WHEN reservation.release_reason = 'TRANSFERRED_TO_PLAN'
                    THEN reservation.qty
                    ELSE reservation.qty - reservation.consumed_qty
                        - reservation.released_qty
                END), 0)
                FROM stock_reservations reservation
                JOIN production_plan_items plan_item
                  ON plan_item.id = reservation.supply_id
                 AND plan_item.is_deleted = FALSE
                JOIN production_plans plan
                  ON plan.id = plan_item.plan_id
                 AND plan.is_deleted = FALSE
                 AND plan.material_analysis_id = :analysisId
                 AND plan.material_analysis_item_id = :analysisItemId
                WHERE reservation.is_deleted = FALSE
                  AND (reservation.status = :effective
                       OR reservation.release_reason = 'TRANSFERRED_TO_PLAN')
                  AND reservation.owner_type = :ownerType
                  AND reservation.owner_id = :analysisId
                  AND reservation.supply_type = 'PRODUCTION_PLAN_ITEM'
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_analysis_stock_exact_pegs exact_peg
                      WHERE exact_peg.stock_reservation_id = reservation.id)
                """)
                .setParameter("effective", STATUS_EFFECTIVE)
                .setParameter("ownerType", OWNER_TYPE)
                .setParameter("analysisId", analysisId)
                .setParameter("analysisItemId", analysisItemId)
                .getSingleResult());
    }

    private void insertExactMakeReservation(
            UUID allocationId,
            UUID analysisId,
            UUID analysisMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            BigDecimal qtyBase,
            UUID planItemId,
            UUID stockDocumentId,
            UUID stockDocumentItemId) {
        // The FINISHED_IN header becomes APPROVED later in the same approve
        // transaction. Defer the exact-provenance constraint so V312 observes
        // the committed status without publishing an intermediate header state.
        em.createNativeQuery("""
                SET CONSTRAINTS
                    trg_check_preplan_analysis_stock_exact_peg DEFERRED
                """).executeUpdate();
        String key = "PREPLAN-MAKE-EXACT:" + stockDocumentItemId
                + ":" + allocationId;
        insertReservation(
                analysisId, warehouseId, goodsId, colorId, qtyBase,
                SUPPLY_PRODUCTION_PLAN_ITEM, planItemId,
                "PRODUCTION_INBOUND", stockDocumentId, key);
        UUID reservationId = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM stock_reservations
                        WHERE idempotency_key = :key
                          AND is_deleted = FALSE
                        """).setParameter("key", key), UUID.class).stream()
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "MAKE exact reservation was not persisted"));
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                INSERT INTO preplan_analysis_stock_exact_pegs (
                    id, stock_reservation_id,
                    supply_action_allocation_id,
                    origin_analysis_id, origin_analysis_material_id,
                    beneficiary_analysis_id, beneficiary_analysis_material_id,
                    qty, source_receipt_type, source_receipt_id,
                    source_disposition_event_id,
                    source_stock_document_id, source_stock_document_item_id,
                    beneficiary_reason, idempotency_key,
                    created_by, updated_by
                ) VALUES (
                    :id, :reservationId, :allocationId,
                    :analysisId, :materialId,
                    :analysisId, :materialId,
                    :qty, 'MAKE', :stockDocumentId,
                    NULL, :stockDocumentId, :stockDocumentItemId,
                    'ORIGIN_MAKE', :key, :actorId, :actorId
                )
                ON CONFLICT (idempotency_key) DO NOTHING
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("reservationId", reservationId)
                .setParameter("allocationId", allocationId)
                .setParameter("analysisId", analysisId)
                .setParameter("materialId", analysisMaterialId)
                .setParameter("qty", qtyBase)
                .setParameter("stockDocumentId", stockDocumentId)
                .setParameter("stockDocumentItemId", stockDocumentItemId)
                .setParameter("key", key)
                .setParameter("actorId", actorId)
                .executeUpdate();
        UUID exactPegId = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM preplan_analysis_stock_exact_pegs
                        WHERE idempotency_key = :key
                        """).setParameter("key", key), UUID.class).stream()
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "MAKE exact peg was not persisted"));
        PreplanStockEntitlementService.OriginAppendResult origin =
                entitlement.appendOriginMake(
                stockDocumentItemId, reservationId,
                analysisId, analysisMaterialId, qtyBase,
                exactPegId, stockDocumentId, stockDocumentItemId,
                "PREPLAN-ENTITLEMENT-MAKE:" + stockDocumentItemId
                        + ":" + allocationId);
        applyOriginPriority(origin);
    }

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
            UUID dispositionEventId,
            UUID warehouseStockInItemId) {
        String key = "PREPLAN-EXACT-PEG:" + warehouseStockInItemId + ":" + allocationId;
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
        UUID exactPegId = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM preplan_analysis_stock_exact_pegs
                        WHERE idempotency_key = :key
                        """).setParameter("key", key), UUID.class).stream()
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "exact peg was not persisted"));
        PreplanStockEntitlementService.OriginAppendResult origin =
                entitlement.appendOriginIqc(
                warehouseStockInItemId, reservationId,
                analysisId, analysisMaterialId, qtyBase,
                exactPegId, receiptType, receiptId, dispositionEventId,
                "PREPLAN-ENTITLEMENT-IQC:" + warehouseStockInItemId
                        + ":" + allocationId);
        applyOriginPriority(origin);
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

    private void requireAnalysisCancellationSafe(UUID analysisId) {
        List<UUID> relations = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT reallocation.id
                        FROM preplan_material_reallocations reallocation
                        WHERE reallocation.status IN ('OPEN', 'PARTIAL')
                          AND (reallocation.from_analysis_id = :analysisId
                               OR reallocation.to_analysis_id = :analysisId)
                        ORDER BY reallocation.id
                        FOR UPDATE OF reallocation
                        """).setParameter("analysisId", analysisId), UUID.class);
        if (!relations.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该分析仍有未补齐的跨分析让料；请先撤销未使用让料，"
                            + "或等待优先补齐完成后再取消");
        }
    }

    private void requireReservationsReallocationSafe(
            Collection<UUID> reservationIds, String operationLabel) {
        List<UUID> ids = reservationIds == null
                ? List.of()
                : reservationIds.stream()
                        .filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) return;
        List<UUID> relations = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT reallocation.id
                        FROM preplan_material_reallocations reallocation
                        JOIN preplan_stock_entitlement_events event
                          ON event.reallocation_id = reallocation.id
                        WHERE event.stock_reservation_id IN (:reservationIds)
                          AND reallocation.status IN (
                              'OPEN', 'PARTIAL', 'FULFILLED')
                        ORDER BY reallocation.id
                        FOR UPDATE OF reallocation
                        """).setParameter("reservationIds", ids), UUID.class);
        if (!relations.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    operationLabel + "关联库存仍参与跨分析让料/优先补齐；"
                            + "请先显式撤销未使用让料或取消未领料正式计划");
        }
        List<UUID> foreignBeneficiaries = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT reservation.id
                        FROM stock_reservations reservation
                        JOIN preplan_analysis_stock_exact_pegs exact_peg
                          ON exact_peg.stock_reservation_id = reservation.id
                        JOIN v_preplan_stock_entitlement_beneficiary_balance balance
                          ON balance.stock_reservation_id = reservation.id
                        WHERE reservation.id IN (:reservationIds)
                          AND (balance.beneficiary_analysis_id
                                  <> exact_peg.origin_analysis_id
                               OR balance.beneficiary_analysis_material_id
                                  <> exact_peg.origin_analysis_material_id)
                        ORDER BY reservation.id
                        FOR UPDATE OF reservation
                        """).setParameter("reservationIds", ids), UUID.class);
        if (!foreignBeneficiaries.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    operationLabel + "会影响其他分析当前受益权益；"
                            + "请先显式撤销让料或取消未领料正式计划");
        }
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
        requireReservationsReallocationSafe(
                rows.stream().map(row -> (UUID) row[0]).toList(),
                "库存归属释放");

        if (rows.stream().anyMatch(row ->
                "TRANSFERRED_TO_PLAN".equals(row[7]))) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该分析归属库存仍有未恢复正式转移；请先取消未领料计划完成RESTORE，"
                            + "已领料则禁止取消或释放归属");
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
            entitlement.appendReleaseForReservation(
                    reservationId, reservationId,
                    "PREPLAN-RELEASE:" + reservationId);
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

    private void applyBeneficiaryReleaseSlices(
            List<PreplanStockEntitlementService.ReservationRelease> slices,
            String releaseReason) {
        UUID actorId = currentUser.requireId();
        for (PreplanStockEntitlementService.ReservationRelease slice : slices) {
            inventoryLock.lock(new InventoryKey(
                    slice.goodsId(), slice.colorId()));
            int updated = em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET released_qty = released_qty + :releaseQty,
                                status = CASE
                                    WHEN qty - consumed_qty - released_qty =
                                         :releaseQty
                                        THEN :done
                                    ELSE :effective
                                END,
                                release_reason = CASE
                                    WHEN qty - consumed_qty - released_qty =
                                         :releaseQty
                                        THEN COALESCE(release_reason, :reason)
                                    ELSE release_reason
                                END,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND is_deleted = FALSE
                              AND owner_type = :ownerType
                              AND qty - consumed_qty - released_qty >=
                                  :releaseQty
                            """)
                    .setParameter("releaseQty", slice.qty())
                    .setParameter("done", STATUS_DONE)
                    .setParameter("effective", STATUS_EFFECTIVE)
                    .setParameter("reason", releaseReason)
                    .setParameter("actorId", actorId)
                    .setParameter("id", slice.stockReservationId())
                    .setParameter("ownerType", OWNER_TYPE)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "分析取消时库存权益切片已发生变化，请刷新后重试");
            }
        }
    }

    private void closeFulfilledReallocations(
            UUID analysisId,
            String closeReason,
            String cancellationIdempotencyKey) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT reallocation.id, reallocation.lock_version
                        FROM preplan_material_reallocations reallocation
                        WHERE reallocation.status = 'FULFILLED'
                          AND (reallocation.from_analysis_id = :analysisId
                               OR reallocation.to_analysis_id = :analysisId)
                        ORDER BY reallocation.id
                        FOR UPDATE OF reallocation
                        """).setParameter("analysisId", analysisId));
        UUID actorId = currentUser.requireId();
        for (Object[] row : rows) {
            UUID reallocationId = (UUID) row[0];
            long lockVersion = ((Number) row[1]).longValue();
            String closeKey = "ANALYSIS-CANCEL:"
                    + PlanningPackageFingerprint.sha256(List.of(
                            analysisId.toString(), reallocationId.toString(),
                            cancellationIdempotencyKey));
            String closeHash = PlanningPackageFingerprint.sha256(List.of(
                    "CANCEL_FULFILLED_REALLOCATION",
                    analysisId.toString(), reallocationId.toString(),
                    cancellationIdempotencyKey, closeReason));
            int updated = em.createNativeQuery("""
                            UPDATE preplan_material_reallocations
                            SET status = 'CANCELLED',
                                closed_by = :actorId,
                                closed_at = now(),
                                close_reason = :reason,
                                close_idempotency_key = :closeKey,
                                close_request_hash = :closeHash,
                                lock_version = lock_version + 1,
                                updated_by = :actorId
                            WHERE id = :id
                              AND status = 'FULFILLED'
                              AND lock_version = :lockVersion
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("reason", closeReason)
                    .setParameter("closeKey", closeKey)
                    .setParameter("closeHash", closeHash)
                    .setParameter("id", reallocationId)
                    .setParameter("lockVersion", lockVersion)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "已补齐让料记录发生并发变化，请刷新后重试");
            }
        }
    }
    void applyOriginPriority(
            PreplanStockEntitlementService.OriginAppendResult origin) {
        if (origin.inserted()) {
            applyOriginPriority(origin.eventId());
        }
    }

    private void applyOriginPriority(UUID originEventId) {
        originHooks.orderedStream().forEach(
                hook -> hook.applyPriorityForOriginEvent(originEventId));
    }

    private static String normalizeReason(String reason, String fallback) {
        return reason == null || reason.isBlank() ? fallback : reason.strip();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }
}
