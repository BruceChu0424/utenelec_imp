package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.SubcontractPreparationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * V447 exact-entitlement bridge from an original SUBCONTRACT material node to
 * the independent {@code SUBCONTRACT_PREPARATION} analysis created for one
 * approved subcontract order line.
 *
 * <p>The bridge is not a manual cross-analysis reallocation: it creates no
 * replenishment priority.  The immutable physical reservation and exact origin
 * remain unchanged while append-only OUT/IN entitlement events move only the
 * current beneficiary.  A quantitative TAKEOVER event removes only the order
 * line's parent-output share from the original diagnostic subtree.</p>
 */
@Service
@Order(-100)
@RequiredArgsConstructor
public class SubcontractPreparationEntitlementHandoffService
        implements PreplanOriginEntitlementHook {

    private static final String OUT = "SUBCONTRACT_HANDOFF_OUT";
    private static final String IN = "SUBCONTRACT_HANDOFF_IN";

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final InventoryMutationLock inventoryLock;
    private final MaterialAnalysisService analyses;
    private final PreplanStockEntitlementService entitlements;

    /** Canonical lock prefix: inventory dimensions, source analysis, source facts. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockStartContext(SubcontractPreparationPort.StartContext context) {
        tx.bind();
        if (context == null) {
            throw conflict("委外前置自制启动上下文缺失，请刷新后重试");
        }
        inventoryLock.lockAll(context.inventoryDimensions().stream()
                .map(dimension -> new InventoryKey(
                        dimension.goodsId(), dimension.colorId()))
                .toList());
        if (!context.hasSourceAnalysis()) return;
        MaterialAnalysisService.AnalysisHeader source =
                analyses.lockHeader(context.sourceAnalysisId());
        if (!List.of(MaterialAnalysisService.STATUS_ACTIVE,
                        MaterialAnalysisService.STATUS_PARTIAL)
                .contains(source.status())) {
            throw conflict("原物料分析已结束，不能启动委外前置自制");
        }
        List<Object[]> locked = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT action.id, allocation.id, material.id
                        FROM preplan_supply_actions action
                        JOIN preplan_supply_action_allocations allocation
                          ON allocation.action_id = action.id
                         AND allocation.analysis_id = action.analysis_id
                        JOIN production_material_analysis_materials material
                          ON material.id = allocation.analysis_material_id
                         AND material.analysis_id = allocation.analysis_id
                        WHERE action.id = :actionId
                          AND allocation.id = :allocationId
                          AND action.analysis_id = :analysisId
                          AND material.id = :materialId
                          AND action.route = 'SUBCONTRACT'
                          AND action.status <> 'CANCELLED'
                          AND material.active = TRUE
                          AND material.confirmed_route = 'SUBCONTRACT'
                        FOR UPDATE OF action, allocation, material
                        """)
                        .setParameter("actionId", context.sourceSupplyActionId())
                        .setParameter("allocationId",
                                context.sourceSupplyActionAllocationId())
                        .setParameter("analysisId", context.sourceAnalysisId())
                        .setParameter("materialId", context.sourceMaterialLineId()));
        if (locked.size() != 1) {
            throw conflict("原物料分析委外行动已变化，请刷新后重试");
        }
    }

    /** Creates the full handoff atomically before the task START command commits. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void createStartHandoff(
            SubcontractPreparationPort.StartClaim claim,
            UUID targetAnalysisId,
            UUID targetAnalysisItemId) {
        tx.bind();
        if (claim.sourceAnalysisId() == null) {
            requireNoUnexpectedHandoff(claim.planItemId());
            return;
        }
        MaterialAnalysisService.AnalysisHeader target =
                analyses.lockHeader(targetAnalysisId);
        if (!Objects.equals(target.warehouseId(), claim.warehouseId())) {
            throw conflict("前置自制分析目标仓与冻结仓不一致");
        }
        List<MappingDraft> mappings = mappingDrafts(
                claim.sourceAnalysisId(), claim.sourceAnalysisItemId(),
                claim.sourceMaterialLineId(), targetAnalysisId, targetAnalysisItemId);
        if (mappings.isEmpty()) {
            throw conflict("委外前置自制未形成可接管的 BOM 子层级，启动已回滚");
        }
        List<ClaimDraft> claims = claimDrafts(
                claim.sourceAnalysisId(), mappings);
        String requestHash = handoffHash(claim, targetAnalysisId,
                targetAnalysisItemId, target, mappings, claims);
        String key = "SC-HANDOFF:" + claim.planItemId() + ":" + targetAnalysisId;

        HandoffHeader existing = handoffByPlanItem(claim.planItemId(), true);
        if (existing != null) {
            requireSameHandoff(existing, claim, targetAnalysisId,
                    targetAnalysisItemId, requestHash);
            return;
        }

        UUID handoffId = UUID.randomUUID();
        UUID actorId = currentUser.requireId();
        em.createNativeQuery("""
                INSERT INTO preplan_subcontract_requirement_handoffs (
                    id, plan_item_id,
                    source_supply_action_id, source_supply_action_allocation_id,
                    source_analysis_id, source_analysis_item_id,
                    source_parent_material_id,
                    target_analysis_id, target_analysis_item_id,
                    warehouse_id, target_goods_id, target_color_id, target_unit_id,
                    parent_output_qty,
                    source_analysis_version, source_analysis_fingerprint,
                    target_analysis_version, target_analysis_fingerprint,
                    idempotency_key, request_hash, created_by)
                VALUES (
                    :id, :planItemId, :sourceActionId, :sourceAllocationId,
                    :sourceAnalysisId, :sourceAnalysisItemId, :sourceMaterialId,
                    :targetAnalysisId, :targetAnalysisItemId,
                    :warehouseId, :goodsId, :colorId, :unitId, :outputQty,
                    :sourceVersion, :sourceFingerprint,
                    :targetVersion, :targetFingerprint,
                    :key, :requestHash, :actorId)
                """)
                .setParameter("id", handoffId)
                .setParameter("planItemId", claim.planItemId())
                .setParameter("sourceActionId", claim.sourceSupplyActionId())
                .setParameter("sourceAllocationId",
                        claim.sourceSupplyActionAllocationId())
                .setParameter("sourceAnalysisId", claim.sourceAnalysisId())
                .setParameter("sourceAnalysisItemId", claim.sourceAnalysisItemId())
                .setParameter("sourceMaterialId", claim.sourceMaterialLineId())
                .setParameter("targetAnalysisId", targetAnalysisId)
                .setParameter("targetAnalysisItemId", targetAnalysisItemId)
                .setParameter("warehouseId", claim.warehouseId())
                .setParameter("goodsId", claim.goodsId())
                .setParameter("colorId", claim.colorId())
                .setParameter("unitId", claim.unitId())
                .setParameter("outputQty", claim.requiredQty())
                .setParameter("sourceVersion", claim.sourceAnalysisVersion())
                .setParameter("sourceFingerprint", claim.sourceAnalysisFingerprint())
                .setParameter("targetVersion", target.version())
                .setParameter("targetFingerprint", target.fingerprint())
                .setParameter("key", key)
                .setParameter("requestHash", requestHash)
                .setParameter("actorId", actorId)
                .executeUpdate();

        Map<MappingIdentity, UUID> itemIds = new LinkedHashMap<>();
        int position = 0;
        for (MappingDraft mapping : mappings) {
            UUID itemId = UUID.randomUUID();
            String itemKey = "SC-HANDOFF-ITEM:" + handoffId + ":"
                    + mapping.targetMaterialId();
            em.createNativeQuery("""
                    INSERT INTO preplan_subcontract_requirement_handoff_items (
                        id, handoff_id, position,
                        source_analysis_id, source_analysis_material_id,
                        target_analysis_id, target_analysis_material_id,
                        relative_bom_path, bom_item_id,
                        goods_id, color_id, unit_id,
                        source_required_qty_snapshot,
                        target_required_qty_snapshot, transfer_capacity_qty,
                        idempotency_key, created_by)
                    VALUES (
                        :id, :handoffId, :position,
                        :sourceAnalysisId, :sourceMaterialId,
                        :targetAnalysisId, :targetMaterialId,
                        CAST(:relativePath AS uuid[]), :bomItemId,
                        :goodsId, :colorId, :unitId,
                        :sourceRequired, :targetRequired, :capacity,
                        :key, :actorId)
                    """)
                    .setParameter("id", itemId)
                    .setParameter("handoffId", handoffId)
                    .setParameter("position", ++position)
                    .setParameter("sourceAnalysisId", claim.sourceAnalysisId())
                    .setParameter("sourceMaterialId", mapping.sourceMaterialId())
                    .setParameter("targetAnalysisId", targetAnalysisId)
                    .setParameter("targetMaterialId", mapping.targetMaterialId())
                    .setParameter("relativePath", uuidArrayLiteral(mapping.relativePath()))
                    .setParameter("bomItemId", mapping.bomItemId())
                    .setParameter("goodsId", mapping.goodsId())
                    .setParameter("colorId", mapping.colorId())
                    .setParameter("unitId", mapping.unitId())
                    .setParameter("sourceRequired", mapping.sourceRequiredQty())
                    .setParameter("targetRequired", mapping.capacityQty())
                    .setParameter("capacity", mapping.capacityQty())
                    .setParameter("key", itemKey)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            itemIds.put(mapping.identity(), itemId);
        }

        Map<ClaimIdentity, UUID> claimIds = new LinkedHashMap<>();
        for (ClaimDraft draft : claims) {
            UUID itemId = itemIds.get(draft.mappingIdentity());
            UUID claimId = UUID.randomUUID();
            String claimKey = "SC-HANDOFF-CLAIM:" + itemId + ":"
                    + draft.allocationId();
            em.createNativeQuery("""
                    INSERT INTO preplan_subcontract_requirement_supply_claims (
                        id, handoff_item_id, source_analysis_id,
                        source_supply_action_id,
                        source_supply_action_allocation_id, claimed_qty,
                        idempotency_key, created_by)
                    VALUES (
                        :id, :itemId, :sourceAnalysisId, :actionId,
                        :allocationId, :qty, :key, :actorId)
                    """)
                    .setParameter("id", claimId)
                    .setParameter("itemId", itemId)
                    .setParameter("sourceAnalysisId", claim.sourceAnalysisId())
                    .setParameter("actionId", draft.actionId())
                    .setParameter("allocationId", draft.allocationId())
                    .setParameter("qty", draft.qty())
                    .setParameter("key", claimKey)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            claimIds.put(new ClaimIdentity(itemId, draft.allocationId()), claimId);
        }

        em.createNativeQuery("""
                INSERT INTO preplan_subcontract_requirement_handoff_events (
                    id, handoff_id, event_type, qty, counter_event_id,
                    reason, idempotency_key, created_by)
                VALUES (:id, :handoffId, 'TAKEOVER', :qty, NULL,
                    '委外订货行启动前置自制，定量接管原树子层需求', :key, :actorId)
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("handoffId", handoffId)
                .setParameter("qty", claim.requiredQty())
                .setParameter("key", "SC-HANDOFF-TAKEOVER:" + handoffId)
                .setParameter("actorId", actorId)
                .executeUpdate();

        for (MappingDraft mapping : mappings) {
            UUID itemId = itemIds.get(mapping.identity());
            transferExistingLots(itemId, mapping, claimIds,
                    claim.sourceAnalysisId(), targetAnalysisId, claim.warehouseId());
        }
        analyses.refreshLocked(claim.sourceAnalysisId());
        analyses.refreshLocked(targetAnalysisId);
    }

    /** A replay may never hide a pre-V447 source-linked START command. */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireReplayComplete(SubcontractPreparationPort.StartClaim claim) {
        HandoffHeader handoff = handoffByPlanItem(claim.planItemId(), false);
        if (claim.sourceAnalysisId() == null) {
            if (handoff != null) {
                throw conflict("直接委外前置自制重放出现异常权益交接账");
            }
            return;
        }
        if (handoff == null || claim.replayHandoffId() == null
                || !claim.replayHandoffId().equals(handoff.id())
                || !claim.sourceAnalysisId().equals(handoff.sourceAnalysisId())
                || !claim.sourceMaterialLineId().equals(handoff.sourceMaterialId())
                || !claim.replayAnalysisId().equals(handoff.targetAnalysisId())
                || !claim.replayAnalysisItemId().equals(handoff.targetAnalysisItemId())
                || activeTakeover(handoff.id()).compareTo(handoff.parentOutputQty()) != 0) {
            throw conflict("历史委外前置自制命令缺少完整 V447 权益交接账，禁止伪装重放");
        }
    }

    /**
     * New exact origins are handed to an active preparation before manual
     * cross-analysis priority sees the residual lot.
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyPriorityForOriginEvent(UUID originEventId) {
        tx.bind();
        PreplanStockEntitlementService.AvailableLot origin =
                entitlements.availableLotOrNull(originEventId, true);
        if (origin == null || origin.sourceExactPegId() == null) return;
        Object allocationValue = em.createNativeQuery("""
                SELECT exact.supply_action_allocation_id
                FROM preplan_analysis_stock_exact_pegs exact
                WHERE exact.id = :exactPegId
                """).setParameter("exactPegId", origin.sourceExactPegId())
                .getSingleResult();
        if (allocationValue == null) return;
        UUID allocationId = (UUID) allocationValue;

        List<HookTarget> targets = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT mapped.id, mapped.target_analysis_id,
                               mapped.target_analysis_material_id,
                               mapped.transfer_capacity_qty,
                               claim.id, claim.claimed_qty,
                               handoff.created_at, handoff.id
                        FROM preplan_subcontract_requirement_supply_claims claim
                        JOIN preplan_subcontract_requirement_handoff_items mapped
                          ON mapped.id = claim.handoff_item_id
                        JOIN preplan_subcontract_requirement_handoffs handoff
                          ON handoff.id = mapped.handoff_id
                        JOIN production_material_analyses target_analysis
                          ON target_analysis.id = mapped.target_analysis_id
                         AND target_analysis.is_deleted = FALSE
                         AND target_analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                        JOIN production_material_analysis_materials target_material
                          ON target_material.id = mapped.target_analysis_material_id
                         AND target_material.analysis_id = mapped.target_analysis_id
                         AND target_material.active = TRUE
                        WHERE claim.source_supply_action_allocation_id = :allocationId
                          AND mapped.source_analysis_id = :sourceAnalysisId
                          AND mapped.source_analysis_material_id = :sourceMaterialId
                          AND EXISTS (
                              SELECT 1
                              FROM preplan_subcontract_requirement_handoff_events take
                              WHERE take.handoff_id = handoff.id
                                AND take.event_type = 'TAKEOVER'
                                AND NOT EXISTS (
                                    SELECT 1
                                    FROM preplan_subcontract_requirement_handoff_events restore
                                    WHERE restore.handoff_id = handoff.id
                                      AND restore.event_type = 'RESTORE'
                                      AND restore.counter_event_id = take.id))
                        ORDER BY handoff.created_at, handoff.id, mapped.position, mapped.id
                        FOR UPDATE OF claim, mapped, handoff, target_material
                        """)
                        .setParameter("allocationId", allocationId)
                        .setParameter("sourceAnalysisId",
                                origin.beneficiaryAnalysisId())
                        .setParameter("sourceMaterialId",
                                origin.beneficiaryAnalysisMaterialId())).stream()
                .map(HookTarget::from)
                .toList();
        if (targets.isEmpty()) return;

        Set<UUID> touched = new LinkedHashSet<>();
        touched.add(origin.beneficiaryAnalysisId());
        PreplanStockEntitlementService.AvailableLot remainingLot = origin;
        for (HookTarget target : targets) {
            if (remainingLot == null || remainingLot.remainingQty().signum() <= 0) break;
            BigDecimal itemUsed = sliceQtyForItem(target.itemId());
            BigDecimal claimUsed = sliceQtyForClaim(target.claimId());
            BigDecimal capacity = target.capacityQty().subtract(itemUsed)
                    .min(target.claimedQty().subtract(claimUsed))
                    .max(BigDecimal.ZERO);
            BigDecimal take = capacity.min(remainingLot.remainingQty());
            if (take.signum() <= 0) continue;
            appendSliceAndEvents(target.itemId(), target.claimId(), remainingLot,
                    target.targetAnalysisId(), target.targetMaterialId(), take);
            touched.add(target.targetAnalysisId());
            remainingLot = entitlements.availableLotOrNull(originEventId, true);
        }
        touched.stream().sorted().forEach(analyses::refreshLocked);
    }

    /** Blocks cancelling any source action whose capacity is actively claimed. */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireSupplyActionCancellationSafe(UUID analysisId, UUID actionId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM preplan_subcontract_requirement_handoffs handoff
                WHERE handoff.source_analysis_id = :analysisId
                  AND (handoff.source_supply_action_id = :actionId OR EXISTS (
                      SELECT 1
                      FROM preplan_subcontract_requirement_handoff_items mapped
                      JOIN preplan_subcontract_requirement_supply_claims claim
                        ON claim.handoff_item_id = mapped.id
                      WHERE mapped.handoff_id = handoff.id
                        AND claim.source_supply_action_id = :actionId))
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_subcontract_requirement_handoff_events take
                      WHERE take.handoff_id = handoff.id
                        AND take.event_type = 'TAKEOVER'
                        AND NOT EXISTS (
                            SELECT 1
                            FROM preplan_subcontract_requirement_handoff_events restore
                            WHERE restore.handoff_id = handoff.id
                              AND restore.event_type = 'RESTORE'
                              AND restore.counter_event_id = take.id))
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId)
                .getSingleResult();
        if (count.longValue() > 0) {
            throw conflict("该备料行动已被委外前置自制接管；请先取消前置自制并恢复权益");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireSourceAnalysisCancellationSafe(UUID analysisId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM preplan_subcontract_requirement_handoffs handoff
                WHERE handoff.source_analysis_id = :analysisId
                  AND EXISTS (
                      SELECT 1
                      FROM preplan_subcontract_requirement_handoff_events take
                      WHERE take.handoff_id = handoff.id
                        AND take.event_type = 'TAKEOVER'
                        AND NOT EXISTS (
                            SELECT 1
                            FROM preplan_subcontract_requirement_handoff_events restore
                            WHERE restore.handoff_id = handoff.id
                              AND restore.event_type = 'RESTORE'
                              AND restore.counter_event_id = take.id))
                """).setParameter("analysisId", analysisId).getSingleResult();
        if (count.longValue() > 0) {
            throw conflict("该分析仍有生效中的委外前置自制接管，必须先反向前置生产链并恢复权益");
        }
    }

    /** Restores all unconsumed handoff lots before generic analysis release. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void restoreForTargetAnalysis(UUID targetAnalysisId, String cancellationKey) {
        tx.bind();
        List<HandoffHeader> headers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT handoff.id, handoff.plan_item_id,
                               handoff.source_analysis_id,
                               handoff.source_parent_material_id,
                               handoff.target_analysis_id,
                               handoff.target_analysis_item_id,
                               handoff.parent_output_qty, handoff.request_hash
                        FROM preplan_subcontract_requirement_handoffs handoff
                        WHERE handoff.target_analysis_id = :analysisId
                          AND EXISTS (
                              SELECT 1
                              FROM preplan_subcontract_requirement_handoff_events take
                              WHERE take.handoff_id = handoff.id
                                AND take.event_type = 'TAKEOVER'
                                AND NOT EXISTS (
                                    SELECT 1
                                    FROM preplan_subcontract_requirement_handoff_events restore
                                    WHERE restore.handoff_id = handoff.id
                                      AND restore.event_type = 'RESTORE'
                                      AND restore.counter_event_id = take.id))
                        ORDER BY handoff.id
                        FOR UPDATE OF handoff
                        """).setParameter("analysisId", targetAnalysisId)).stream()
                .map(HandoffHeader::fromCompact)
                .toList();
        for (HandoffHeader header : headers) {
            restoreHandoff(header, cancellationKey);
            analyses.refreshLocked(header.sourceAnalysisId());
        }
        if (!headers.isEmpty()) analyses.refreshLocked(targetAnalysisId);
        em.createNativeQuery("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'CANCELLED',
                    preparation_version = preparation_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE preparation_analysis_id = :analysisId
                  AND flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND preparation_status IN (
                      'IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                  AND prepared_qty = 0 AND issued_qty = 0
                  AND is_deleted = FALSE
                """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("analysisId", targetAnalysisId)
                .executeUpdate();
        Number stillActive = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM subcontract_material_plan_items
                WHERE preparation_analysis_id = :analysisId
                  AND flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND preparation_status NOT IN ('CANCELLED','OUTBOUND_COMPLETE')
                  AND is_deleted = FALSE
                """).setParameter("analysisId", targetAnalysisId)
                .getSingleResult();
        if (stillActive.longValue() > 0) {
            throw conflict("委外前置自制任务已有实收、出仓或并发状态变化，禁止取消分析");
        }
    }

    private void restoreHandoff(HandoffHeader header, String cancellationKey) {
        List<Object[]> slices = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT slice.id, slice.stock_reservation_id,
                               slice.source_entitlement_event_id,
                               slice.source_exact_peg_id, slice.qty,
                               mapped.source_analysis_id,
                               mapped.source_analysis_material_id,
                               mapped.target_analysis_id,
                               mapped.target_analysis_material_id,
                               outgoing.id, incoming.id
                        FROM preplan_subcontract_entitlement_handoff_slices slice
                        JOIN preplan_subcontract_requirement_handoff_items mapped
                          ON mapped.id = slice.handoff_item_id
                        JOIN preplan_stock_entitlement_events outgoing
                          ON outgoing.event_group_id = slice.id
                         AND outgoing.event_type = 'SUBCONTRACT_HANDOFF_OUT'
                        JOIN preplan_stock_entitlement_events incoming
                          ON incoming.event_group_id = slice.id
                         AND incoming.event_type = 'SUBCONTRACT_HANDOFF_IN'
                         AND incoming.counter_event_id = outgoing.id
                        WHERE mapped.handoff_id = :handoffId
                        ORDER BY mapped.position, slice.created_at, slice.id
                        FOR UPDATE OF slice, mapped, outgoing, incoming
                        """).setParameter("handoffId", header.id()));
        for (Object[] row : slices) {
            UUID incomingId = (UUID) row[10];
            PreplanStockEntitlementService.AvailableLot current =
                    currentRestoredFormalLot(incomingId);
            BigDecimal qty = decimal(row[4]);
            if (current == null || current.remainingQty().compareTo(qty) != 0
                    || !Objects.equals(current.beneficiaryAnalysisId(), row[7])
                    || !Objects.equals(current.beneficiaryAnalysisMaterialId(), row[8])) {
                throw conflict("前置自制权益已被正式计划、领料或再次转交，必须先完整反向下游");
            }
            UUID sliceId = (UUID) row[0];
            entitlements.appendReleaseLot(sliceId, current, qty,
                    current.reallocationId(),
                    "SC-HANDOFF-CANCEL:" + sliceId + ":RELEASE");
            entitlements.appendRestoreFromCounter(
                    sliceId, (UUID) row[1], (UUID) row[9],
                    (UUID) row[5], (UUID) row[6], qty,
                    current.reallocationId(), (UUID) row[3],
                    "SC-HANDOFF-CANCEL:" + sliceId + ":RESTORE");
        }
        Object[] takeover = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT id, qty
                        FROM preplan_subcontract_requirement_handoff_events
                        WHERE handoff_id = :handoffId AND event_type = 'TAKEOVER'
                        ORDER BY created_at, id
                        FOR UPDATE
                        """).setParameter("handoffId", header.id())).stream()
                .findFirst()
                .orElseThrow(() -> conflict("委外前置自制缺少需求接管事件"));
        em.createNativeQuery("""
                INSERT INTO preplan_subcontract_requirement_handoff_events (
                    id, handoff_id, event_type, qty, counter_event_id,
                    reason, idempotency_key, created_by)
                VALUES (:id, :handoffId, 'RESTORE', :qty, :counterId,
                    '取消委外前置自制后恢复原树子层需求', :key, :actorId)
                ON CONFLICT (idempotency_key) DO NOTHING
                """)
                .setParameter("id", UUID.randomUUID())
                .setParameter("handoffId", header.id())
                .setParameter("qty", takeover[1])
                .setParameter("counterId", takeover[0])
                .setParameter("key", "SC-HANDOFF-RESTORE:" + header.id() + ":"
                        + PlanningPackageFingerprint.sha256(List.of(cancellationKey)))
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private PreplanStockEntitlementService.AvailableLot currentRestoredFormalLot(
            UUID incomingEventId) {
        List<UUID> ids = NativeQueryResults.typedRows(em.createNativeQuery("""
                WITH RECURSIVE lineage(id) AS (
                    SELECT :incomingEventId
                    UNION ALL
                    SELECT restored.id
                    FROM lineage positive
                    JOIN preplan_stock_entitlement_events formalized
                      ON formalized.source_entitlement_event_id = positive.id
                     AND formalized.event_type = 'FORMALIZE'
                    JOIN preplan_stock_entitlement_events restored
                      ON restored.counter_event_id = formalized.id
                     AND restored.event_type = 'RESTORE'
                )
                SELECT id FROM lineage ORDER BY id
                """).setParameter("incomingEventId", incomingEventId), UUID.class);
        List<PreplanStockEntitlementService.AvailableLot> current = ids.stream()
                .map(id -> entitlements.availableLotOrNull(id, true))
                .filter(Objects::nonNull)
                .toList();
        return current.size() == 1 ? current.getFirst() : null;
    }

    private List<MappingDraft> mappingDrafts(
            UUID sourceAnalysisId, UUID sourceAnalysisItemId,
            UUID sourceParentMaterialId, UUID targetAnalysisId,
            UUID targetAnalysisItemId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH RECURSIVE source_tree AS (
                    SELECT child.id, child.analysis_item_id, child.node_key,
                           child.bom_item_id, child.goods_id, child.color_id,
                           child.unit_id, child.required_qty,
                           ARRAY[child.bom_item_id]::uuid[] AS relative_path
                    FROM production_material_analysis_materials parent
                    JOIN production_material_analysis_materials child
                      ON child.analysis_id = parent.analysis_id
                     AND child.analysis_item_id = parent.analysis_item_id
                     AND child.parent_node_key = parent.node_key
                     AND child.active = TRUE
                    WHERE parent.analysis_id = :sourceAnalysisId
                      AND parent.analysis_item_id = :sourceAnalysisItemId
                      AND parent.id = :sourceParentMaterialId
                      AND parent.active = TRUE
                    UNION ALL
                    SELECT child.id, child.analysis_item_id, child.node_key,
                           child.bom_item_id, child.goods_id, child.color_id,
                           child.unit_id, child.required_qty,
                           parent.relative_path || child.bom_item_id
                    FROM source_tree parent
                    JOIN production_material_analysis_materials child
                      ON child.analysis_id = :sourceAnalysisId
                     AND child.analysis_item_id = parent.analysis_item_id
                     AND child.parent_node_key = parent.node_key
                     AND child.active = TRUE
                ), target_tree AS (
                    SELECT material.id, material.analysis_item_id, material.node_key,
                           material.bom_item_id, material.goods_id, material.color_id,
                           material.unit_id, material.required_qty,
                           ARRAY[material.bom_item_id]::uuid[] AS relative_path
                    FROM production_material_analysis_materials material
                    WHERE material.analysis_id = :targetAnalysisId
                      AND material.analysis_item_id = :targetAnalysisItemId
                      AND material.depth = 1 AND material.active = TRUE
                    UNION ALL
                    SELECT child.id, child.analysis_item_id, child.node_key,
                           child.bom_item_id, child.goods_id, child.color_id,
                           child.unit_id, child.required_qty,
                           parent.relative_path || child.bom_item_id
                    FROM target_tree parent
                    JOIN production_material_analysis_materials child
                      ON child.analysis_id = :targetAnalysisId
                     AND child.analysis_item_id = :targetAnalysisItemId
                     AND child.parent_node_key = parent.node_key
                     AND child.active = TRUE
                )
                SELECT source.id, target.id,
                       array_to_string(target.relative_path, ','),
                       target.bom_item_id, target.goods_id, target.color_id,
                       target.unit_id, source.required_qty, target.required_qty
                FROM target_tree target
                LEFT JOIN source_tree source
                  ON source.relative_path = target.relative_path
                 AND source.bom_item_id = target.bom_item_id
                 AND source.goods_id = target.goods_id
                 AND source.color_id IS NOT DISTINCT FROM target.color_id
                 AND source.unit_id = target.unit_id
                WHERE target.required_qty > 0
                ORDER BY cardinality(target.relative_path), target.relative_path,
                         target.id
                """)
                .setParameter("sourceAnalysisId", sourceAnalysisId)
                .setParameter("sourceAnalysisItemId", sourceAnalysisItemId)
                .setParameter("sourceParentMaterialId", sourceParentMaterialId)
                .setParameter("targetAnalysisId", targetAnalysisId)
                .setParameter("targetAnalysisItemId", targetAnalysisItemId));
        List<MappingDraft> result = new ArrayList<>();
        Set<UUID> targets = new LinkedHashSet<>();
        for (Object[] row : rows) {
            if (row[0] == null || !targets.add((UUID) row[1])) {
                throw conflict("原分析与前置自制 BOM 路径无法按 UUID 唯一映射");
            }
            BigDecimal capacity = decimal(row[8]);
            if (capacity.signum() <= 0) continue;
            result.add(new MappingDraft(
                    (UUID) row[0], (UUID) row[1], parseUuidPath(row[2]),
                    (UUID) row[3], (UUID) row[4], (UUID) row[5], (UUID) row[6],
                    decimal(row[7]), capacity));
        }
        return List.copyOf(result);
    }

    private List<ClaimDraft> claimDrafts(
            UUID sourceAnalysisId, List<MappingDraft> mappings) {
        List<ClaimDraft> result = new ArrayList<>();
        for (MappingDraft mapping : mappings) {
            BigDecimal remaining = mapping.capacityQty();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                            SELECT action.id, allocation.id,
                                   GREATEST(allocation.allocated_qty - COALESCE((
                                       SELECT SUM(claim.claimed_qty)
                                       FROM preplan_subcontract_requirement_supply_claims
                                            claim
                                       WHERE claim.source_supply_action_allocation_id =
                                             allocation.id
                                   ), 0), 0)
                            FROM preplan_supply_action_allocations allocation
                            JOIN preplan_supply_actions action
                              ON action.id = allocation.action_id
                             AND action.analysis_id = allocation.analysis_id
                             AND action.status <> 'CANCELLED'
                            WHERE allocation.analysis_id = :analysisId
                              AND allocation.analysis_material_id = :materialId
                            ORDER BY action.created_at, action.id,
                                     allocation.created_at, allocation.id
                            FOR UPDATE OF action, allocation
                            """)
                            .setParameter("analysisId", sourceAnalysisId)
                            .setParameter("materialId", mapping.sourceMaterialId()));
            for (Object[] row : rows) {
                if (remaining.signum() <= 0) break;
                BigDecimal take = remaining.min(decimal(row[2]));
                if (take.signum() <= 0) continue;
                result.add(new ClaimDraft(mapping.identity(),
                        (UUID) row[0], (UUID) row[1], take));
                remaining = remaining.subtract(take);
            }
        }
        return List.copyOf(result);
    }

    private void transferExistingLots(
            UUID itemId, MappingDraft mapping,
            Map<ClaimIdentity, UUID> claimIds,
            UUID sourceAnalysisId, UUID targetAnalysisId, UUID warehouseId) {
        BigDecimal remaining = mapping.capacityQty();
        List<PreplanStockEntitlementService.AvailableLot> lots =
                entitlements.listAvailableBeneficiaryLots(
                        sourceAnalysisId, mapping.sourceMaterialId(), warehouseId,
                        mapping.goodsId(), mapping.colorId(), true);
        for (PreplanStockEntitlementService.AvailableLot lot : lots) {
            if (remaining.signum() <= 0) break;
            if (lot.sourceExactPegId() == null) continue;
            BigDecimal take = remaining.min(lot.remainingQty());
            if (take.signum() <= 0) continue;
            UUID allocationId = exactAllocationId(lot.sourceExactPegId());
            UUID claimId = claimIds.get(new ClaimIdentity(itemId, allocationId));
            appendSliceAndEvents(itemId, claimId, lot, targetAnalysisId,
                    mapping.targetMaterialId(), take);
            remaining = remaining.subtract(take);
        }
    }

    private void appendSliceAndEvents(
            UUID itemId, UUID claimId,
            PreplanStockEntitlementService.AvailableLot sourceLot,
            UUID targetAnalysisId, UUID targetMaterialId, BigDecimal qty) {
        String key = "SC-HANDOFF-SLICE:" + itemId + ":"
                + sourceLot.entitlementEventId();
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT id, supply_claim_id, stock_reservation_id,
                               source_entitlement_event_id, source_exact_peg_id, qty
                        FROM preplan_subcontract_entitlement_handoff_slices
                        WHERE handoff_item_id = :itemId
                          AND source_entitlement_event_id = :sourceEventId
                        FOR UPDATE
                        """)
                        .setParameter("itemId", itemId)
                        .setParameter("sourceEventId",
                                sourceLot.entitlementEventId()));
        UUID sliceId;
        if (replay.isEmpty()) {
            sliceId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO preplan_subcontract_entitlement_handoff_slices (
                        id, handoff_item_id, supply_claim_id,
                        stock_reservation_id, source_entitlement_event_id,
                        source_exact_peg_id, qty, idempotency_key, created_by)
                    VALUES (:id, :itemId, :claimId, :reservationId,
                        :sourceEventId, :exactPegId, :qty, :key, :actorId)
                    """)
                    .setParameter("id", sliceId)
                    .setParameter("itemId", itemId)
                    .setParameter("claimId", claimId)
                    .setParameter("reservationId", sourceLot.stockReservationId())
                    .setParameter("sourceEventId", sourceLot.entitlementEventId())
                    .setParameter("exactPegId", sourceLot.sourceExactPegId())
                    .setParameter("qty", qty)
                    .setParameter("key", key)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        } else {
            Object[] row = replay.getFirst();
            sliceId = (UUID) row[0];
            if (!Objects.equals(row[1], claimId)
                    || !Objects.equals(row[2], sourceLot.stockReservationId())
                    || !Objects.equals(row[3], sourceLot.entitlementEventId())
                    || !Objects.equals(row[4], sourceLot.sourceExactPegId())
                    || decimal(row[5]).compareTo(qty) != 0) {
                throw conflict("委外前置自制权益切片幂等载荷已变化");
            }
        }
        entitlements.appendPairedOutIn(
                sliceId, sourceLot, OUT, IN,
                targetAnalysisId, targetMaterialId,
                sourceLot.reallocationId(), qty, key);
    }

    private UUID exactAllocationId(UUID exactPegId) {
        List<UUID> ids = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT supply_action_allocation_id
                FROM preplan_analysis_stock_exact_pegs
                WHERE id = :id
                """).setParameter("id", exactPegId), UUID.class);
        return ids.size() == 1 ? ids.getFirst() : null;
    }

    private BigDecimal sliceQtyForItem(UUID itemId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(qty), 0)
                FROM preplan_subcontract_entitlement_handoff_slices
                WHERE handoff_item_id = :itemId
                """).setParameter("itemId", itemId).getSingleResult());
    }

    private BigDecimal sliceQtyForClaim(UUID claimId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(qty), 0)
                FROM preplan_subcontract_entitlement_handoff_slices
                WHERE supply_claim_id = :claimId
                """).setParameter("claimId", claimId).getSingleResult());
    }

    private BigDecimal activeTakeover(UUID handoffId) {
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(CASE event_type
                    WHEN 'TAKEOVER' THEN qty ELSE -qty END), 0)
                FROM preplan_subcontract_requirement_handoff_events
                WHERE handoff_id = :handoffId
                """).setParameter("handoffId", handoffId).getSingleResult());
    }

    private void requireNoUnexpectedHandoff(UUID planItemId) {
        if (handoffByPlanItem(planItemId, false) != null) {
            throw conflict("无原物料分析来源的委外任务出现异常权益交接账");
        }
    }

    private HandoffHeader handoffByPlanItem(UUID planItemId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, plan_item_id, source_supply_action_id,
                       source_supply_action_allocation_id,
                       source_analysis_id, source_analysis_item_id,
                       source_parent_material_id,
                       target_analysis_id, target_analysis_item_id,
                       warehouse_id, target_goods_id, target_color_id, target_unit_id,
                       parent_output_qty, source_analysis_version,
                       source_analysis_fingerprint, target_analysis_version,
                       target_analysis_fingerprint, request_hash
                FROM preplan_subcontract_requirement_handoffs
                WHERE plan_item_id = :planItemId
                """ + lock).setParameter("planItemId", planItemId));
        if (rows.isEmpty()) return null;
        if (rows.size() != 1) throw conflict("委外前置自制存在重复权益交接账");
        return HandoffHeader.from(rows.getFirst());
    }

    private static void requireSameHandoff(
            HandoffHeader header, SubcontractPreparationPort.StartClaim claim,
            UUID targetAnalysisId, UUID targetAnalysisItemId, String requestHash) {
        if (!Objects.equals(header.sourceActionId(), claim.sourceSupplyActionId())
                || !Objects.equals(header.sourceAllocationId(),
                        claim.sourceSupplyActionAllocationId())
                || !Objects.equals(header.sourceAnalysisId(), claim.sourceAnalysisId())
                || !Objects.equals(header.sourceMaterialId(),
                        claim.sourceMaterialLineId())
                || !Objects.equals(header.targetAnalysisId(), targetAnalysisId)
                || !Objects.equals(header.targetAnalysisItemId(), targetAnalysisItemId)
                || !Objects.equals(header.requestHash(), requestHash)) {
            throw conflict("委外前置自制权益交接幂等载荷已变化");
        }
    }

    private static String handoffHash(
            SubcontractPreparationPort.StartClaim claim,
            UUID targetAnalysisId, UUID targetAnalysisItemId,
            MaterialAnalysisService.AnalysisHeader target,
            List<MappingDraft> mappings, List<ClaimDraft> claims) {
        List<String> parts = new ArrayList<>(List.of(
                "SC-HANDOFF-V1", claim.planItemId().toString(),
                claim.sourceSupplyActionId().toString(),
                claim.sourceSupplyActionAllocationId().toString(),
                claim.sourceAnalysisId().toString(),
                claim.sourceMaterialLineId().toString(),
                targetAnalysisId.toString(), targetAnalysisItemId.toString(),
                claim.warehouseId().toString(),
                claim.requiredQty().stripTrailingZeros().toPlainString(),
                Long.toString(claim.sourceAnalysisVersion()),
                claim.sourceAnalysisFingerprint(), Long.toString(target.version()),
                target.fingerprint()));
        mappings.stream().sorted(Comparator.comparing(MappingDraft::pathText))
                .forEach(mapping -> parts.add("MAP|" + mapping.pathText() + "|"
                        + mapping.bomItemId() + "|" + mapping.goodsId() + "|"
                        + Objects.toString(mapping.colorId(), "-") + "|"
                        + mapping.unitId() + "|" + mapping.sourceMaterialId() + "|"
                        + mapping.targetMaterialId() + "|"
                        + mapping.capacityQty().stripTrailingZeros().toPlainString()));
        claims.stream().sorted(Comparator.comparing(
                        draft -> draft.allocationId().toString()))
                .forEach(draft -> parts.add("CLAIM|" + draft.mappingIdentity()
                        + "|" + draft.allocationId() + "|"
                        + draft.qty().stripTrailingZeros().toPlainString()));
        return PlanningPackageFingerprint.sha256(parts);
    }

    private static String uuidArrayLiteral(List<UUID> path) {
        return "{" + path.stream().map(UUID::toString)
                .reduce((left, right) -> left + "," + right).orElse("") + "}";
    }

    private static List<UUID> parseUuidPath(Object raw) {
        if (raw == null || raw.toString().isBlank()) return List.of();
        return List.of(raw.toString().split(",")).stream()
                .map(UUID::fromString).toList();
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal number
                ? number : new BigDecimal(value.toString());
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record MappingIdentity(UUID sourceMaterialId, UUID targetMaterialId) {
    }

    private record ClaimIdentity(UUID itemId, UUID allocationId) {
    }

    private record MappingDraft(
            UUID sourceMaterialId, UUID targetMaterialId, List<UUID> relativePath,
            UUID bomItemId, UUID goodsId, UUID colorId, UUID unitId,
            BigDecimal sourceRequiredQty, BigDecimal capacityQty) {
        MappingIdentity identity() {
            return new MappingIdentity(sourceMaterialId, targetMaterialId);
        }

        String pathText() {
            return relativePath.stream().map(UUID::toString)
                    .reduce((left, right) -> left + "/" + right).orElse("");
        }
    }

    private record ClaimDraft(
            MappingIdentity mappingIdentity, UUID actionId,
            UUID allocationId, BigDecimal qty) {
    }

    private record HookTarget(
            UUID itemId, UUID targetAnalysisId, UUID targetMaterialId,
            BigDecimal capacityQty, UUID claimId, BigDecimal claimedQty) {
        static HookTarget from(Object[] row) {
            return new HookTarget((UUID) row[0], (UUID) row[1], (UUID) row[2],
                    decimal(row[3]), (UUID) row[4], decimal(row[5]));
        }
    }

    private record HandoffHeader(
            UUID id, UUID planItemId, UUID sourceActionId, UUID sourceAllocationId,
            UUID sourceAnalysisId, UUID sourceAnalysisItemId, UUID sourceMaterialId,
            UUID targetAnalysisId, UUID targetAnalysisItemId, UUID warehouseId,
            UUID goodsId, UUID colorId, UUID unitId, BigDecimal parentOutputQty,
            long sourceVersion, String sourceFingerprint,
            long targetVersion, String targetFingerprint, String requestHash) {
        static HandoffHeader from(Object[] row) {
            return new HandoffHeader(
                    (UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    (UUID) row[4], (UUID) row[5], (UUID) row[6], (UUID) row[7],
                    (UUID) row[8], (UUID) row[9], (UUID) row[10], (UUID) row[11],
                    (UUID) row[12], decimal(row[13]), ((Number) row[14]).longValue(),
                    Objects.toString(row[15], null), ((Number) row[16]).longValue(),
                    Objects.toString(row[17], null), Objects.toString(row[18], null));
        }

        static HandoffHeader fromCompact(Object[] row) {
            return new HandoffHeader(
                    (UUID) row[0], (UUID) row[1], null, null,
                    (UUID) row[2], null, (UUID) row[3],
                    (UUID) row[4], (UUID) row[5], null,
                    null, null, null, decimal(row[6]), 0, null, 0, null,
                    Objects.toString(row[7], null));
        }
    }
}
