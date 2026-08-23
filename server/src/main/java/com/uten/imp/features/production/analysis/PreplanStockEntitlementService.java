package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Append-only V309 entitlement ledger primitives.
 *
 * <p>The physical reservation remains authoritative for inventory. Entitlement
 * events only split that reservation between analysis material nodes. Callers
 * must hold the canonical goods/color advisory lock before requesting write
 * locks from this service.
 */
@Service
@RequiredArgsConstructor
public class PreplanStockEntitlementService {

    private static final short RESERVATION_EFFECTIVE = 0;
    private static final short RESERVATION_DONE = 1;
    private static final String OWNER_PREPLAN = "PREPLAN_ANALYSIS";

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    /** Only immutable origin supply may be selected by a manual reallocation. */
    @Transactional(propagation = Propagation.MANDATORY)
    public List<AvailableLot> listAvailableOriginalLots(
            UUID analysisId,
            UUID analysisMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            boolean forUpdate) {
        tx.bind();
        String lock = forUpdate ? " FOR UPDATE OF positive, reservation" : "";
        Query query = em.createNativeQuery("""
                WITH RECURSIVE entitlement_lineage AS (
                    SELECT positive.id AS lot_id,
                           positive.id AS current_positive_event_id,
                           positive.event_type,
                           0 AS depth
                    FROM preplan_stock_entitlement_events positive
                    WHERE positive.beneficiary_analysis_id = :analysisId
                      AND positive.beneficiary_analysis_material_id = :materialId
                      AND positive.event_type IN (
                          'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                          'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
                    UNION ALL
                    SELECT lineage.lot_id,
                           source_positive.id,
                           source_positive.event_type,
                           lineage.depth + 1
                    FROM entitlement_lineage lineage
                    JOIN preplan_stock_entitlement_events current_positive
                      ON current_positive.id =
                         lineage.current_positive_event_id
                    JOIN preplan_stock_entitlement_events counter_negative
                      ON current_positive.event_type IN (
                         'RESTORE', 'MAKE_DELEGATE_IN')
                     AND counter_negative.id =
                         current_positive.counter_event_id
                    JOIN preplan_stock_entitlement_events source_positive
                      ON source_positive.id =
                         counter_negative.source_entitlement_event_id
                    WHERE lineage.depth < 64
                )
                SELECT positive.id, positive.event_group_id,
                       positive.stock_reservation_id,
                       positive.beneficiary_analysis_id,
                       positive.beneficiary_analysis_material_id,
                       positive.event_type, positive.reallocation_id,
                       positive.source_exact_peg_id,
                       positive.qty - COALESCE((
                           SELECT SUM(negative.qty)
                           FROM preplan_stock_entitlement_events negative
                           WHERE negative.source_entitlement_event_id = positive.id
                             AND negative.event_type IN (
                                 'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                       ), 0) AS remaining_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id
                FROM preplan_stock_entitlement_events positive
                JOIN stock_reservations reservation
                  ON reservation.id = positive.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                 AND reservation.owner_type = 'PREPLAN_ANALYSIS'
                WHERE positive.beneficiary_analysis_id = :analysisId
                  AND positive.beneficiary_analysis_material_id = :materialId
                  AND reservation.warehouse_id = :warehouseId
                  AND reservation.goods_id = :goodsId
                  AND reservation.color_id IS NOT DISTINCT FROM
                      CAST(:colorId AS uuid)
                  AND (
                      positive.event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE')
                      OR (
                          positive.event_type IN ('RESTORE', 'MAKE_DELEGATE_IN')
                          AND EXISTS (
                              SELECT 1
                              FROM entitlement_lineage lineage
                              WHERE lineage.lot_id = positive.id
                                AND lineage.event_type IN (
                                    'ORIGIN_IQC', 'ORIGIN_MAKE'))
                          AND NOT EXISTS (
                              SELECT 1
                              FROM entitlement_lineage lineage
                              WHERE lineage.lot_id = positive.id
                                AND lineage.event_type IN (
                                    'REALLOCATE_IN', 'PRIORITY_IN'))
                      )
                  )
                  AND positive.qty - COALESCE((
                      SELECT SUM(negative.qty)
                      FROM preplan_stock_entitlement_events negative
                      WHERE negative.source_entitlement_event_id = positive.id
                        AND negative.event_type IN (
                            'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                            'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                  ), 0) > 0
                ORDER BY positive.created_at, positive.id
                """ + lock)
                .setParameter("analysisId", analysisId)
                .setParameter("materialId", analysisMaterialId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId);
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(AvailableLot::from)
                .toList();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<AvailableLot> listAvailableBeneficiaryLots(
            UUID analysisId,
            UUID analysisMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            boolean forUpdate) {
        tx.bind();
        String lock = forUpdate ? " FOR UPDATE OF positive, reservation" : "";
        Query query = em.createNativeQuery("""
                SELECT positive.id, positive.event_group_id,
                       positive.stock_reservation_id,
                       positive.beneficiary_analysis_id,
                       positive.beneficiary_analysis_material_id,
                       positive.event_type, positive.reallocation_id,
                       positive.source_exact_peg_id,
                       positive.qty - COALESCE((
                           SELECT SUM(negative.qty)
                           FROM preplan_stock_entitlement_events negative
                           WHERE negative.source_entitlement_event_id = positive.id
                             AND negative.event_type IN (
                                 'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                       ), 0) AS remaining_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id
                FROM preplan_stock_entitlement_events positive
                JOIN stock_reservations reservation
                  ON reservation.id = positive.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                 AND reservation.owner_type = 'PREPLAN_ANALYSIS'
                WHERE positive.event_type IN (
                        'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                        'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
                  AND positive.beneficiary_analysis_id = :analysisId
                  AND positive.beneficiary_analysis_material_id = :materialId
                  AND reservation.warehouse_id = :warehouseId
                  AND reservation.goods_id = :goodsId
                  AND reservation.color_id IS NOT DISTINCT FROM
                      CAST(:colorId AS uuid)
                  AND positive.qty - COALESCE((
                      SELECT SUM(negative.qty)
                      FROM preplan_stock_entitlement_events negative
                      WHERE negative.source_entitlement_event_id = positive.id
                        AND negative.event_type IN (
                            'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                            'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                  ), 0) > 0
                ORDER BY positive.created_at, positive.id
                """ + lock)
                .setParameter("analysisId", analysisId)
                .setParameter("materialId", analysisMaterialId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId);
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(AvailableLot::from)
                .toList();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public AvailableLot requireAvailableLot(
            UUID positiveEventId, boolean forUpdate) {
        tx.bind();
        String lock = forUpdate ? " FOR UPDATE OF positive, reservation" : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT positive.id, positive.event_group_id,
                               positive.stock_reservation_id,
                               positive.beneficiary_analysis_id,
                               positive.beneficiary_analysis_material_id,
                               positive.event_type, positive.reallocation_id,
                               positive.source_exact_peg_id,
                               positive.qty - COALESCE((
                                   SELECT SUM(negative.qty)
                                   FROM preplan_stock_entitlement_events negative
                                   WHERE negative.source_entitlement_event_id =
                                       positive.id
                                     AND negative.event_type IN (
                                         'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                         'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                               ), 0) AS remaining_qty,
                               reservation.goods_id, reservation.color_id,
                               reservation.warehouse_id
                        FROM preplan_stock_entitlement_events positive
                        JOIN stock_reservations reservation
                          ON reservation.id = positive.stock_reservation_id
                         AND reservation.is_deleted = FALSE
                         AND reservation.owner_type = 'PREPLAN_ANALYSIS'
                        WHERE positive.id = :eventId
                          AND positive.event_type IN (
                              'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                              'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
                          AND positive.qty - COALESCE((
                              SELECT SUM(negative.qty)
                              FROM preplan_stock_entitlement_events negative
                              WHERE negative.source_entitlement_event_id =
                                  positive.id
                                AND negative.event_type IN (
                                    'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                    'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                          ), 0) > 0
                        """ + lock).setParameter("eventId", positiveEventId));
        if (rows.size() != 1) {
            throw conflict("Entitlement lot is no longer available");
        }
        return AvailableLot.from(rows.getFirst());
    }

    @Transactional(readOnly = true)
    public List<BeneficiaryBalance> beneficiaryBalances(
            UUID analysisId, UUID warehouseId,
            UUID goodsId, UUID colorId) {
        Query query = em.createNativeQuery("""
                SELECT balance.stock_reservation_id,
                       balance.beneficiary_analysis_id,
                       balance.beneficiary_analysis_material_id,
                       balance.effective_qty
                FROM v_preplan_stock_entitlement_beneficiary_balance balance
                JOIN stock_reservations reservation
                  ON reservation.id = balance.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                WHERE balance.beneficiary_analysis_id = :analysisId
                  AND reservation.warehouse_id = :warehouseId
                  AND reservation.goods_id = :goodsId
                  AND reservation.color_id IS NOT DISTINCT FROM
                      CAST(:colorId AS uuid)
                ORDER BY balance.beneficiary_analysis_material_id,
                         balance.stock_reservation_id
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId);
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(row -> new BeneficiaryBalance(
                        uuid(row[0]), uuid(row[1]), uuid(row[2]), decimal(row[3])))
                .toList();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public OriginAppendResult appendOriginIqc(
            UUID eventGroupId, UUID reservationId,
            UUID analysisId, UUID materialId, BigDecimal qty,
            UUID exactPegId, String receiptType, UUID receiptId,
            UUID dispositionEventId, String idempotencyKey) {
        tx.bind();
        return insertEventWithResult(new EventDraft(
                eventGroupId, reservationId, analysisId, materialId,
                "ORIGIN_IQC", qty, null, null, exactPegId,
                receiptType, receiptId, dispositionEventId,
                null, null, null, null, null, null, idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public OriginAppendResult appendOriginMake(
            UUID eventGroupId, UUID reservationId,
            UUID analysisId, UUID materialId, BigDecimal qty,
            UUID exactPegId, UUID stockDocumentId,
            UUID stockDocumentItemId, String idempotencyKey) {
        tx.bind();
        return insertEventWithResult(new EventDraft(
                eventGroupId, reservationId, analysisId, materialId,
                "ORIGIN_MAKE", qty, null, null, exactPegId,
                "MAKE", stockDocumentId, null,
                stockDocumentId, stockDocumentItemId,
                null, null, null, null, idempotencyKey));
    }

    /**
     * Moves exact entitlement from the former parent-tree child path to the
     * matching depth-one path owned by a newly-created MAKE_COMPONENT item.
     *
     * <p>The caller must already hold inventory-dimension locks and the analysis
     * header lock. The first refresh creates the target material rows; a second
     * refresh consumes the new beneficiary projection.</p>
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public BigDecimal delegateMakeEntitlements(UUID analysisId, UUID actionId) {
        tx.bind();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT parent_material.id, child.id,
                       source_material.id, target_material.id,
                       analysis.warehouse_id,
                       target_material.goods_id, target_material.color_id,
                       target_material.unit_id, target_material.required_qty
                FROM preplan_supply_actions action
                JOIN production_material_analyses analysis
                  ON analysis.id = action.analysis_id
                 AND analysis.is_deleted = FALSE
                 AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                JOIN production_material_analysis_items child
                  ON child.id = action.external_document_id
                 AND child.analysis_id = action.analysis_id
                 AND child.source_type = 'MAKE_COMPONENT'
                 AND child.is_deleted = FALSE
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.action_id = action.id
                 AND allocation.analysis_id = action.analysis_id
                JOIN production_material_analysis_materials parent_material
                  ON parent_material.id = allocation.analysis_material_id
                 AND parent_material.analysis_id = action.analysis_id
                 AND parent_material.active = TRUE
                 AND parent_material.confirmed_route = 'MAKE'
                JOIN production_material_analysis_materials source_material
                  ON source_material.analysis_id = action.analysis_id
                 AND source_material.analysis_item_id =
                     parent_material.analysis_item_id
                 AND source_material.parent_node_key = parent_material.node_key
                 AND source_material.active = TRUE
                JOIN production_material_analysis_materials target_material
                  ON target_material.analysis_id = action.analysis_id
                 AND target_material.analysis_item_id = child.id
                 AND target_material.depth = 1
                 AND target_material.bom_item_id = source_material.bom_item_id
                 AND target_material.goods_id = source_material.goods_id
                 AND target_material.color_id IS NOT DISTINCT FROM
                     source_material.color_id
                 AND target_material.unit_id = source_material.unit_id
                 AND target_material.active = TRUE
                WHERE action.id = :actionId
                  AND action.analysis_id = :analysisId
                  AND action.route = 'MAKE'
                  AND action.status <> 'CANCELLED'
                  AND action.external_document_type = 'PREPLAN_MAKE_TASK'
                  AND child.parent_analysis_material_id = parent_material.id
                ORDER BY target_material.id, source_material.id
                FOR UPDATE OF action, allocation, child, parent_material,
                              source_material, target_material
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId));
        Map<UUID, MakeDelegationTarget> targets = new LinkedHashMap<>();
        for (Object[] row : rows) {
            MakeDelegationTarget target = new MakeDelegationTarget(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                    uuid(row[4]), uuid(row[5]), uuid(row[6]), uuid(row[7]),
                    decimal(row[8]));
            targets.putIfAbsent(target.targetMaterialId(), target);
        }
        BigDecimal transferred = BigDecimal.ZERO;
        for (MakeDelegationTarget target : targets.values()) {
            BigDecimal alreadyOwned = beneficiaryBalances(
                    analysisId, target.warehouseId(),
                    target.goodsId(), target.colorId()).stream()
                    .filter(balance -> balance.beneficiaryAnalysisMaterialId()
                            .equals(target.targetMaterialId()))
                    .map(BeneficiaryBalance::effectiveQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            List<AvailableLot> lots = listAvailableBeneficiaryLots(
                    analysisId, target.sourceMaterialId(), target.warehouseId(),
                    target.goodsId(), target.colorId(), true);
            for (AvailableLot lot : lots) {
                BigDecimal take = makeDelegationTake(
                        target.requiredQty(), alreadyOwned, lot.remainingQty());
                if (take.signum() <= 0) break;
                appendMakeDelegation(actionId, analysisId, target, lot, take);
                alreadyOwned = alreadyOwned.add(take);
                transferred = transferred.add(take);
            }
        }
        return transferred;
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void restoreMakeDelegationsForAction(
            UUID analysisId, UUID actionId, String idempotencyPrefix) {
        tx.bind();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT delegation.id,
                       delegation.source_analysis_material_id,
                       delegation.stock_reservation_id, delegation.qty,
                       outgoing.id, incoming.id
                FROM preplan_make_entitlement_delegations delegation
                JOIN preplan_stock_entitlement_events outgoing
                  ON outgoing.event_group_id = delegation.id
                 AND outgoing.event_type = 'MAKE_DELEGATE_OUT'
                JOIN preplan_stock_entitlement_events incoming
                  ON incoming.event_group_id = delegation.id
                 AND incoming.event_type = 'MAKE_DELEGATE_IN'
                 AND incoming.counter_event_id = outgoing.id
                WHERE delegation.analysis_id = :analysisId
                  AND delegation.supply_action_id = :actionId
                ORDER BY delegation.created_at, delegation.id
                FOR UPDATE OF delegation, outgoing, incoming
                """)
                .setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId));
        List<MakeDelegationRestore> restores = new ArrayList<>();
        for (Object[] row : rows) {
            UUID delegationId = uuid(row[0]);
            BigDecimal qty = decimal(row[3]);
            AvailableLot current = requireAvailableLot(uuid(row[5]), true);
            if (current.remainingQty().compareTo(qty) != 0) {
                throw conflict(
                        "自制备料权益已被正式计划、领料或让料使用，不能撤回自制任务");
            }
            restores.add(new MakeDelegationRestore(
                    delegationId, uuid(row[1]), uuid(row[2]), qty,
                    uuid(row[4]), current));
        }
        for (MakeDelegationRestore restore : restores) {
            appendReleaseLot(
                    restore.delegationId(), restore.currentLot(),
                    restore.qty(), restore.currentLot().reallocationId(),
                    idempotencyPrefix + ":" + restore.delegationId() + ":RELEASE");
            appendRestoreFromCounter(
                    restore.delegationId(), restore.stockReservationId(),
                    restore.outEventId(), analysisId, restore.sourceMaterialId(),
                    restore.qty(), restore.currentLot().reallocationId(),
                    restore.currentLot().sourceExactPegId(),
                    idempotencyPrefix + ":" + restore.delegationId() + ":RESTORE");
        }
    }

    static BigDecimal makeDelegationTake(
            BigDecimal required, BigDecimal alreadyOwned,
            BigDecimal lotRemaining) {
        if (required == null || alreadyOwned == null || lotRemaining == null) {
            return BigDecimal.ZERO;
        }
        return required.subtract(alreadyOwned).max(BigDecimal.ZERO)
                .min(lotRemaining.max(BigDecimal.ZERO));
    }

    private void appendMakeDelegation(
            UUID actionId, UUID analysisId, MakeDelegationTarget target,
            AvailableLot sourceLot, BigDecimal qty) {
        requirePositiveWithin(qty, sourceLot.remainingQty(),
                "MAKE delegation exceeds the source entitlement balance");
        String key = "MAKE-DELEGATE:" + actionId + ":"
                + sourceLot.entitlementEventId() + ":"
                + target.targetMaterialId();
        UUID proposedId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                INSERT INTO preplan_make_entitlement_delegations (
                    id, analysis_id, supply_action_id,
                    parent_analysis_material_id, child_analysis_item_id,
                    source_analysis_material_id, target_analysis_material_id,
                    stock_reservation_id, source_entitlement_event_id,
                    qty, idempotency_key, created_by
                ) VALUES (
                    :id, :analysisId, :actionId,
                    :parentMaterialId, :childItemId,
                    :sourceMaterialId, :targetMaterialId,
                    :reservationId, :sourceEventId,
                    :qty, :key, :actorId
                )
                ON CONFLICT (idempotency_key) DO NOTHING
                """)
                .setParameter("id", proposedId)
                .setParameter("analysisId", analysisId)
                .setParameter("actionId", actionId)
                .setParameter("parentMaterialId", target.parentMaterialId())
                .setParameter("childItemId", target.childItemId())
                .setParameter("sourceMaterialId", target.sourceMaterialId())
                .setParameter("targetMaterialId", target.targetMaterialId())
                .setParameter("reservationId", sourceLot.stockReservationId())
                .setParameter("sourceEventId", sourceLot.entitlementEventId())
                .setParameter("qty", qty)
                .setParameter("key", key)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT id, analysis_id, supply_action_id,
                               parent_analysis_material_id,
                               child_analysis_item_id,
                               source_analysis_material_id,
                               target_analysis_material_id,
                               stock_reservation_id,
                               source_entitlement_event_id, qty
                        FROM preplan_make_entitlement_delegations
                        WHERE idempotency_key = :key
                        FOR UPDATE
                        """).setParameter("key", key));
        if (replay.size() != 1) {
            throw new IllegalStateException(
                    "MAKE entitlement delegation was not persisted");
        }
        Object[] persisted = replay.getFirst();
        if (!Objects.equals(uuid(persisted[1]), analysisId)
                || !Objects.equals(uuid(persisted[2]), actionId)
                || !Objects.equals(
                        uuid(persisted[3]), target.parentMaterialId())
                || !Objects.equals(uuid(persisted[4]), target.childItemId())
                || !Objects.equals(
                        uuid(persisted[5]), target.sourceMaterialId())
                || !Objects.equals(
                        uuid(persisted[6]), target.targetMaterialId())
                || !Objects.equals(
                        uuid(persisted[7]), sourceLot.stockReservationId())
                || !Objects.equals(
                        uuid(persisted[8]), sourceLot.entitlementEventId())
                || decimal(persisted[9]).compareTo(qty) != 0) {
            throw conflict(
                    "MAKE entitlement delegation idempotency payload changed");
        }
        if (inserted != 0 && inserted != 1) {
            throw new IllegalStateException(
                    "Unexpected MAKE delegation insert count");
        }
        UUID delegationId = uuid(persisted[0]);
        UUID outId = insertEvent(new EventDraft(
                delegationId, sourceLot.stockReservationId(), analysisId,
                target.sourceMaterialId(), "MAKE_DELEGATE_OUT", qty,
                sourceLot.entitlementEventId(), sourceLot.reallocationId(),
                null, null, null, null, null, null,
                null, null, null, null, key + ":OUT"));
        insertEvent(new EventDraft(
                delegationId, sourceLot.stockReservationId(), analysisId,
                target.targetMaterialId(), "MAKE_DELEGATE_IN", qty,
                null, sourceLot.reallocationId(),
                sourceLot.sourceExactPegId(),
                null, null, null, null, null,
                null, null, null, outId, key + ":IN"));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendFormalize(
            UUID eventGroupId,
            UUID sourceEntitlementEventId,
            UUID sourceReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            BigDecimal qty,
            UUID packageId,
            UUID demandId,
            UUID formalReservationId,
            String idempotencyKey) {
        tx.bind();
        AvailableLot sourceLot = listRemainingLotsForReservation(
                sourceReservationId, true).stream()
                .filter(lot -> lot.entitlementEventId()
                        .equals(sourceEntitlementEventId))
                .findFirst()
                .orElseThrow(() -> conflict(
                        "Source entitlement lot is no longer available"));
        if (!sourceLot.beneficiaryAnalysisId().equals(beneficiaryAnalysisId)
                || !sourceLot.beneficiaryAnalysisMaterialId()
                        .equals(beneficiaryAnalysisMaterialId)) {
            throw conflict("Source entitlement beneficiary changed");
        }
        return appendFormalize(
                eventGroupId, sourceLot, qty,
                packageId, demandId, formalReservationId,
                idempotencyKey);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendFormalize(
            UUID eventGroupId, AvailableLot sourceLot, BigDecimal qty,
            UUID packageId, UUID demandId, UUID formalReservationId,
            String idempotencyKey) {
        tx.bind();
        requirePositiveWithin(qty, sourceLot.remainingQty(),
                "Formalized entitlement exceeds the source lot balance");
        return insertEvent(new EventDraft(
                eventGroupId, sourceLot.stockReservationId(),
                sourceLot.beneficiaryAnalysisId(),
                sourceLot.beneficiaryAnalysisMaterialId(),
                "FORMALIZE", qty, sourceLot.entitlementEventId(),
                sourceLot.reallocationId(), null,
                null, null, null, null, null,
                packageId, demandId, formalReservationId,
                null, idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendRestore(
            UUID eventGroupId, Formalization formalization,
            String idempotencyKey) {
        tx.bind();
        return insertEvent(new EventDraft(
                eventGroupId, formalization.sourceStockReservationId(),
                formalization.beneficiaryAnalysisId(),
                formalization.beneficiaryAnalysisMaterialId(),
                "RESTORE", formalization.qty(), null, formalization.reallocationId(),
                formalization.sourceExactPegId(),
                null, null, null, null, null,
                null, null, null, formalization.formalizeEventId(),
                idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void consumePhysicalForFormalize(UUID reservationId, BigDecimal qty) {
        tx.bind();
        int updated = em.createNativeQuery("""
                UPDATE stock_reservations
                SET released_qty = released_qty + :qty,
                    status = CASE
                        WHEN consumed_qty + released_qty + :qty >= qty
                        THEN :done ELSE :effective END,
                    release_reason = 'TRANSFERRED_TO_PLAN',
                    lock_version = lock_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :id
                  AND is_deleted = FALSE
                  AND owner_type = :ownerType
                  AND status = :effective
                  AND qty - consumed_qty - released_qty >= :qty
                """)
                .setParameter("qty", qty)
                .setParameter("done", RESERVATION_DONE)
                .setParameter("effective", RESERVATION_EFFECTIVE)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("id", reservationId)
                .setParameter("ownerType", OWNER_PREPLAN)
                .executeUpdate();
        if (updated != 1) {
            throw conflict("Analysis stock entitlement changed concurrently");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void restorePhysicalAfterFormalRelease(
            UUID reservationId, BigDecimal qty) {
        tx.bind();
        int updated = em.createNativeQuery("""
                UPDATE stock_reservations
                SET released_qty = released_qty - :qty,
                    status = :effective,
                    release_reason = CASE
                        WHEN released_qty - :qty = 0 THEN NULL
                        ELSE 'TRANSFERRED_TO_PLAN' END,
                    lock_version = lock_version + 1,
                    updated_at = now(), updated_by = :actorId
                WHERE id = :id
                  AND is_deleted = FALSE
                  AND owner_type = :ownerType
                  AND consumed_qty = 0
                  AND released_qty >= :qty
                  AND release_reason = 'TRANSFERRED_TO_PLAN'
                """)
                .setParameter("qty", qty)
                .setParameter("effective", RESERVATION_EFFECTIVE)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("id", reservationId)
                .setParameter("ownerType", OWNER_PREPLAN)
                .executeUpdate();
        if (updated != 1) {
            throw conflict("Source analysis reservation cannot be restored safely");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void appendReleaseForReservation(
            UUID reservationId, UUID eventGroupId, String idempotencyPrefix) {
        tx.bind();
        List<AvailableLot> lots = listRemainingLotsForReservation(reservationId, true);
        int sequence = 0;
        for (AvailableLot lot : lots) {
            sequence++;
            insertEvent(new EventDraft(
                    eventGroupId, reservationId,
                    lot.beneficiaryAnalysisId(), lot.beneficiaryAnalysisMaterialId(),
                    "RELEASE", lot.remainingQty(), lot.entitlementEventId(),
                    null, null, null, null, null,
                    null, null, null, null, null, null,
                    idempotencyPrefix + ":" + sequence + ":" + lot.entitlementEventId()));
        }
    }
    @Transactional(propagation = Propagation.MANDATORY)
    public List<ReservationRelease> appendReleaseForBeneficiaryAnalysis(
            UUID analysisId,
            UUID eventGroupId,
            String idempotencyPrefix) {
        tx.bind();
        List<AvailableLot> lots =
                listRemainingLotsForBeneficiaryAnalysis(analysisId, true);
        Map<UUID, ReservationRelease> totals = new LinkedHashMap<>();
        int sequence = 0;
        for (AvailableLot lot : lots) {
            sequence++;
            insertEvent(new EventDraft(
                    eventGroupId, lot.stockReservationId(),
                    lot.beneficiaryAnalysisId(),
                    lot.beneficiaryAnalysisMaterialId(),
                    "RELEASE", lot.remainingQty(), lot.entitlementEventId(),
                    lot.reallocationId(), null, null, null, null,
                    null, null, null, null, null, null,
                    idempotencyPrefix + ":" + sequence + ":"
                            + lot.entitlementEventId()));
            totals.compute(lot.stockReservationId(), (reservationId, current) ->
                    current == null
                            ? new ReservationRelease(
                                    reservationId, lot.goodsId(), lot.colorId(),
                                    lot.remainingQty())
                            : new ReservationRelease(
                                    reservationId, current.goodsId(),
                                    current.colorId(),
                                    current.qty().add(lot.remainingQty())));
        }
        return List.copyOf(totals.values());
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendPrioritySatisfiedInPlace(
            UUID eventGroupId,
            AvailableLot sourceLot,
            UUID reallocationId,
            BigDecimal qty,
            String idempotencyKey) {
        tx.bind();
        requirePositiveWithin(qty, sourceLot.remainingQty(),
                "Priority satisfaction exceeds the source lot balance");
        return insertEvent(new EventDraft(
                eventGroupId, sourceLot.stockReservationId(),
                sourceLot.beneficiaryAnalysisId(),
                sourceLot.beneficiaryAnalysisMaterialId(),
                "PRIORITY_SATISFIED_IN_PLACE", qty,
                sourceLot.entitlementEventId(), reallocationId,
                null, null, null, null, null, null,
                null, null, null, null, idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public PairedEvents appendPairedOutIn(
            UUID eventGroupId,
            AvailableLot sourceLot,
            String outEventType,
            String inEventType,
            UUID targetAnalysisId,
            UUID targetAnalysisMaterialId,
            UUID reallocationId,
            BigDecimal qty,
            String idempotencyPrefix) {
        tx.bind();
        boolean validPair = ("REALLOCATE_OUT".equals(outEventType)
                && "REALLOCATE_IN".equals(inEventType))
                || ("PRIORITY_OUT".equals(outEventType)
                && "PRIORITY_IN".equals(inEventType));
        if (!validPair) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Unsupported entitlement event pair");
        }
        requirePositiveWithin(qty, sourceLot.remainingQty(),
                "Entitlement transfer exceeds the source lot balance");
        UUID outId = insertEvent(new EventDraft(
                eventGroupId, sourceLot.stockReservationId(),
                sourceLot.beneficiaryAnalysisId(),
                sourceLot.beneficiaryAnalysisMaterialId(),
                outEventType, qty, sourceLot.entitlementEventId(),
                reallocationId, null, null, null, null,
                null, null, null, null, null, null,
                idempotencyPrefix + ":OUT"));
        UUID inId = insertEvent(new EventDraft(
                eventGroupId, sourceLot.stockReservationId(),
                targetAnalysisId, targetAnalysisMaterialId,
                inEventType, qty, null, reallocationId,
                sourceLot.sourceExactPegId(), null, null, null,
                null, null, null, null, null, outId,
                idempotencyPrefix + ":IN"));
        return new PairedEvents(outId, inId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendReleaseLot(
            UUID eventGroupId,
            AvailableLot targetLot,
            BigDecimal qty,
            UUID reallocationId,
            String idempotencyKey) {
        tx.bind();
        requirePositiveWithin(qty, targetLot.remainingQty(),
                "Released entitlement exceeds the target lot balance");
        return insertEvent(new EventDraft(
                eventGroupId, targetLot.stockReservationId(),
                targetLot.beneficiaryAnalysisId(),
                targetLot.beneficiaryAnalysisMaterialId(),
                "RELEASE", qty, targetLot.entitlementEventId(),
                reallocationId, null, null, null, null,
                null, null, null, null, null, null,
                idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public UUID appendRestoreFromCounter(
            UUID eventGroupId,
            UUID sourceReservationId,
            UUID originalOutEventId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            BigDecimal qty,
            UUID reallocationId,
            UUID sourceExactPegId,
            String idempotencyKey) {
        tx.bind();
        return insertEvent(new EventDraft(
                eventGroupId, sourceReservationId,
                beneficiaryAnalysisId, beneficiaryAnalysisMaterialId,
                "RESTORE", qty, null, reallocationId,
                sourceExactPegId, null, null, null,
                null, null, null, null, null,
                originalOutEventId, idempotencyKey));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseUnformalizedReallocation(
            UUID reallocationId,
            UUID fromAnalysisId,
            UUID fromMaterialId,
            UUID toAnalysisId,
            UUID toMaterialId,
            UUID eventGroupId,
            String idempotencyPrefix) {
        tx.bind();
        List<Object[]> headers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT qty
                        FROM preplan_material_reallocations
                        WHERE id = :reallocationId
                          AND from_analysis_id = :fromAnalysisId
                          AND from_analysis_material_id = :fromMaterialId
                          AND to_analysis_id = :toAnalysisId
                          AND to_analysis_material_id = :toMaterialId
                          AND status = 'OPEN'
                        FOR UPDATE
                        """)
                        .setParameter("reallocationId", reallocationId)
                        .setParameter("fromAnalysisId", fromAnalysisId)
                        .setParameter("fromMaterialId", fromMaterialId)
                        .setParameter("toAnalysisId", toAnalysisId)
                        .setParameter("toMaterialId", toMaterialId));
        if (headers.size() != 1) {
            throw conflict("Only an open unfulfilled reallocation can be reversed");
        }
        BigDecimal headerQty = decimal(headers.getFirst()[0]);

        // Immutable REALLOCATE_IN rows retain the original OUT counters even
        // after formalize/restore cycles move current entitlement to RESTORE lots.
        List<Object[]> originalRoots = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT incoming.stock_reservation_id,
                               incoming.counter_event_id,
                               incoming.source_exact_peg_id, incoming.qty
                        FROM preplan_stock_entitlement_events incoming
                        WHERE incoming.reallocation_id = :reallocationId
                          AND incoming.event_type = 'REALLOCATE_IN'
                          AND incoming.beneficiary_analysis_id = :toAnalysisId
                          AND incoming.beneficiary_analysis_material_id =
                              :toMaterialId
                          AND incoming.counter_event_id IS NOT NULL
                        ORDER BY incoming.created_at, incoming.id
                        FOR UPDATE OF incoming
                        """)
                        .setParameter("reallocationId", reallocationId)
                        .setParameter("toAnalysisId", toAnalysisId)
                        .setParameter("toMaterialId", toMaterialId));
        BigDecimal originalGranted = originalRoots.stream()
                .map(row -> decimal(row[3]))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (originalRoots.isEmpty()
                || originalGranted.compareTo(headerQty) != 0) {
            throw conflict("Reallocation origin lineage is incomplete");
        }

        // Revoke the entitlement that exists now, including RESTORE descendants
        // created after a formal plan was cancelled without material issue.
        List<Object[]> currentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT positive.id, positive.event_group_id,
                               positive.stock_reservation_id,
                               positive.beneficiary_analysis_id,
                               positive.beneficiary_analysis_material_id,
                               positive.event_type, positive.reallocation_id,
                               positive.source_exact_peg_id,
                               positive.qty - COALESCE((
                                   SELECT SUM(negative.qty)
                                   FROM preplan_stock_entitlement_events negative
                                   WHERE negative.source_entitlement_event_id =
                                       positive.id
                                     AND negative.event_type IN (
                                         'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                         'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                               ), 0) AS remaining_qty,
                               reservation.goods_id, reservation.color_id,
                               reservation.warehouse_id
                        FROM preplan_stock_entitlement_events positive
                        JOIN stock_reservations reservation
                          ON reservation.id = positive.stock_reservation_id
                         AND reservation.is_deleted = FALSE
                        WHERE positive.reallocation_id = :reallocationId
                          AND positive.event_type IN ('REALLOCATE_IN', 'RESTORE')
                          AND positive.beneficiary_analysis_id = :toAnalysisId
                          AND positive.beneficiary_analysis_material_id =
                              :toMaterialId
                          AND positive.qty - COALESCE((
                              SELECT SUM(negative.qty)
                              FROM preplan_stock_entitlement_events negative
                              WHERE negative.source_entitlement_event_id =
                                  positive.id
                                AND negative.event_type IN (
                                    'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                    'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                          ), 0) > 0
                        ORDER BY reservation.created_at, reservation.id,
                                 positive.created_at, positive.id
                        FOR UPDATE OF positive, reservation
                        """)
                        .setParameter("reallocationId", reallocationId)
                        .setParameter("toAnalysisId", toAnalysisId)
                        .setParameter("toMaterialId", toMaterialId));
        List<AvailableLot> currentLots = currentRows.stream()
                .map(AvailableLot::from)
                .toList();
        BigDecimal currentTotal = currentLots.stream()
                .map(AvailableLot::remainingQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (currentLots.isEmpty() || currentTotal.compareTo(headerQty) != 0) {
            throw conflict(
                    "Reallocated stock is formalized, consumed, or otherwise incomplete");
        }

        int releaseSequence = 0;
        for (AvailableLot current : currentLots) {
            releaseSequence++;
            appendReleaseLot(
                    eventGroupId, current, current.remainingQty(),
                    reallocationId, idempotencyPrefix + ":CURRENT-RELEASE:"
                            + releaseSequence);
        }
        int restoreSequence = 0;
        for (Object[] root : originalRoots) {
            restoreSequence++;
            appendRestoreFromCounter(
                    eventGroupId, uuid(root[0]), uuid(root[1]),
                    fromAnalysisId, fromMaterialId, decimal(root[3]),
                    reallocationId, uuid(root[2]),
                    idempotencyPrefix + ":ORIGIN-RESTORE:" + restoreSequence);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<Formalization> listActiveFormalizations(
            Collection<UUID> formalReservationIds, boolean forUpdate) {
        tx.bind();
        List<UUID> ids = formalReservationIds == null
                ? List.of()
                : formalReservationIds.stream()
                        .filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) {
            return List.of();
        }
        String lock = forUpdate
                ? " FOR UPDATE OF formalize, source_lot, target_reservation"
                : "";
        Query query = em.createNativeQuery("""
                SELECT formalize.id, formalize.stock_reservation_id,
                       formalize.beneficiary_analysis_id,
                       formalize.beneficiary_analysis_material_id,
                       formalize.qty, formalize.source_entitlement_event_id,
                       source_lot.source_exact_peg_id,
                       source_lot.reallocation_id,
                       formalize.target_package_id,
                       formalize.target_demand_id,
                       formalize.target_stock_reservation_id,
                       target_reservation.consumed_qty,
                       target_reservation.released_qty,
                       target_reservation.qty
                FROM preplan_stock_entitlement_events formalize
                JOIN preplan_stock_entitlement_events source_lot
                  ON source_lot.id = formalize.source_entitlement_event_id
                JOIN stock_reservations target_reservation
                  ON target_reservation.id = formalize.target_stock_reservation_id
                WHERE formalize.event_type = 'FORMALIZE'
                  AND formalize.target_stock_reservation_id IN (:ids)
                  AND NOT EXISTS (
                      SELECT 1
                      FROM preplan_stock_entitlement_events restored
                      WHERE restored.event_type = 'RESTORE'
                        AND restored.counter_event_id = formalize.id)
                ORDER BY formalize.stock_reservation_id,
                         formalize.created_at, formalize.id
                """ + lock).setParameter("ids", ids);
        List<Formalization> result = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            BigDecimal consumed = decimal(row[11]);
            BigDecimal released = decimal(row[12]);
            BigDecimal targetQty = decimal(row[13]);
            if (consumed.signum() > 0) {
                throw conflict("Formalized analysis stock has already been issued");
            }
            if (released.compareTo(targetQty) < 0) {
                throw conflict("Formal demand reservation must be released before restore");
            }
            result.add(new Formalization(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                    decimal(row[4]), uuid(row[5]), uuid(row[7]), uuid(row[6]),
                    uuid(row[8]), uuid(row[9]), uuid(row[10])));
        }
        return List.copyOf(result);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void requireNoActiveFormalizationForBeneficiary(
            UUID analysisId, boolean forUpdate) {
        tx.bind();
        String lock = forUpdate
                ? " FOR UPDATE OF formalize, source_lot, target_reservation"
                : "";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT formalize.id,
                               target_reservation.consumed_qty,
                               target_reservation.released_qty,
                               target_reservation.qty
                        FROM preplan_stock_entitlement_events formalize
                        JOIN preplan_stock_entitlement_events source_lot
                          ON source_lot.id =
                             formalize.source_entitlement_event_id
                        JOIN stock_reservations target_reservation
                          ON target_reservation.id =
                             formalize.target_stock_reservation_id
                        WHERE formalize.event_type = 'FORMALIZE'
                          AND formalize.beneficiary_analysis_id = :analysisId
                          AND NOT EXISTS (
                              SELECT 1
                              FROM preplan_stock_entitlement_events restored
                              WHERE restored.event_type = 'RESTORE'
                                AND restored.counter_event_id = formalize.id)
                        ORDER BY formalize.created_at, formalize.id
                        """ + lock).setParameter("analysisId", analysisId));
        if (rows.isEmpty()) {
            return;
        }
        boolean issued = rows.stream()
                .anyMatch(row -> decimal(row[1]).signum() > 0);
        if (issued) {
            throw conflict(
                    "该分析的正式需求库存已经领料，禁止取消物料分析");
        }
        boolean notFullyReleased = rows.stream()
                .anyMatch(row -> decimal(row[2]).compareTo(decimal(row[3])) < 0);
        if (notFullyReleased) {
            throw conflict(
                    "该分析仍有未释放的正式需求库存；请先取消未领料计划并完成RESTORE");
        }
        throw conflict(
                "该分析的正式需求库存虽已完整释放，但尚未完成RESTORE；请先恢复权益");
    }

    private List<AvailableLot> listRemainingLotsForBeneficiaryAnalysis(
            UUID analysisId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE OF positive, reservation" : "";
        Query query = em.createNativeQuery("""
                SELECT positive.id, positive.event_group_id,
                       positive.stock_reservation_id,
                       positive.beneficiary_analysis_id,
                       positive.beneficiary_analysis_material_id,
                       positive.event_type, positive.reallocation_id,
                       positive.source_exact_peg_id,
                       positive.qty - COALESCE((
                           SELECT SUM(negative.qty)
                           FROM preplan_stock_entitlement_events negative
                           WHERE negative.source_entitlement_event_id = positive.id
                             AND negative.event_type IN (
                                 'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                       ), 0) AS remaining_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id
                FROM preplan_stock_entitlement_events positive
                JOIN stock_reservations reservation
                  ON reservation.id = positive.stock_reservation_id
                 AND reservation.is_deleted = FALSE
                 AND reservation.owner_type = 'PREPLAN_ANALYSIS'
                WHERE positive.beneficiary_analysis_id = :analysisId
                  AND positive.event_type IN (
                      'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                      'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
                  AND positive.qty - COALESCE((
                      SELECT SUM(negative.qty)
                      FROM preplan_stock_entitlement_events negative
                      WHERE negative.source_entitlement_event_id = positive.id
                        AND negative.event_type IN (
                            'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                            'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                  ), 0) > 0
                  AND reservation.qty - reservation.consumed_qty
                      - reservation.released_qty > 0
                ORDER BY reservation.created_at, reservation.id,
                         positive.created_at, positive.id
                """ + lock).setParameter("analysisId", analysisId);
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(AvailableLot::from)
                .toList();
    }
    private List<AvailableLot> listRemainingLotsForReservation(
            UUID reservationId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE OF positive, reservation" : "";
        Query query = em.createNativeQuery("""
                SELECT positive.id, positive.event_group_id,
                       positive.stock_reservation_id,
                       positive.beneficiary_analysis_id,
                       positive.beneficiary_analysis_material_id,
                       positive.event_type, positive.reallocation_id,
                       positive.source_exact_peg_id,
                       positive.qty - COALESCE((
                           SELECT SUM(negative.qty)
                           FROM preplan_stock_entitlement_events negative
                           WHERE negative.source_entitlement_event_id = positive.id
                             AND negative.event_type IN (
                                 'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                                 'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                       ), 0) AS remaining_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id
                FROM preplan_stock_entitlement_events positive
                JOIN stock_reservations reservation
                  ON reservation.id = positive.stock_reservation_id
                WHERE positive.stock_reservation_id = :reservationId
                  AND positive.event_type IN (
                      'ORIGIN_IQC', 'ORIGIN_MAKE', 'MAKE_DELEGATE_IN',
                      'REALLOCATE_IN', 'PRIORITY_IN', 'RESTORE')
                  AND positive.qty - COALESCE((
                      SELECT SUM(negative.qty)
                      FROM preplan_stock_entitlement_events negative
                      WHERE negative.source_entitlement_event_id = positive.id
                        AND negative.event_type IN (
                            'MAKE_DELEGATE_OUT', 'REALLOCATE_OUT',
                            'PRIORITY_OUT', 'FORMALIZE', 'RELEASE')
                  ), 0) > 0
                ORDER BY positive.created_at, positive.id
                """ + lock).setParameter("reservationId", reservationId);
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(AvailableLot::from)
                .toList();
    }

    private UUID insertEvent(EventDraft draft) {
        return insertEventWithResult(draft).eventId();
    }

    private OriginAppendResult insertEventWithResult(EventDraft draft) {
        requirePositiveWithin(draft.qty(), draft.qty(),
                "Entitlement event quantity must be positive");
        UUID proposedId = UUID.randomUUID();
        int inserted = em.createNativeQuery("""
                INSERT INTO preplan_stock_entitlement_events (
                    id, event_group_id, stock_reservation_id,
                    beneficiary_analysis_id, beneficiary_analysis_material_id,
                    event_type, qty, source_entitlement_event_id,
                    reallocation_id, source_exact_peg_id,
                    source_receipt_type, source_receipt_id,
                    source_disposition_event_id,
                    source_stock_document_id, source_stock_document_item_id,
                    target_package_id, target_demand_id,
                    target_stock_reservation_id, counter_event_id,
                    idempotency_key, created_by
                ) VALUES (
                    :id, :eventGroupId, :reservationId,
                    :analysisId, :materialId,
                    :eventType, :qty, :sourceEventId,
                    :reallocationId, :exactPegId,
                    :receiptType, :receiptId, :dispositionEventId,
                    :stockDocumentId, :stockDocumentItemId,
                    :packageId, :demandId, :targetReservationId,
                    :counterEventId, :key, :actorId
                )
                ON CONFLICT (idempotency_key) DO NOTHING
                """)
                .setParameter("id", proposedId)
                .setParameter("eventGroupId", draft.eventGroupId())
                .setParameter("reservationId", draft.stockReservationId())
                .setParameter("analysisId", draft.beneficiaryAnalysisId())
                .setParameter("materialId", draft.beneficiaryAnalysisMaterialId())
                .setParameter("eventType", draft.eventType())
                .setParameter("qty", draft.qty())
                .setParameter("sourceEventId", draft.sourceEntitlementEventId())
                .setParameter("reallocationId", draft.reallocationId())
                .setParameter("exactPegId", draft.sourceExactPegId())
                .setParameter("receiptType", draft.sourceReceiptType())
                .setParameter("receiptId", draft.sourceReceiptId())
                .setParameter("dispositionEventId", draft.sourceDispositionEventId())
                .setParameter("stockDocumentId", draft.sourceStockDocumentId())
                .setParameter("stockDocumentItemId", draft.sourceStockDocumentItemId())
                .setParameter("packageId", draft.targetPackageId())
                .setParameter("demandId", draft.targetDemandId())
                .setParameter("targetReservationId", draft.targetStockReservationId())
                .setParameter("counterEventId", draft.counterEventId())
                .setParameter("key", draft.idempotencyKey())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT id, event_group_id, stock_reservation_id,
                               beneficiary_analysis_id,
                               beneficiary_analysis_material_id,
                               event_type, qty, source_entitlement_event_id,
                               reallocation_id, source_exact_peg_id,
                               source_receipt_type, source_receipt_id,
                               source_disposition_event_id,
                               source_stock_document_id,
                               source_stock_document_item_id,
                               target_package_id, target_demand_id,
                               target_stock_reservation_id, counter_event_id
                        FROM preplan_stock_entitlement_events
                        WHERE idempotency_key = :key
                        FOR UPDATE
                        """).setParameter("key", draft.idempotencyKey()));
        if (replay.size() != 1) {
            throw new IllegalStateException("Entitlement event was not persisted");
        }
        Object[] row = replay.getFirst();
        if (!eventPayloadMatches(row, draft)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Entitlement idempotency key was reused with a different payload");
        }
        if (inserted != 0 && inserted != 1) {
            throw new IllegalStateException(
                    "Unexpected entitlement insert row count: " + inserted);
        }
        return new OriginAppendResult(uuid(row[0]), inserted == 1);
    }

    private static boolean eventPayloadMatches(
            Object[] row, EventDraft draft) {
        return Objects.equals(uuid(row[1]), draft.eventGroupId())
                && Objects.equals(uuid(row[2]), draft.stockReservationId())
                && Objects.equals(uuid(row[3]), draft.beneficiaryAnalysisId())
                && Objects.equals(
                        uuid(row[4]), draft.beneficiaryAnalysisMaterialId())
                && Objects.equals(
                        Objects.toString(row[5], null), draft.eventType())
                && decimal(row[6]).compareTo(draft.qty()) == 0
                && Objects.equals(
                        uuid(row[7]), draft.sourceEntitlementEventId())
                && Objects.equals(uuid(row[8]), draft.reallocationId())
                && Objects.equals(uuid(row[9]), draft.sourceExactPegId())
                && Objects.equals(
                        Objects.toString(row[10], null), draft.sourceReceiptType())
                && Objects.equals(uuid(row[11]), draft.sourceReceiptId())
                && Objects.equals(
                        uuid(row[12]), draft.sourceDispositionEventId())
                && Objects.equals(uuid(row[13]), draft.sourceStockDocumentId())
                && Objects.equals(
                        uuid(row[14]), draft.sourceStockDocumentItemId())
                && Objects.equals(uuid(row[15]), draft.targetPackageId())
                && Objects.equals(uuid(row[16]), draft.targetDemandId())
                && Objects.equals(
                        uuid(row[17]), draft.targetStockReservationId())
                && Objects.equals(uuid(row[18]), draft.counterEventId());
    }

    private static void requirePositiveWithin(
            BigDecimal qty, BigDecimal capacity, String message) {
        if (qty == null || qty.signum() <= 0 || capacity == null
                || qty.compareTo(capacity) > 0) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    public record AvailableLot(
            UUID entitlementEventId,
            UUID eventGroupId,
            UUID stockReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            String originEventType,
            UUID reallocationId,
            UUID sourceExactPegId,
            BigDecimal remainingQty,
            UUID goodsId,
            UUID colorId,
            UUID warehouseId) {
        static AvailableLot from(Object[] row) {
            return new AvailableLot(
                    uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                    uuid(row[4]), Objects.toString(row[5], null), uuid(row[6]),
                    uuid(row[7]), decimal(row[8]), uuid(row[9]), uuid(row[10]),
                    uuid(row[11]));
        }
    }

    public record OriginAppendResult(UUID eventId, boolean inserted) {
    }

    public record ReservationRelease(
            UUID stockReservationId,
            UUID goodsId,
            UUID colorId,
            BigDecimal qty) {
    }

    public record BeneficiaryBalance(
            UUID stockReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            BigDecimal effectiveQty) {
    }

    public record PairedEvents(UUID outEventId, UUID inEventId) {
    }

    public record Formalization(
            UUID formalizeEventId,
            UUID sourceStockReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            BigDecimal qty,
            UUID sourceEntitlementEventId,
            UUID reallocationId,
            UUID sourceExactPegId,
            UUID targetPackageId,
            UUID targetDemandId,
            UUID targetStockReservationId) {
    }

    private record MakeDelegationTarget(
            UUID parentMaterialId,
            UUID childItemId,
            UUID sourceMaterialId,
            UUID targetMaterialId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requiredQty) {
    }

    private record MakeDelegationRestore(
            UUID delegationId,
            UUID sourceMaterialId,
            UUID stockReservationId,
            BigDecimal qty,
            UUID outEventId,
            AvailableLot currentLot) {
    }

    private record EventDraft(
            UUID eventGroupId,
            UUID stockReservationId,
            UUID beneficiaryAnalysisId,
            UUID beneficiaryAnalysisMaterialId,
            String eventType,
            BigDecimal qty,
            UUID sourceEntitlementEventId,
            UUID reallocationId,
            UUID sourceExactPegId,
            String sourceReceiptType,
            UUID sourceReceiptId,
            UUID sourceDispositionEventId,
            UUID sourceStockDocumentId,
            UUID sourceStockDocumentItemId,
            UUID targetPackageId,
            UUID targetDemandId,
            UUID targetStockReservationId,
            UUID counterEventId,
            String idempotencyKey) {
    }
}
