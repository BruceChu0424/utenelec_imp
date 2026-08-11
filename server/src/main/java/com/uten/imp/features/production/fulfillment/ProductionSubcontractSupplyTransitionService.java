package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Exact, reversible subcontract supply transitions:
 *
 * <pre>
 * application item peg -> approved order item peg
 * approved receipt -> complete-kit readiness conversion
 * </pre>
 */
@Service
@RequiredArgsConstructor
public class ProductionSubcontractSupplyTransitionService
        implements ProductionSubcontractSupplyTransitionPort {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionFulfillmentLedgerService ledger;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionExecutionReadinessService readiness;
    private final MaterialAnalysisSupplyWakeupService materialAnalysisWakeup;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void onSubcontractApplicationRemoved(UUID applicationId) {
        UUID actorId = currentUser.requireId();
        List<Object[]> pegs = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT peg.id, peg.demand_id,
                                       peg.allocated_qty,
                                       peg.consumed_qty,
                                       peg.released_qty
                                FROM subcontract_application_items item
                                JOIN production_material_supply_pegs peg
                                  ON peg.supply_type =
                                    'SUBCONTRACT_APPLICATION_ITEM'
                                 AND peg.supply_item_id = item.id
                                 AND peg.status <> 'REVERSED'
                                JOIN production_material_demands demand
                                  ON demand.id = peg.demand_id
                                WHERE item.application_id = :applicationId
                                  AND item.is_deleted = FALSE
                                ORDER BY peg.demand_id, peg.id
                                FOR UPDATE OF peg, demand
                                """)
                        .setParameter(
                                "applicationId", applicationId));
        Set<UUID> touched = new LinkedHashSet<>();
        for (Object[] row : pegs) {
            if (decimal(row[3]).signum() > 0) {
                throw conflict(
                        "委外申请供给已经回厂并被生产需求消费，不能直接删除或红冲");
            }
            UUID pegId = uuid(row[0]);
            int updated = em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET released_qty = allocated_qty,
                                status = 'REVERSED',
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                              AND consumed_qty = 0
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", pegId)
                    .executeUpdate();
            if (updated != 1) {
                throw conflict("委外申请供给并发变化，请刷新后重试");
            }
            touched.add(uuid(row[1]));
        }
        ledger.refreshDemandStatuses(touched);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void onSubcontractOrderApproved(UUID orderId) {
        UUID actorId = currentUser.requireId();
        Set<UUID> touched = new LinkedHashSet<>();
        List<Object[]> items = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT item.id,
                                       item.application_item_id,
                                       item.qty *
                                           COALESCE(item.unit_rate, 1),
                                       item.deliver_date
                                FROM subcontract_order_items item
                                WHERE item.order_id = :orderId
                                  AND item.is_deleted = FALSE
                                  AND item.application_item_id IS NOT NULL
                                ORDER BY item.application_item_id, item.id
                                FOR UPDATE
                                """)
                        .setParameter("orderId", orderId));
        for (Object[] item : items) {
            UUID orderItemId = uuid(item[0]);
            UUID applicationItemId = uuid(item[1]);
            BigDecimal remaining = decimal(item[2]).subtract(
                    decimal(em.createNativeQuery("""
                                    SELECT COALESCE(
                                        SUM(transferred_qty), 0)
                                    FROM
                                      production_material_subcontract_peg_transfers
                                    WHERE order_item_id = :orderItemId
                                      AND status = 'EFFECTIVE'
                                    """)
                            .setParameter(
                                    "orderItemId", orderItemId)
                            .getSingleResult()));
            if (remaining.signum() <= 0) {
                continue;
            }
            LocalDate expectedDate = localDate(item[3]);
            List<Object[]> sources = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT peg.id, peg.demand_id,
                                           peg.allocated_qty,
                                           peg.consumed_qty,
                                           peg.released_qty
                                    FROM production_material_supply_pegs peg
                                    JOIN production_material_demands demand
                                      ON demand.id = peg.demand_id
                                     AND demand.is_deleted = FALSE
                                    JOIN production_planning_packages package
                                      ON package.id = demand.package_id
                                     AND package.is_deleted = FALSE
                                     AND package.status = 'CONFIRMED'
                                    WHERE peg.supply_type =
                                        'SUBCONTRACT_APPLICATION_ITEM'
                                      AND peg.supply_item_id =
                                        :applicationItemId
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                    ORDER BY demand.need_date NULLS LAST,
                                             demand.id, peg.id
                                    FOR UPDATE OF peg, demand, package
                                    """)
                            .setParameter(
                                    "applicationItemId",
                                    applicationItemId));
            for (Object[] source : sources) {
                if (remaining.signum() <= 0) {
                    break;
                }
                UUID sourcePegId = uuid(source[0]);
                UUID demandId = uuid(source[1]);
                BigDecimal available = decimal(source[2])
                        .subtract(decimal(source[3]))
                        .subtract(decimal(source[4]));
                BigDecimal qty = remaining.min(available);
                if (qty.signum() <= 0) {
                    continue;
                }
                int released = em.createNativeQuery("""
                                UPDATE production_material_supply_pegs
                                SET released_qty = released_qty + :qty,
                                    status = CASE
                                        WHEN consumed_qty + released_qty
                                             + :qty = allocated_qty
                                        THEN 'RELEASED'
                                        ELSE 'EFFECTIVE'
                                    END,
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :pegId
                                  AND allocated_qty - consumed_qty
                                      - released_qty >= :qty
                                """)
                        .setParameter("qty", qty)
                        .setParameter("actorId", actorId)
                        .setParameter("pegId", sourcePegId)
                        .executeUpdate();
                if (released != 1) {
                    throw conflict(
                            "委外申请供给并发变化，请刷新后重试");
                }

                UUID targetPegId = UUID.randomUUID();
                em.createNativeQuery("""
                                INSERT INTO
                                  production_material_supply_pegs (
                                    id, demand_id, supply_type,
                                    supply_item_id, allocated_qty,
                                    consumed_qty, released_qty,
                                    expected_date, status,
                                    idempotency_key, lock_version,
                                    created_at, updated_at,
                                    created_by, updated_by)
                                VALUES (
                                    :id, :demandId,
                                    'SUBCONTRACT_ORDER_ITEM',
                                    :orderItemId, :qty, 0, 0,
                                    :expectedDate, 'EFFECTIVE', :key, 0,
                                    now(), now(), :actorId, :actorId)
                                """)
                        .setParameter("id", targetPegId)
                        .setParameter("demandId", demandId)
                        .setParameter("orderItemId", orderItemId)
                        .setParameter("qty", qty)
                        .setParameter("expectedDate", expectedDate)
                        .setParameter(
                                "key",
                                demandId
                                        + ":SUBCONTRACT_ORDER_ITEM:"
                                        + orderItemId)
                        .setParameter("actorId", actorId)
                        .executeUpdate();
                em.createNativeQuery("""
                                INSERT INTO
                                  production_material_subcontract_peg_transfers (
                                    demand_id, from_peg_id, to_peg_id,
                                    application_item_id, order_item_id,
                                    transferred_qty, status,
                                    idempotency_key, created_at, updated_at,
                                    created_by, updated_by)
                                VALUES (
                                    :demandId, :fromPegId, :toPegId,
                                    :applicationItemId, :orderItemId,
                                    :qty, 'EFFECTIVE', :key,
                                    now(), now(), :actorId, :actorId)
                                """)
                        .setParameter("demandId", demandId)
                        .setParameter("fromPegId", sourcePegId)
                        .setParameter("toPegId", targetPegId)
                        .setParameter(
                                "applicationItemId",
                                applicationItemId)
                        .setParameter("orderItemId", orderItemId)
                        .setParameter("qty", qty)
                        .setParameter(
                                "key",
                                "SUB-ORDER-PEG:"
                                        + sourcePegId + ":" + orderItemId)
                        .setParameter("actorId", actorId)
                        .executeUpdate();
                touched.add(demandId);
                remaining = remaining.subtract(qty);
            }
        }
        ledger.refreshDemandStatuses(touched);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void onSubcontractOrderReversed(UUID orderId) {
        UUID actorId = currentUser.requireId();
        Set<UUID> touched = new LinkedHashSet<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT transfer.id, transfer.demand_id,
                                       transfer.from_peg_id,
                                       transfer.to_peg_id,
                                       transfer.transferred_qty,
                                       target.consumed_qty,
                                       source.released_qty
                                FROM
                                  production_material_subcontract_peg_transfers
                                    transfer
                                JOIN subcontract_order_items item
                                  ON item.id = transfer.order_item_id
                                JOIN production_material_supply_pegs source
                                  ON source.id = transfer.from_peg_id
                                JOIN production_material_supply_pegs target
                                  ON target.id = transfer.to_peg_id
                                JOIN production_material_demands demand
                                  ON demand.id = transfer.demand_id
                                WHERE item.order_id = :orderId
                                  AND transfer.status = 'EFFECTIVE'
                                ORDER BY transfer.demand_id, transfer.id
                                FOR UPDATE OF transfer, source,
                                                   target, demand
                                """)
                        .setParameter("orderId", orderId));
        for (Object[] row : rows) {
            BigDecimal qty = decimal(row[4]);
            if (decimal(row[5]).signum() > 0) {
                throw conflict(
                        "委外订单供给已回厂并转为生产备料，必须先红冲下游回厂单");
            }
            if (decimal(row[6]).compareTo(qty) < 0) {
                throw conflict(
                        "委外申请供给迁移数量异常，禁止红冲");
            }
            int target = em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET released_qty = allocated_qty,
                                status = 'REVERSED',
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                              AND consumed_qty = 0
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", uuid(row[3]))
                    .executeUpdate();
            int source = em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET released_qty = released_qty - :qty,
                                status = 'EFFECTIVE',
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                              AND released_qty >= :qty
                            """)
                    .setParameter("qty", qty)
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", uuid(row[2]))
                    .executeUpdate();
            int transfer = em.createNativeQuery("""
                            UPDATE
                              production_material_subcontract_peg_transfers
                            SET status = 'REVERSED',
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                              AND status = 'EFFECTIVE'
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("id", uuid(row[0]))
                    .executeUpdate();
            if (target != 1 || source != 1 || transfer != 1) {
                throw conflict(
                        "委外订单供给并发变化，请刷新后重试");
            }
            touched.add(uuid(row[1]));
        }
        ledger.refreshDemandStatuses(touched);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockSubcontractReceiptMutationDimensions(
            UUID receiptId) {
        List<UUID> warehouses = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT warehouse_id
                                FROM subcontract_receipts
                                WHERE id = :receiptId
                                  AND is_deleted = FALSE
                                """)
                        .setParameter("receiptId", receiptId),
                UUID.class);
        if (!warehouses.isEmpty()
                && warehouses.getFirst() != null) {
            lockReceiptDimensions(
                    receiptId, warehouses.getFirst());
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockSubcontractReceiptProductionDemands(
            UUID receiptId, UUID warehouseId) {
        if (receiptId == null || warehouseId == null) {
            return;
        }
        lockReceiptDimensions(receiptId, warehouseId);
        em.createNativeQuery("""
                        SELECT demand.id
                        FROM subcontract_receipt_items receipt_item
                        JOIN production_material_supply_pegs peg
                          ON peg.supply_type =
                                'SUBCONTRACT_ORDER_ITEM'
                         AND peg.supply_item_id =
                                receipt_item.order_item_id
                         AND peg.status <> 'REVERSED'
                         AND peg.allocated_qty - peg.consumed_qty
                               - peg.released_qty > 0
                        JOIN production_material_demands demand
                          ON demand.id = peg.demand_id
                         AND demand.is_deleted = FALSE
                         AND demand.warehouse_id = :warehouseId
                        JOIN production_planning_packages package
                          ON package.id = demand.package_id
                         AND package.is_deleted = FALSE
                         AND package.status = 'CONFIRMED'
                        WHERE receipt_item.receipt_id = :receiptId
                          AND receipt_item.is_deleted = FALSE
                        ORDER BY demand.id, peg.id
                        FOR UPDATE OF demand, peg, package
                        """)
                .setParameter("receiptId", receiptId)
                .setParameter("warehouseId", warehouseId)
                .getResultList();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void onSubcontractReceiptApproved(UUID receiptId) {
        UUID warehouseId = receiptWarehouse(receiptId);
        readiness.onSubcontractReceiptApproved(
                receiptId, warehouseId);
        materialAnalysisWakeup.afterSubcontractReceiptApproved(receiptId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeSubcontractReceiptReversed(UUID receiptId) {
        readiness.beforeSubcontractReceiptReversed(receiptId);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterSubcontractReceiptReversed(UUID receiptId) {
        materialAnalysisWakeup.afterSubcontractReceiptReversed(receiptId);
    }

    private void lockReceiptDimensions(
            UUID receiptId, UUID warehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                WITH receipt_segments AS (
                                    SELECT DISTINCT
                                        demand.execution_segment_id
                                    FROM subcontract_receipt_items receipt_item
                                    JOIN production_material_supply_pegs peg
                                      ON peg.supply_type =
                                            'SUBCONTRACT_ORDER_ITEM'
                                     AND peg.supply_item_id =
                                            receipt_item.order_item_id
                                     AND peg.status <> 'REVERSED'
                                    JOIN production_material_demands demand
                                      ON demand.id = peg.demand_id
                                     AND demand.is_deleted = FALSE
                                     AND demand.warehouse_id = :warehouseId
                                    WHERE receipt_item.receipt_id = :receiptId
                                      AND receipt_item.is_deleted = FALSE
                                      AND demand.execution_segment_id
                                            IS NOT NULL
                                ),
                                dimensions AS (
                                    SELECT receipt_item.goods_id,
                                           receipt_item.color_id
                                    FROM subcontract_receipt_items receipt_item
                                    WHERE receipt_item.receipt_id = :receiptId
                                      AND receipt_item.is_deleted = FALSE
                                    UNION ALL
                                    SELECT candidate.goods_id,
                                           candidate.color_id
                                    FROM receipt_segments source
                                    JOIN production_material_demands candidate
                                      ON candidate.execution_segment_id =
                                            source.execution_segment_id
                                    WHERE candidate.is_deleted = FALSE
                                      AND candidate.warehouse_id =
                                            :warehouseId
                                )
                                SELECT DISTINCT goods_id, color_id
                                FROM dimensions
                                ORDER BY goods_id, color_id NULLS FIRST
                                """)
                        .setParameter("receiptId", receiptId)
                        .setParameter("warehouseId", warehouseId));
        stockAllocation.lockMaterialDimensions(rows.stream()
                .map(row -> new ProductionMaterialAllocationFacade
                        .MaterialDimension(
                        uuid(row[0]), uuid(row[1])))
                .toList());
    }

    private UUID receiptWarehouse(UUID receiptId) {
        List<UUID> warehouses = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT warehouse_id
                                FROM subcontract_receipts
                                WHERE id = :receiptId
                                  AND is_deleted = FALSE
                                  AND status = 1
                                FOR UPDATE
                                """)
                        .setParameter("receiptId", receiptId),
                UUID.class);
        if (warehouses.isEmpty()
                || warehouses.getFirst() == null) {
            throw conflict(
                    "委外回厂单缺少目标仓库，不能转为生产备料");
        }
        return warehouses.getFirst();
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static UUID uuid(Object value) {
        if (value == null) {
            return null;
        }
        return value instanceof UUID uuid
                ? uuid : UUID.fromString(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof LocalDate date) {
            return date;
        }
        return ((java.sql.Date) value).toLocalDate();
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
