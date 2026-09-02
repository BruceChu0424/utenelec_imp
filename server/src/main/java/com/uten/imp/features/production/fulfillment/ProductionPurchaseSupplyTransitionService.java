package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Converts explicitly pegged purchase supply through the production material
 * chain. Every conversion is quantity-based, idempotent and reversible:
 *
 * <pre>
 * request peg -> order peg -> target-warehouse reservation -> draft DRAW
 * </pre>
 *
 * Matching goods alone is never treated as provenance. Only the real linked
 * request/order/receipt item identifiers participate.
 */
@Service
@RequiredArgsConstructor
public class ProductionPurchaseSupplyTransitionService implements ProductionSupplyTransitionPort {

    private static final short RESERVATION_EFFECTIVE = 0;
    private static final short RESERVATION_DONE = 1;
    private static final short RESERVATION_RELEASED = -1;
    private static final short PRODUCTION_MATERIAL_SOURCE = 2;

    private final EntityManager em;
    private final StockDocumentRepository stockDocumentRepo;
    private final StockDocumentItemRepository stockDocumentItemRepo;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionFulfillmentLedgerService ledger;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionExecutionReadinessService executionReadiness;
    private final MaterialAnalysisSupplyWakeupService materialAnalysisWakeup;
    private final ChainNoticeService chainNotice;

    /**
     * Moves the production-covered part of each real request item to its
     * approved order item. General purchase quantity with no production peg is
     * intentionally left outside the production ledger.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void onPurchaseOrderApproved(UUID orderId) {
        UUID actorId = currentUser.requireId();
        Set<UUID> touched = new LinkedHashSet<>();
        List<Object[]> orderItems = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT i.id, i.request_item_id,
                                       i.qty * COALESCE(i.unit_rate, 1),
                                       i.deliver_date
                                FROM purchase_order_items i
                                WHERE i.order_id = :orderId
                                  AND i.is_deleted = FALSE
                                  AND i.request_item_id IS NOT NULL
                                ORDER BY i.request_item_id, i.id
                                FOR UPDATE
                                """)
                        .setParameter("orderId", orderId));

        for (Object[] orderItem : orderItems) {
            UUID orderItemId = uuid(orderItem[0]);
            UUID requestItemId = uuid(orderItem[1]);
            BigDecimal orderedBase = decimal(orderItem[2]);
            LocalDate expectedDate = localDate(orderItem[3]);
            BigDecimal replayed = decimal(em.createNativeQuery("""
                            SELECT COALESCE(SUM(transferred_qty), 0)
                            FROM production_material_peg_transfers
                            WHERE order_item_id = :orderItemId
                              AND status = 'EFFECTIVE'
                            """)
                    .setParameter("orderItemId", orderItemId)
                    .getSingleResult());
            BigDecimal remaining = orderedBase.subtract(replayed);
            if (remaining.signum() <= 0) {
                continue;
            }

            List<Object[]> requestPegs = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT p.id, p.demand_id, p.allocated_qty,
                                           p.consumed_qty, p.released_qty
                                    FROM production_material_supply_pegs p
                                    JOIN production_material_demands d
                                      ON d.id = p.demand_id
                                     AND d.is_deleted = FALSE
                                    JOIN production_planning_packages package
                                      ON package.id = d.package_id
                                     AND package.is_deleted = FALSE
                                     AND package.status = 'CONFIRMED'
                                    WHERE p.supply_type = 'PURCHASE_REQUEST_ITEM'
                                      AND p.supply_item_id = :requestItemId
                                      AND p.status <> 'REVERSED'
                                      AND p.allocated_qty
                                            - p.consumed_qty
                                            - p.released_qty > 0
                                    ORDER BY d.need_date NULLS LAST, d.id, p.id
                                    FOR UPDATE OF p, d, package
                                    """)
                            .setParameter("requestItemId", requestItemId));

            for (Object[] requestPeg : requestPegs) {
                if (remaining.signum() <= 0) {
                    break;
                }
                UUID fromPegId = uuid(requestPeg[0]);
                UUID demandId = uuid(requestPeg[1]);
                BigDecimal available = decimal(requestPeg[2])
                        .subtract(decimal(requestPeg[3]))
                        .subtract(decimal(requestPeg[4]));
                BigDecimal quantity = remaining.min(available);
                if (quantity.signum() <= 0) {
                    continue;
                }

                em.createNativeQuery("""
                                UPDATE production_material_supply_pegs
                                SET released_qty = released_qty + :qty,
                                    status = CASE
                                        WHEN consumed_qty + released_qty + :qty
                                             = allocated_qty
                                        THEN 'RELEASED'
                                        ELSE 'EFFECTIVE'
                                    END,
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :pegId
                                """)
                        .setParameter("qty", quantity)
                        .setParameter("actorId", actorId)
                        .setParameter("pegId", fromPegId)
                        .executeUpdate();

                UUID toPegId = UUID.randomUUID();
                em.createNativeQuery("""
                                INSERT INTO production_material_supply_pegs (
                                    id, demand_id, supply_type, supply_item_id,
                                    allocated_qty, consumed_qty, released_qty,
                                    expected_date, status, idempotency_key,
                                    lock_version, created_at, updated_at,
                                    created_by, updated_by
                                ) VALUES (
                                    :id, :demandId, 'PURCHASE_ORDER_ITEM',
                                    :orderItemId, :qty, 0, 0, :expectedDate,
                                    'EFFECTIVE', :key, 0, now(), now(),
                                    :actorId, :actorId
                                )
                                """)
                        .setParameter("id", toPegId)
                        .setParameter("demandId", demandId)
                        .setParameter("orderItemId", orderItemId)
                        .setParameter("qty", quantity)
                        .setParameter("expectedDate", expectedDate)
                        .setParameter(
                                "key",
                                demandId + ":PURCHASE_ORDER_ITEM:" + orderItemId)
                        .setParameter("actorId", actorId)
                        .executeUpdate();

                em.createNativeQuery("""
                                INSERT INTO production_material_peg_transfers (
                                    demand_id, from_peg_id, to_peg_id,
                                    request_item_id, order_item_id,
                                    transferred_qty, status, idempotency_key,
                                    created_at, updated_at, created_by, updated_by
                                ) VALUES (
                                    :demandId, :fromPegId, :toPegId,
                                    :requestItemId, :orderItemId, :qty,
                                    'EFFECTIVE', :key, now(), now(),
                                    :actorId, :actorId
                                )
                                """)
                        .setParameter("demandId", demandId)
                        .setParameter("fromPegId", fromPegId)
                        .setParameter("toPegId", toPegId)
                        .setParameter("requestItemId", requestItemId)
                        .setParameter("orderItemId", orderItemId)
                        .setParameter("qty", quantity)
                        .setParameter(
                                "key",
                                "ORDER-PEG:" + fromPegId + ":" + orderItemId)
                        .setParameter("actorId", actorId)
                        .executeUpdate();
                touched.add(demandId);
                remaining = remaining.subtract(quantity);
            }
        }
        ledger.refreshDemandStatuses(touched);
    }

    /**
     * Restores the request pegs exactly when an order is reversed. The caller
     * already rejects an order with receipts; this method independently
     * verifies that no target peg has been received.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void onPurchaseOrderReversed(UUID orderId) {
        UUID actorId = currentUser.requireId();
        Set<UUID> touched = new LinkedHashSet<>();
        List<Object[]> transfers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT t.id, t.demand_id, t.from_peg_id,
                                       t.to_peg_id, t.transferred_qty,
                                       target.consumed_qty,
                                       source.released_qty
                                FROM production_material_peg_transfers t
                                JOIN purchase_order_items oi
                                  ON oi.id = t.order_item_id
                                JOIN production_material_supply_pegs source
                                  ON source.id = t.from_peg_id
                                JOIN production_material_supply_pegs target
                                  ON target.id = t.to_peg_id
                                JOIN production_material_demands d
                                  ON d.id = t.demand_id
                                WHERE oi.order_id = :orderId
                                  AND t.status = 'EFFECTIVE'
                                ORDER BY t.demand_id, t.id
                                FOR UPDATE OF t, source, target, d
                                """)
                        .setParameter("orderId", orderId));

        for (Object[] transfer : transfers) {
            UUID transferId = uuid(transfer[0]);
            UUID demandId = uuid(transfer[1]);
            UUID fromPegId = uuid(transfer[2]);
            UUID toPegId = uuid(transfer[3]);
            BigDecimal quantity = decimal(transfer[4]);
            if (decimal(transfer[5]).signum() > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购订单供给已收货并转为生产备料，必须先红冲下游收货单");
            }
            if (decimal(transfer[6]).compareTo(quantity) < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购申请供给迁移数量异常，禁止红冲以免破坏需求守恒");
            }

            em.createNativeQuery("""
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
                    .setParameter("pegId", toPegId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET released_qty = released_qty - :qty,
                                status = 'EFFECTIVE',
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                            """)
                    .setParameter("qty", quantity)
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", fromPegId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE production_material_peg_transfers
                            SET status = 'REVERSED',
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("id", transferId)
                    .executeUpdate();
            touched.add(demandId);
        }
        ledger.refreshDemandStatuses(touched);
    }

    /**
     * Must run before the purchase receipt row is locked. It acquires every
     * inventory-dimension advisory lock touched by the receipt, including all
     * materials of a pegged execution segment, in the canonical sorted order.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockPurchaseReceiptMutationDimensions(UUID receiptId) {
        List<UUID> warehouses = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT warehouse_id
                                FROM purchase_receipts
                                WHERE id = :receiptId
                                  AND is_deleted = FALSE
                                """)
                        .setParameter("receiptId", receiptId),
                UUID.class);
        if (warehouses.isEmpty() || warehouses.getFirst() == null) {
            return;
        }
        lockReceiptMaterialDimensions(
                receiptId, warehouses.getFirst());
    }

    /**
     * With canonical advisory locks already held, acquires the production
     * demand/peg rows before stock balances are mutated.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockReceiptProductionDemands(
            UUID receiptId, UUID warehouseId) {
        if (receiptId == null || warehouseId == null) {
            return;
        }
        lockReceiptMaterialDimensions(receiptId, warehouseId);
        em.createNativeQuery("""
                        SELECT d.id
                        FROM purchase_receipt_items receipt_item
                        JOIN production_material_supply_pegs peg
                          ON peg.supply_type = 'PURCHASE_ORDER_ITEM'
                         AND peg.supply_item_id =
                             receipt_item.order_item_id
                         AND peg.status <> 'REVERSED'
                         AND peg.allocated_qty
                               - peg.consumed_qty
                               - peg.released_qty > 0
                        JOIN production_material_demands d
                          ON d.id = peg.demand_id
                         AND d.is_deleted = FALSE
                         AND d.warehouse_id = :warehouseId
                        JOIN production_planning_packages package
                          ON package.id = d.package_id
                         AND package.is_deleted = FALSE
                         AND package.status = 'CONFIRMED'
                        WHERE receipt_item.receipt_id = :receiptId
                          AND receipt_item.is_deleted = FALSE
                        ORDER BY d.id, peg.id
                        FOR UPDATE OF d, peg, package
                        """)
                .setParameter("receiptId", receiptId)
                .setParameter("warehouseId", warehouseId)
                .getResultList();
    }

    /**
     * Converts only the part received into the exact demand target warehouse.
     * An order line may serve several warehouses, so a receipt for warehouse A
     * deliberately leaves warehouse B's future peg untouched.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void onPurchaseReceiptApproved(UUID receiptId) {
        advancePurchaseReceipt(receiptId, null);
    }

    private void advancePurchaseReceipt(
            UUID receiptId, UUID dispositionEventId) {
        advancePurchaseReceiptState(receiptId, dispositionEventId);
        materialAnalysisWakeup.afterPurchaseReceiptApproved(receiptId);
    }

    /**
     * IQC 仓库确认入库（一张收货单一批，整批同事务）后的生产推进：
     * 正式履约按收货单累计入库量推进一次（领取/预留/领料单的最终数据
     * 与逐条推进一致，不再每条明细重复整单扫描），随后对受影响物料
     * 分析做整批一轮唤醒刷新（事件按批聚合）。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseInspectionStockInConfirmed(
            UUID receiptId, UUID warehouseStockInBatchId,
            Collection<UUID> inspectionItemIds) {
        advancePurchaseReceiptState(receiptId, warehouseStockInBatchId);
        materialAnalysisWakeup.afterInspectionStockInConfirmed(
                "PURCHASE", receiptId, warehouseStockInBatchId,
                inspectionItemIds);
    }

    /**
     * State transition only: converts only the part received into the exact
     * demand target warehouse. An order line may serve several warehouses, so
     * a receipt for warehouse A deliberately leaves warehouse B's future peg
     * untouched. Callers own the trailing material-analysis wakeup so the IQC
     * stock-in path can refresh once per confirmed batch instead of per slice.
     */
    private void advancePurchaseReceiptState(
            UUID receiptId, UUID dispositionEventId) {
        UUID actorId = currentUser.requireId();
        UUID employeeId = currentUser.requireEmployeeId();
        List<UUID> warehouses = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT warehouse_id
                                FROM purchase_receipts
                                WHERE id = :receiptId
                                  AND is_deleted = FALSE
                                  AND status = 1
                                FOR UPDATE
                                """)
                        .setParameter("receiptId", receiptId),
                UUID.class);
        if (warehouses.isEmpty() || warehouses.getFirst() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "采购收货单缺少目标仓库，不能转为生产备料");
        }
        UUID warehouseId = warehouses.getFirst();
        List<Object[]> receiptItems = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT receipt_item.id,
                                       receipt_item.order_item_id,
                                       CASE
                                           WHEN inspection.id IS NULL
                                           THEN receipt_item.qty
                                               * COALESCE(
                                                   receipt_item.unit_rate, 1)
                                           ELSE inspection.warehouse_stocked_base_qty
                                       END AS qualified_base_qty
                                FROM purchase_receipt_items receipt_item
                                LEFT JOIN procurement_inspection_items inspection
                                  ON inspection.receipt_type = 'PURCHASE'
                                 AND inspection.receipt_item_id = receipt_item.id
                                WHERE receipt_item.receipt_id = :receiptId
                                  AND receipt_item.is_deleted = FALSE
                                  AND receipt_item.order_item_id IS NOT NULL
                                  AND (
                                      inspection.id IS NULL
                                      OR (
                                          inspection.status IN (
                                              'PARTIAL', 'RESOLVED')
                                          AND inspection.warehouse_stocked_base_qty > 0
                                      )
                                  )
                                ORDER BY receipt_item.order_item_id,
                                         receipt_item.id
                                FOR UPDATE OF receipt_item
                                """)
                        .setParameter("receiptId", receiptId));

        Map<ReceiptPackage, DrawHandle> draws = new HashMap<>();
        Set<UUID> touched = new LinkedHashSet<>();
        for (Object[] receiptItem : receiptItems) {
            UUID receiptItemId = uuid(receiptItem[0]);
            UUID orderItemId = uuid(receiptItem[1]);
            BigDecimal receivedBase = decimal(receiptItem[2]);
            BigDecimal replayed = decimal(em.createNativeQuery("""
                            SELECT COALESCE(SUM(allocated_qty), 0)
                            FROM production_material_receipt_allocations
                            WHERE receipt_item_id = :receiptItemId
                              AND status = 'EFFECTIVE'
                            """)
                    .setParameter("receiptItemId", receiptItemId)
                    .getSingleResult());
            BigDecimal remaining = receivedBase.subtract(replayed);
            if (remaining.signum() <= 0) {
                continue;
            }

            List<Object[]> candidates = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT p.id, d.id, d.package_id, d.plan_id,
                                           plan.bill_no, d.goods_id, d.color_id,
                                           d.unit_id, p.allocated_qty,
                                           p.consumed_qty, p.released_qty
                                    FROM production_material_supply_pegs p
                                    JOIN production_material_demands d
                                      ON d.id = p.demand_id
                                     AND d.is_deleted = FALSE
                                     AND d.execution_segment_id IS NULL
                                    JOIN production_planning_packages package
                                      ON package.id = d.package_id
                                     AND package.is_deleted = FALSE
                                     AND package.status = 'CONFIRMED'
                                    JOIN production_plans plan
                                      ON plan.id = d.plan_id
                                    WHERE p.supply_type = 'PURCHASE_ORDER_ITEM'
                                      AND p.supply_item_id = :orderItemId
                                      AND p.status <> 'REVERSED'
                                      AND p.allocated_qty
                                            - p.consumed_qty
                                            - p.released_qty > 0
                                      AND d.warehouse_id = :warehouseId
                                    ORDER BY d.need_date NULLS LAST, d.id, p.id
                                    FOR UPDATE OF p, d, package
                                    """)
                            .setParameter("orderItemId", orderItemId)
                            .setParameter("warehouseId", warehouseId));
            Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                    StockGoodsSnapshot.fromMaster(
                            em,
                            candidates.stream()
                                    .map(candidate -> uuid(candidate[5]))
                                    .toList(),
                            StockGoodsSnapshot.MASTER_AT_SAVE);

            for (Object[] candidate : candidates) {
                if (remaining.signum() <= 0) {
                    break;
                }
                UUID pegId = uuid(candidate[0]);
                UUID demandId = uuid(candidate[1]);
                UUID packageId = uuid(candidate[2]);
                UUID planId = uuid(candidate[3]);
                String planNo = (String) candidate[4];
                UUID goodsId = uuid(candidate[5]);
                UUID colorId = uuid(candidate[6]);
                UUID unitId = uuid(candidate[7]);
                BigDecimal available = decimal(candidate[8])
                        .subtract(decimal(candidate[9]))
                        .subtract(decimal(candidate[10]));
                BigDecimal quantity = remaining.min(available);
                if (quantity.signum() <= 0) {
                    continue;
                }

                UUID balanceId = lockBalance(
                        warehouseId, goodsId, colorId);
                em.createNativeQuery("""
                                UPDATE production_material_supply_pegs
                                SET consumed_qty = consumed_qty + :qty,
                                    status = CASE
                                        WHEN consumed_qty + released_qty + :qty
                                             = allocated_qty
                                        THEN 'DONE'
                                        ELSE 'EFFECTIVE'
                                    END,
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :pegId
                                """)
                        .setParameter("qty", quantity)
                        .setParameter("actorId", actorId)
                        .setParameter("pegId", pegId)
                        .executeUpdate();

                UUID reservationId = extendOrCreateReservation(
                        receiptId,
                        demandId,
                        packageId,
                        warehouseId,
                        goodsId,
                        colorId,
                        balanceId,
                        quantity,
                        actorId);
                ReceiptPackage receiptPackage =
                        new ReceiptPackage(receiptId, packageId);
                DrawHandle draw = draws.computeIfAbsent(
                        receiptPackage,
                        ignored -> createReceiptDraw(
                                packageId,
                                planId,
                                planNo,
                                warehouseId,
                                actorId,
                                employeeId));
                UUID drawItemId = addDrawItem(
                        draw,
                        packageId,
                        demandId,
                        goodsId,
                        colorId,
                        unitId,
                        quantity,
                        planNo,
                        actorId,
                        StockGoodsSnapshot.require(
                                goodsSnapshots,
                                goodsId,
                                "采购到货转生产领料明细"));

                em.createNativeQuery("""
                                INSERT INTO production_material_receipt_allocations (
                                    receipt_id, receipt_item_id, package_id,
                                    demand_id, order_peg_id, reservation_id,
                                    draw_id, draw_item_id, allocated_qty,
                                    status, idempotency_key, created_at,
                                    updated_at, created_by, updated_by
                                ) VALUES (
                                    :receiptId, :receiptItemId, :packageId,
                                    :demandId, :pegId, :reservationId,
                                    :drawId, :drawItemId, :qty,
                                    'EFFECTIVE', :key, now(), now(),
                                    :actorId, :actorId
                                )
                                """)
                        .setParameter("receiptId", receiptId)
                        .setParameter("receiptItemId", receiptItemId)
                        .setParameter("packageId", packageId)
                        .setParameter("demandId", demandId)
                        .setParameter("pegId", pegId)
                        .setParameter("reservationId", reservationId)
                        .setParameter("drawId", draw.id())
                        .setParameter("drawItemId", drawItemId)
                        .setParameter("qty", quantity)
                        .setParameter(
                                "key",
                                receiptAllocationKey(
                                        receiptItemId,
                                        pegId,
                                        dispositionEventId))
                        .setParameter("actorId", actorId)
                        .executeUpdate();
                touched.add(demandId);
                remaining = remaining.subtract(quantity);
            }
        }
        draws.values().forEach(draw ->
                chainNotice.notifyProductionDrawPending(draw.id()));
        executionReadiness.onPurchaseReceiptApproved(receiptId, warehouseId);
        ledger.refreshDemandStatuses(touched);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseReceiptReversed(UUID receiptId) {
        materialAnalysisWakeup.afterPurchaseReceiptReversed(receiptId);
    }

    /**
     * Reverses receipt-created reservations and DRAW items before physical
     * stock is removed. Any issued downstream DRAW item blocks the reversal.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforePurchaseReceiptReversed(UUID receiptId) {
        executionReadiness.beforePurchaseReceiptReversed(receiptId);
        UUID actorId = currentUser.requireId();
        List<Object[]> allocations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.id, a.demand_id, a.order_peg_id,
                                       a.reservation_id, a.draw_id,
                                       a.draw_item_id, a.allocated_qty,
                                       r.qty, r.consumed_qty, r.released_qty,
                                       item.issued_qty,
                                       COALESCE((
                                           SELECT SUM(CASE posting_type
                                               WHEN 'ISSUE' THEN qty_base
                                               WHEN 'ISSUE_REVERSE' THEN -qty_base
                                               ELSE 0 END)
                                           FROM production_material_stock_postings
                                           WHERE stock_document_item_id = item.id
                                             AND posting_type IN (
                                                 'ISSUE', 'ISSUE_REVERSE')
                                       ), 0) AS ledger_issued
                                FROM production_material_receipt_allocations a
                                JOIN production_material_demands d
                                  ON d.id = a.demand_id
                                 AND d.execution_segment_id IS NULL
                                JOIN production_material_supply_pegs p
                                  ON p.id = a.order_peg_id
                                JOIN stock_reservations r
                                  ON r.id = a.reservation_id
                                JOIN stock_documents draw
                                  ON draw.id = a.draw_id
                                JOIN stock_document_items item
                                  ON item.id = a.draw_item_id
                                WHERE a.receipt_id = :receiptId
                                  AND a.status = 'EFFECTIVE'
                                ORDER BY a.demand_id, a.id
                                FOR UPDATE OF a, d, p, r, draw, item
                                """)
                        .setParameter("receiptId", receiptId));

        Map<UUID, BigDecimal> reverseByReservation = new HashMap<>();
        Map<UUID, ReservationState> reservationStates = new HashMap<>();
        for (Object[] allocation : allocations) {
            UUID reservationId = uuid(allocation[3]);
            BigDecimal quantity = decimal(allocation[6]);
            reverseByReservation.merge(
                    reservationId, quantity, BigDecimal::add);
            reservationStates.putIfAbsent(
                    reservationId,
                    new ReservationState(
                            decimal(allocation[7]),
                            decimal(allocation[8]),
                            decimal(allocation[9])));
            if (decimal(allocation[10]).signum() > 0
                    || decimal(allocation[11]).signum() > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购收货已生成的生产领料单存在发料或占用消耗，必须先反出库");
            }
        }
        for (Map.Entry<UUID, BigDecimal> entry
                : reverseByReservation.entrySet()) {
            ReservationState state =
                    reservationStates.get(entry.getKey());
            BigDecimal open = state.qty()
                    .subtract(state.consumedQty())
                    .subtract(state.releasedQty());
            if (open.compareTo(entry.getValue()) < 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购收货对应的生产预留已被下游占用，必须先完成反向处理");
            }
            BigDecimal remainingQty =
                    state.qty().subtract(entry.getValue());
            if (remainingQty.signum() == 0
                    && state.consumedQty().signum() == 0
                    && state.releasedQty().signum() == 0) {
                em.createNativeQuery("""
                                UPDATE stock_reservations
                                SET released_qty = qty,
                                    status = :releasedStatus,
                                    is_deleted = TRUE,
                                    deleted_at = now(),
                                    release_reason =
                                        'PURCHASE_RECEIPT_REVERSED',
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :id
                                """)
                        .setParameter(
                                "releasedStatus", RESERVATION_RELEASED)
                        .setParameter("actorId", actorId)
                        .setParameter("id", entry.getKey())
                        .executeUpdate();
            } else {
                short status = remainingQty.compareTo(
                        state.consumedQty()
                                .add(state.releasedQty())) == 0
                        ? RESERVATION_DONE
                        : RESERVATION_EFFECTIVE;
                em.createNativeQuery("""
                                UPDATE stock_reservations
                                SET qty = qty - :qty,
                                    status = :status,
                                    lock_version = lock_version + 1,
                                    updated_at = now(),
                                    updated_by = :actorId
                                WHERE id = :id
                                """)
                        .setParameter("qty", entry.getValue())
                        .setParameter("status", status)
                        .setParameter("actorId", actorId)
                        .setParameter("id", entry.getKey())
                        .executeUpdate();
            }
        }

        Set<UUID> touched = new LinkedHashSet<>();
        Set<UUID> drawIds = new LinkedHashSet<>();
        for (Object[] allocation : allocations) {
            UUID allocationId = uuid(allocation[0]);
            UUID demandId = uuid(allocation[1]);
            UUID pegId = uuid(allocation[2]);
            UUID drawId = uuid(allocation[4]);
            UUID drawItemId = uuid(allocation[5]);
            BigDecimal quantity = decimal(allocation[6]);

            ledger.authorizeDraftDrawCleanup(drawId);
            em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET consumed_qty = consumed_qty - :qty,
                                status = 'EFFECTIVE',
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                              AND consumed_qty >= :qty
                            """)
                    .setParameter("qty", quantity)
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", pegId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE production_material_receipt_allocations
                            SET status = 'REVERSED',
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("id", allocationId)
                    .executeUpdate();
            em.createNativeQuery("""
                            DELETE FROM production_planning_package_document_items
                            WHERE document_type = 'DRAW'
                              AND document_item_id = :itemId
                            """)
                    .setParameter("itemId", drawItemId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE stock_document_items
                            SET is_deleted = TRUE,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :itemId
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("itemId", drawItemId)
                    .executeUpdate();
            touched.add(demandId);
            drawIds.add(drawId);
        }

        for (UUID drawId : drawIds) {
            ledger.authorizeDraftDrawCleanup(drawId);
            Number activeItems = (Number) em.createNativeQuery("""
                            SELECT COUNT(*)
                            FROM stock_document_items
                            WHERE doc_id = :drawId
                              AND is_deleted = FALSE
                            """)
                    .setParameter("drawId", drawId)
                    .getSingleResult();
            if (activeItems.longValue() > 0) {
                continue;
            }
            em.createNativeQuery("""
                            UPDATE stock_documents
                            SET status = -1,
                                is_deleted = TRUE,
                                deleted_at = now(),
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :drawId
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("drawId", drawId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE plan_draw_links
                            SET is_deleted = TRUE,
                                deleted_at = now()
                            WHERE draw_id = :drawId
                              AND is_deleted = FALSE
                            """)
                    .setParameter("drawId", drawId)
                    .executeUpdate();
            em.createNativeQuery("""
                            DELETE FROM production_planning_package_documents
                            WHERE document_type = 'DRAW'
                              AND document_id = :drawId
                            """)
                    .setParameter("drawId", drawId)
                    .executeUpdate();
        }
        ledger.refreshDemandStatuses(touched);
    }

    private void lockReceiptMaterialDimensions(
            UUID receiptId, UUID warehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                WITH receipt_segments AS (
                                    SELECT DISTINCT
                                           demand.execution_segment_id
                                    FROM purchase_receipt_items receipt_item
                                    JOIN production_material_supply_pegs peg
                                      ON peg.supply_type =
                                             'PURCHASE_ORDER_ITEM'
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
                                    FROM purchase_receipt_items receipt_item
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
                                      AND candidate.warehouse_id = :warehouseId
                                )
                                SELECT DISTINCT
                                       goods_id, color_id
                                FROM dimensions
                                ORDER BY goods_id,
                                         color_id NULLS FIRST
                                """)
                        .setParameter("receiptId", receiptId)
                        .setParameter("warehouseId", warehouseId));
        stockAllocation.lockMaterialDimensions(rows.stream()
                .map(row ->
                        new ProductionMaterialAllocationFacade.MaterialDimension(
                                uuid(row[0]), uuid(row[1])))
                .toList());
    }

    private UUID lockBalance(
            UUID warehouseId,
            UUID goodsId,
            UUID colorId) {
        List<?> rows = em.createNativeQuery("""
                        SELECT id
                        FROM stock_balances
                        WHERE warehouse_id = :warehouseId
                          AND goods_id = :goodsId
                          AND color_id IS NOT DISTINCT
                              FROM CAST(:colorId AS uuid)
                        FOR UPDATE
                        """, UUID.class)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "采购收货库存余额尚未落账，不能生成生产物料预留");
        }
        return uuid(rows.getFirst());
    }

    private UUID extendOrCreateReservation(
            UUID receiptId,
            UUID demandId,
            UUID packageId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            UUID balanceId,
            BigDecimal quantity,
            UUID actorId) {
        List<UUID> existing = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT id
                                FROM stock_reservations
                                WHERE demand_id = :demandId
                                  AND supply_id = :balanceId
                                  AND owner_type =
                                      'PRODUCTION_MATERIAL_DEMAND'
                                  AND is_deleted = FALSE
                                FOR UPDATE
                                """)
                        .setParameter("demandId", demandId)
                        .setParameter("balanceId", balanceId),
                UUID.class);
        if (!existing.isEmpty()) {
            UUID reservationId = existing.getFirst();
            em.createNativeQuery("""
                            UPDATE stock_reservations
                            SET qty = qty + :qty,
                                status = :effectiveStatus,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :id
                            """)
                    .setParameter("qty", quantity)
                    .setParameter(
                            "effectiveStatus", RESERVATION_EFFECTIVE)
                    .setParameter("actorId", actorId)
                    .setParameter("id", reservationId)
                    .executeUpdate();
            return reservationId;
        }

        UUID reservationId = UUID.randomUUID();
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
                            'PURCHASE_RECEIPT', :receiptId,
                            'PRODUCTION_MATERIAL_DEMAND', :demandId,
                            'PRODUCTION_MATERIAL', :demandId,
                            'STOCK_BALANCE', :balanceId, :key,
                            now(), now(), :actorId, :actorId, FALSE, 0
                        )
                        """)
                .setParameter("id", reservationId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("qty", quantity)
                .setParameter("status", RESERVATION_EFFECTIVE)
                .setParameter("source", PRODUCTION_MATERIAL_SOURCE)
                .setParameter("receiptId", receiptId)
                .setParameter("demandId", demandId)
                .setParameter("balanceId", balanceId)
                .setParameter(
                        "key",
                        receiptId + ":RECEIPT-STOCK:" + demandId)
                .setParameter("actorId", actorId)
                .executeUpdate();
        return reservationId;
    }

    private static String receiptAllocationKey(
            UUID receiptItemId,
            UUID pegId,
            UUID dispositionEventId) {
        String base = "RECEIPT-STOCK:" + receiptItemId + ":" + pegId;
        return dispositionEventId == null
                ? base
                : base + ":IQC_PASS:" + dispositionEventId;
    }

    private DrawHandle createReceiptDraw(
            UUID packageId,
            UUID planId,
            String planNo,
            UUID warehouseId,
            UUID actorId,
            UUID employeeId) {
        StockDocument document = new StockDocument();
        document.setDocType("DRAW");
        document.setBillNo(
                docNumberService.nextNumber(DocNumberPrefix.STOCK_DRAW));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(warehouseId);
        document.setPlanNo(planNo);
        document.setSourceDocNo(planNo);
        document.setRemark("采购到货转生产备料，计划包 " + packageId);
        document.setWorkerId(employeeId);
        document.setMakerId(employeeId);
        document.setStatus((short) 0);
        stockDocumentRepo.saveAndFlush(document);

        ledger.recordDocument(
                packageId,
                "DRAW",
                document.getId(),
                document.getBillNo(),
                actorId);
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(
                            plan_id, draw_id, created_by
                        ) VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", planId)
                .setParameter("drawId", document.getId())
                .setParameter("actorId", actorId)
                .executeUpdate();
        return new DrawHandle(document.getId(), document.getBillNo());
    }

    private UUID addDrawItem(
            DrawHandle draw,
            UUID packageId,
            UUID demandId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal quantity,
            String planNo,
            UUID actorId,
            StockGoodsSnapshot goodsSnapshot) {
        Number maxLine = (Number) em.createNativeQuery("""
                        SELECT COALESCE(MAX(line_no), 0)
                        FROM stock_document_items
                        WHERE doc_id = :drawId
                        """)
                .setParameter("drawId", draw.id())
                .getSingleResult();
        StockDocumentItem item = new StockDocumentItem();
        item.setDocId(draw.id());
        item.setBillType("DRAW");
        item.setBillNo(draw.billNo());
        item.setBillDate(BusinessTime.today());
        item.setLineNo(maxLine.intValue() + 1);
        item.setGoodsId(goodsId);
        goodsSnapshot.applyTo(item, null);
        item.setColorId(colorId);
        item.setUnitId(unitId);
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(quantity);
        item.setBaseQty(quantity);
        item.setSourceDocNo(planNo);
        item.setRemark("采购到货需求 " + demandId);
        stockDocumentItemRepo.saveAndFlush(item);

        em.createNativeQuery("""
                        INSERT INTO production_planning_package_document_items (
                            package_id, demand_id, document_type,
                            document_id, document_item_id, created_by
                        ) VALUES (
                            :packageId, :demandId, 'DRAW',
                            :drawId, :itemId, :actorId
                        )
                        """)
                .setParameter("packageId", packageId)
                .setParameter("demandId", demandId)
                .setParameter("drawId", draw.id())
                .setParameter("itemId", item.getId())
                .setParameter("actorId", actorId)
                .executeUpdate();
        return item.getId();
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) {
            return BigDecimal.ZERO;
        }
        return value instanceof BigDecimal decimal
                ? decimal
                : new BigDecimal(value.toString());
    }

    private static UUID uuid(Object value) {
        if (value == null) {
            return null;
        }
        return value instanceof UUID uuid
                ? uuid
                : UUID.fromString(value.toString());
    }

    /**
     * 原生 SQL 读 PG {@code date} 列时 Hibernate 返回 {@link java.sql.Date}，直接强转
     * {@link LocalDate} 会抛 {@link ClassCastException}（明细含 deliver_date 即触发，见审批链）。
     * 与 {@code decimal()}/{@code uuid()} 同型的安全转换。
     */
    private static LocalDate localDate(Object value) {
        if (value == null) {
            return null;
        }
        return value instanceof LocalDate ld
                ? ld
                : ((java.sql.Date) value).toLocalDate();
    }

    private record ReceiptPackage(UUID receiptId, UUID packageId) {}

    private record DrawHandle(UUID id, String billNo) {}

    private record ReservationState(
            BigDecimal qty,
            BigDecimal consumedQty,
            BigDecimal releasedQty) {}
}
