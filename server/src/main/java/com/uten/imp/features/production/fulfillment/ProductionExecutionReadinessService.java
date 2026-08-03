package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Re-kits WAITING execution segments after purchase stock lands.
 *
 * <p>No partial reservation is ever persisted. The service first acquires all
 * material advisory locks and proves that every demand is coverable, then
 * atomically reserves the complete set, creates one exact segment DRAW and
 * promotes WAITING to READY.
 */
@Service
@RequiredArgsConstructor
public class ProductionExecutionReadinessService {

    private static final short RESERVATION_EFFECTIVE = 0;

    private final EntityManager em;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionFulfillmentLedgerService ledger;
    private final StockDocumentRepository stockDocumentRepo;
    private final StockDocumentItemRepository stockDocumentItemRepo;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ChainNoticeService chainNotice;

    @Transactional(propagation = Propagation.MANDATORY)
    public void onPurchaseReceiptApproved(
            UUID triggeringReceiptId,
            UUID warehouseId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT d.execution_segment_id
                        FROM purchase_receipt_items receipt_item
                        JOIN production_material_supply_pegs peg
                          ON peg.supply_type = 'PURCHASE_ORDER_ITEM'
                         AND peg.supply_item_id =
                             receipt_item.order_item_id
                         AND peg.status <> 'REVERSED'
                        JOIN production_material_demands d
                          ON d.id = peg.demand_id
                         AND d.execution_segment_id IS NOT NULL
                         AND d.is_deleted = FALSE
                         AND d.warehouse_id = :warehouseId
                        JOIN production_execution_segments segment
                          ON segment.id = d.execution_segment_id
                         AND segment.status = 'WAITING'
                         AND segment.auto_promote_when_ready = TRUE
                         AND segment.is_deleted = FALSE
                        WHERE receipt_item.receipt_id = :receiptId
                          AND receipt_item.is_deleted = FALSE
                        ORDER BY d.execution_segment_id
                        """, UUID.class)
                .setParameter("receiptId", triggeringReceiptId)
                .setParameter("warehouseId", warehouseId), UUID.class);
        for (UUID segmentId : segmentIds) {
            tryPromote(
                    segmentId,
                    triggeringReceiptId,
                    warehouseId,
                    ReceiptKind.PURCHASE);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void onSubcontractReceiptApproved(
            UUID triggeringReceiptId,
            UUID warehouseId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT demand.execution_segment_id
                        FROM subcontract_receipt_items receipt_item
                        JOIN production_material_supply_pegs peg
                          ON peg.supply_type =
                                'SUBCONTRACT_ORDER_ITEM'
                         AND peg.supply_item_id =
                                receipt_item.order_item_id
                         AND peg.status <> 'REVERSED'
                        JOIN production_material_demands demand
                          ON demand.id = peg.demand_id
                         AND demand.execution_segment_id IS NOT NULL
                         AND demand.is_deleted = FALSE
                         AND demand.warehouse_id = :warehouseId
                        JOIN production_execution_segments segment
                          ON segment.id = demand.execution_segment_id
                         AND segment.status = 'WAITING'
                         AND segment.auto_promote_when_ready = TRUE
                         AND segment.is_deleted = FALSE
                        WHERE receipt_item.receipt_id = :receiptId
                          AND receipt_item.is_deleted = FALSE
                        ORDER BY demand.execution_segment_id
                        """, UUID.class)
                .setParameter("receiptId", triggeringReceiptId)
                .setParameter("warehouseId", warehouseId), UUID.class);
        for (UUID segmentId : segmentIds) {
            tryPromote(
                    segmentId,
                    triggeringReceiptId,
                    warehouseId,
                    ReceiptKind.SUBCONTRACT);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void lockFinishedInboundProductionDimensions(
            UUID receiptId,
            UUID warehouseId) {
        if (receiptId == null || warehouseId == null) {
            return;
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                WITH receipt_segments AS (
                                    SELECT DISTINCT
                                           demand.execution_segment_id
                                    FROM stock_document_items receipt_item
                                    JOIN production_material_supply_pegs peg
                                      ON peg.supply_type =
                                            'PRODUCTION_PLAN_ITEM'
                                     AND peg.supply_item_id =
                                            receipt_item.upstream_item_id
                                     AND peg.status <> 'REVERSED'
                                    JOIN production_material_demands demand
                                      ON demand.id = peg.demand_id
                                     AND demand.execution_segment_id
                                            IS NOT NULL
                                     AND demand.is_deleted = FALSE
                                     AND demand.warehouse_id = :warehouseId
                                    JOIN production_execution_segments segment
                                      ON segment.id =
                                            demand.execution_segment_id
                                     AND segment.is_deleted = FALSE
                                     AND segment.auto_promote_when_ready = TRUE
                                    JOIN production_planning_packages package
                                      ON package.id = segment.package_id
                                     AND package.status = 'CONFIRMED'
                                     AND package.execution_model_version = 1
                                     AND package.is_deleted = FALSE
                                    WHERE receipt_item.doc_id = :receiptId
                                      AND receipt_item.bill_type =
                                            'FINISHED_IN'
                                      AND receipt_item.is_deleted = FALSE
                                ), dimensions AS (
                                    SELECT receipt_item.goods_id,
                                           receipt_item.color_id
                                    FROM stock_document_items receipt_item
                                    WHERE receipt_item.doc_id = :receiptId
                                      AND receipt_item.bill_type =
                                            'FINISHED_IN'
                                      AND receipt_item.is_deleted = FALSE
                                      AND receipt_item.goods_id IS NOT NULL
                                    UNION ALL
                                    SELECT demand.goods_id, demand.color_id
                                    FROM receipt_segments source
                                    JOIN production_material_demands demand
                                      ON demand.execution_segment_id =
                                            source.execution_segment_id
                                     AND demand.is_deleted = FALSE
                                     AND demand.status NOT IN (
                                            'RELEASED', 'REVERSED')
                                     AND demand.warehouse_id = :warehouseId
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

    @Transactional(propagation = Propagation.MANDATORY)
    public void onFinishedInboundApproved(
            UUID triggeringReceiptId,
            UUID warehouseId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT DISTINCT demand.execution_segment_id
                                FROM stock_document_items receipt_item
                                JOIN stock_documents receipt
                                  ON receipt.id = receipt_item.doc_id
                                 AND receipt.doc_type = 'FINISHED_IN'
                                 AND receipt.is_deleted = FALSE
                                 AND receipt.warehouse_id = :warehouseId
                                JOIN production_material_supply_pegs peg
                                  ON peg.supply_type =
                                        'PRODUCTION_PLAN_ITEM'
                                 AND peg.supply_item_id =
                                        receipt_item.upstream_item_id
                                 AND peg.status <> 'REVERSED'
                                JOIN production_material_demands demand
                                  ON demand.id = peg.demand_id
                                 AND demand.execution_segment_id IS NOT NULL
                                 AND demand.is_deleted = FALSE
                                 AND demand.warehouse_id = :warehouseId
                                JOIN production_execution_segments segment
                                  ON segment.id = demand.execution_segment_id
                                 AND segment.status = 'WAITING'
                                 AND segment.auto_promote_when_ready = TRUE
                                 AND segment.is_deleted = FALSE
                                WHERE receipt_item.doc_id = :receiptId
                                  AND receipt_item.bill_type = 'FINISHED_IN'
                                  AND receipt_item.is_deleted = FALSE
                                ORDER BY demand.execution_segment_id
                                """, UUID.class)
                        .setParameter("receiptId", triggeringReceiptId)
                        .setParameter("warehouseId", warehouseId),
                UUID.class);
        for (UUID segmentId : segmentIds) {
            tryPromote(
                    segmentId,
                    triggeringReceiptId,
                    warehouseId,
                    ReceiptKind.MAKE);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeFinishedInboundReversed(UUID receiptId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT DISTINCT demand.execution_segment_id
                                FROM production_material_make_receipt_allocations
                                     allocation
                                JOIN production_material_demands demand
                                  ON demand.id = allocation.demand_id
                                WHERE allocation.receipt_id = :receiptId
                                  AND allocation.status = 'EFFECTIVE'
                                  AND demand.execution_segment_id IS NOT NULL
                                ORDER BY demand.execution_segment_id
                                """, UUID.class)
                        .setParameter("receiptId", receiptId),
                UUID.class);
        for (UUID segmentId : segmentIds) {
            unwindPromotedSegment(segmentId);
        }
    }

    /**
     * A receipt that contributed to a promoted complete kit can only be
     * reversed by demoting the whole unstarted segment. All of that segment's
     * reservations, DRAW lines and receipt conversions are unwound together;
     * issued or dispatched work remains fail-closed.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforePurchaseReceiptReversed(UUID receiptId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT demand.execution_segment_id
                        FROM production_material_receipt_allocations allocation
                        JOIN production_material_demands demand
                          ON demand.id = allocation.demand_id
                        WHERE allocation.receipt_id = :receiptId
                          AND allocation.status = 'EFFECTIVE'
                          AND demand.execution_segment_id IS NOT NULL
                        ORDER BY demand.execution_segment_id
                        """, UUID.class)
                .setParameter("receiptId", receiptId), UUID.class);
        for (UUID segmentId : segmentIds) {
            unwindPromotedSegment(segmentId);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeSubcontractReceiptReversed(UUID receiptId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT demand.execution_segment_id
                        FROM
                          production_material_subcontract_receipt_allocations
                            allocation
                        JOIN production_material_demands demand
                          ON demand.id = allocation.demand_id
                        WHERE allocation.receipt_id = :receiptId
                          AND allocation.status = 'EFFECTIVE'
                          AND demand.execution_segment_id IS NOT NULL
                        ORDER BY demand.execution_segment_id
                        """, UUID.class)
                .setParameter("receiptId", receiptId), UUID.class);
        for (UUID segmentId : segmentIds) {
            unwindPromotedSegment(segmentId);
        }
    }

    private void unwindPromotedSegment(UUID segmentId) {
        List<Object[]> segmentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT segment.package_id, segment.status
                                FROM production_execution_segments segment
                                JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                 AND package.status = 'CONFIRMED'
                                 AND package.execution_model_version = 1
                                 AND package.is_deleted = FALSE
                                WHERE segment.id = :segmentId
                                  AND segment.is_deleted = FALSE
                                FOR UPDATE OF segment, package
                                """)
                        .setParameter("segmentId", segmentId));
        if (segmentRows.size() != 1
                || !ProductionExecutionSegment.STATUS_READY.equals(
                        segmentRows.getFirst()[1])) {
            throw conflict(
                    "收货关联的执行分段已不是未开工的「就绪」状态");
        }
        UUID packageId = uuid(segmentRows.getFirst()[0]);
        UUID actorId = currentUser.requireId();

        List<UUID> demandIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id
                        FROM production_material_demands
                        WHERE execution_segment_id = :segmentId
                          AND is_deleted = FALSE
                          AND status NOT IN ('RELEASED', 'REVERSED')
                        ORDER BY goods_id, color_id NULLS FIRST, id
                        FOR UPDATE
                        """, UUID.class)
                .setParameter("segmentId", segmentId), UUID.class);
        if (demandIds.isEmpty()) {
            throw conflict(
                    "收货关联的执行分段没有有效的物料需求");
        }

        List<Object[]> reservations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, consumed_qty, released_qty,
                                       is_deleted
                                FROM stock_reservations
                                WHERE demand_id IN (:demandIds)
                                  AND owner_type =
                                      'PRODUCTION_MATERIAL_DEMAND'
                                ORDER BY goods_id,
                                         color_id NULLS FIRST,
                                         supply_id, id
                                FOR UPDATE
                                """)
                        .setParameter("demandIds", demandIds));
        if (reservations.isEmpty()
                || reservations.stream().anyMatch(row ->
                        Boolean.TRUE.equals(row[3])
                                || decimal(row[1]).signum() > 0
                                || decimal(row[2]).signum() > 0)) {
            throw conflict(
                    "收货关联的执行分段已发料或已释放物料，不能回退");
        }

        List<Object[]> draws = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT header.document_id,
                                       document.status,
                                       document.is_deleted
                                FROM
                                  production_planning_package_documents header
                                JOIN stock_documents document
                                  ON document.id = header.document_id
                                 AND document.doc_type = 'DRAW'
                                WHERE header.package_id = :packageId
                                  AND header.execution_segment_id = :segmentId
                                  AND header.document_type = 'DRAW'
                                ORDER BY header.document_id
                                FOR UPDATE OF header, document
                                """)
                        .setParameter("packageId", packageId)
                        .setParameter("segmentId", segmentId));
        if (draws.isEmpty()
                || draws.stream().anyMatch(row ->
                        ((Number) row[1]).shortValue() != 0
                                || Boolean.TRUE.equals(row[2]))) {
            throw conflict(
                    "收货关联的执行分段领料单已不是草稿状态");
        }
        List<UUID> drawIds = draws.stream()
                .map(row -> uuid(row[0]))
                .toList();

        List<Object[]> drawItems = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT item.id, item.issued_qty
                                FROM stock_document_items item
                                WHERE item.doc_id IN (:drawIds)
                                  AND item.is_deleted = FALSE
                                ORDER BY item.id
                                FOR UPDATE
                                """)
                        .setParameter("drawIds", drawIds));
        Object postings = em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_material_stock_postings posting
                        JOIN stock_document_items item
                          ON item.id = posting.stock_document_item_id
                        WHERE item.doc_id IN (:drawIds)
                        """)
                .setParameter("drawIds", drawIds)
                .getSingleResult();
        if (drawItems.isEmpty()
                || drawItems.stream().anyMatch(row ->
                        decimal(row[1]).signum() > 0)
                || ((Number) postings).longValue() > 0) {
            throw conflict(
                    "收货关联的执行分段物料已发出，不能回退");
        }

        List<ReceiptAllocationRow> allocations = new ArrayList<>();
        NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.id,
                                       allocation.order_peg_id,
                                       allocation.allocated_qty,
                                       allocation.draw_id
                                FROM
                                  production_material_receipt_allocations
                                    allocation
                                JOIN production_material_demands demand
                                  ON demand.id = allocation.demand_id
                                JOIN production_material_supply_pegs peg
                                  ON peg.id = allocation.order_peg_id
                                WHERE demand.execution_segment_id = :segmentId
                                  AND allocation.status = 'EFFECTIVE'
                                ORDER BY allocation.order_peg_id,
                                         allocation.id
                                FOR UPDATE OF allocation, peg
                                """)
                        .setParameter("segmentId", segmentId))
                .forEach(row -> allocations.add(
                        new ReceiptAllocationRow(
                                ReceiptKind.PURCHASE,
                                uuid(row[0]),
                                uuid(row[1]),
                                decimal(row[2]),
                                uuid(row[3]))));
        NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.id,
                                       allocation.order_peg_id,
                                       allocation.allocated_qty,
                                       allocation.draw_id
                                FROM
                                  production_material_subcontract_receipt_allocations
                                    allocation
                                JOIN production_material_demands demand
                                  ON demand.id = allocation.demand_id
                                JOIN production_material_supply_pegs peg
                                  ON peg.id = allocation.order_peg_id
                                WHERE demand.execution_segment_id = :segmentId
                                  AND allocation.status = 'EFFECTIVE'
                                ORDER BY allocation.order_peg_id,
                                         allocation.id
                                FOR UPDATE OF allocation, peg
                                """)
                        .setParameter("segmentId", segmentId))
                .forEach(row -> allocations.add(
                        new ReceiptAllocationRow(
                                ReceiptKind.SUBCONTRACT,
                                uuid(row[0]),
                                uuid(row[1]),
                                decimal(row[2]),
                                uuid(row[3]))));
        NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT allocation.id,
                                       allocation.supply_peg_id,
                                       allocation.allocated_qty,
                                       allocation.draw_id
                                FROM
                                  production_material_make_receipt_allocations
                                    allocation
                                JOIN production_material_demands demand
                                  ON demand.id = allocation.demand_id
                                JOIN production_material_supply_pegs peg
                                  ON peg.id = allocation.supply_peg_id
                                WHERE demand.execution_segment_id = :segmentId
                                  AND allocation.status = 'EFFECTIVE'
                                ORDER BY allocation.supply_peg_id,
                                         allocation.id
                                FOR UPDATE OF allocation, peg
                                """)
                        .setParameter("segmentId", segmentId))
                .forEach(row -> allocations.add(
                        new ReceiptAllocationRow(
                                ReceiptKind.MAKE,
                                uuid(row[0]),
                                uuid(row[1]),
                                decimal(row[2]),
                                uuid(row[3]))));
        if (allocations.isEmpty()
                || allocations.stream().anyMatch(row ->
                        !drawIds.contains(row.drawId()))) {
            throw conflict(
                    "收货关联的执行分段溯源信息不完整");
        }

        int demoted = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET status = 'WAITING',
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE id = :segmentId
                          AND status = 'READY'
                        """)
                .setParameter("actorId", actorId)
                .setParameter("segmentId", segmentId)
                .executeUpdate();
        if (demoted != 1) {
            throw conflict(
                    "收货关联的执行分段已被并发修改，请刷新后重试");
        }

        int released = em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty,
                            status = -1,
                            is_deleted = TRUE,
                            deleted_at = now(),
                            release_reason =
                                'RECEIPT_SEGMENT_DEMOTED',
                            lock_version = lock_version + 1,
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE demand_id IN (:demandIds)
                          AND owner_type =
                              'PRODUCTION_MATERIAL_DEMAND'
                          AND is_deleted = FALSE
                          AND consumed_qty = 0
                          AND released_qty = 0
                        """)
                .setParameter("actorId", actorId)
                .setParameter("demandIds", demandIds)
                .executeUpdate();
        if (released != reservations.size()) {
            throw conflict(
                    "收货关联的执行分段库存预留已被并发修改，请刷新后重试");
        }

        Map<UUID, BigDecimal> reverseByPeg = new LinkedHashMap<>();
        Map<ReceiptKind, List<UUID>> allocationIds = new LinkedHashMap<>();
        allocations.forEach(row -> {
            allocationIds.computeIfAbsent(row.kind(), ignored -> new ArrayList<>())
                    .add(row.id());
            reverseByPeg.merge(row.pegId(), row.qty(), BigDecimal::add);
        });
        for (Map.Entry<UUID, BigDecimal> entry :
                reverseByPeg.entrySet()) {
            int updated = em.createNativeQuery("""
                            UPDATE production_material_supply_pegs
                            SET consumed_qty =
                                    consumed_qty - :qty,
                                status = CASE
                                    WHEN consumed_qty - :qty
                                         + released_qty = allocated_qty
                                    THEN CASE
                                        WHEN consumed_qty - :qty = 0
                                             AND released_qty =
                                                 allocated_qty
                                        THEN 'RELEASED'
                                        ELSE 'DONE'
                                    END
                                    ELSE 'EFFECTIVE'
                                END,
                                lock_version = lock_version + 1,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :pegId
                              AND consumed_qty >= :qty
                            """)
                    .setParameter("qty", entry.getValue())
                    .setParameter("actorId", actorId)
                    .setParameter("pegId", entry.getKey())
                    .executeUpdate();
            if (updated != 1) {
                throw conflict(
                        "收货关联的采购供给锚点已被并发修改，请刷新后重试");
            }
        }
        for (Map.Entry<ReceiptKind, List<UUID>> entry
                : allocationIds.entrySet()) {
            String table = allocationTable(entry.getKey());
            int reversed = em.createNativeQuery("""
                            UPDATE %s
                            SET status = 'REVERSED',
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id IN (:allocationIds)
                              AND status = 'EFFECTIVE'
                            """.formatted(table))
                    .setParameter("actorId", actorId)
                    .setParameter(
                            "allocationIds", entry.getValue())
                    .executeUpdate();
            if (reversed != entry.getValue().size()) {
                throw conflict(
                        "收货分配记录已被并发修改，请刷新后重试");
            }
        }

        em.createNativeQuery("""
                        DELETE FROM
                            production_planning_package_document_items
                        WHERE package_id = :packageId
                          AND demand_id IN (:demandIds)
                          AND document_type = 'DRAW'
                          AND document_id IN (:drawIds)
                        """)
                .setParameter("packageId", packageId)
                .setParameter("demandIds", demandIds)
                .setParameter("drawIds", drawIds)
                .executeUpdate();
        for (UUID drawId : drawIds) {
            ledger.authorizeDraftDrawCleanup(drawId);
            em.createNativeQuery("""
                            UPDATE stock_document_items
                            SET is_deleted = TRUE,
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE doc_id = :drawId
                              AND is_deleted = FALSE
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("drawId", drawId)
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE stock_documents
                            SET status = -1,
                                is_deleted = TRUE,
                                deleted_at = now(),
                                updated_at = now(),
                                updated_by = :actorId
                            WHERE id = :drawId
                              AND status = 0
                              AND is_deleted = FALSE
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("drawId", drawId)
                    .executeUpdate();
        }
        em.createNativeQuery("""
                        UPDATE plan_draw_links
                        SET is_deleted = TRUE,
                            deleted_at = now()
                        WHERE draw_id IN (:drawIds)
                          AND is_deleted = FALSE
                        """)
                .setParameter("drawIds", drawIds)
                .executeUpdate();
        em.createNativeQuery("""
                        DELETE FROM
                            production_planning_package_documents
                        WHERE package_id = :packageId
                          AND execution_segment_id = :segmentId
                          AND document_type = 'DRAW'
                          AND document_id IN (:drawIds)
                        """)
                .setParameter("packageId", packageId)
                .setParameter("segmentId", segmentId)
                .setParameter("drawIds", drawIds)
                .executeUpdate();
        ledger.refreshDemandStatuses(demandIds);
    }

    /**
     * Acquires the canonical material-dimension locks before the segment row
     * lock used by a manual defer release. This preserves the same ordering as
     * receipt-driven promotion and avoids an inventory-dimension/segment cycle.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID lockManualReleaseDimensions(
            UUID planId,
            UUID segmentId) {
        List<UUID> warehouses = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT package.warehouse_id
                                FROM production_execution_segments segment
                                JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                 AND package.execution_model_version = 1
                                 AND package.is_deleted = FALSE
                                WHERE segment.id = :segmentId
                                  AND segment.plan_id = :planId
                                  AND segment.is_deleted = FALSE
                                """)
                        .setParameter("segmentId", segmentId)
                        .setParameter("planId", planId),
                UUID.class);
        if (warehouses.isEmpty() || warehouses.getFirst() == null) {
            return null;
        }
        UUID warehouseId = warehouses.getFirst();
        lockExecutionSegmentMaterialDimensions(segmentId, warehouseId);
        return warehouseId;
    }

    /**
     * Re-evaluates a just-released USER_DEFER segment. Already approved,
     * provenance-matching receipts may satisfy open pegs; otherwise the segment
     * remains WAITING with automatic receipt-driven promotion enabled.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void promoteAfterManualRelease(
            UUID segmentId,
            UUID warehouseId) {
        if (segmentId == null || warehouseId == null) {
            return;
        }
        tryPromote(segmentId, segmentId, warehouseId, null);
    }

    private void tryPromote(
            UUID segmentId,
            UUID triggeringReceiptId,
            UUID expectedWarehouseId,
            ReceiptKind triggeringKind) {
        lockExecutionSegmentMaterialDimensions(
                segmentId, expectedWarehouseId);
        List<Object[]> segmentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT segment.package_id,
                                       segment.plan_id,
                                       plan.bill_no,
                                       package.warehouse_id,
                                       segment.status
                                FROM production_execution_segments segment
                                JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                 AND package.status = 'CONFIRMED'
                                 AND package.execution_model_version = 1
                                 AND package.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = segment.plan_id
                                WHERE segment.id = :segmentId
                                  AND segment.auto_promote_when_ready = TRUE
                                  AND segment.is_deleted = FALSE
                                FOR UPDATE OF segment, package
                                """)
                        .setParameter("segmentId", segmentId));
        if (segmentRows.isEmpty()
                || !ProductionExecutionSegment.STATUS_WAITING.equals(
                        segmentRows.getFirst()[4])) {
            return;
        }
        Object[] segmentRow = segmentRows.getFirst();
        UUID packageId = uuid(segmentRow[0]);
        UUID planId = uuid(segmentRow[1]);
        String planNo = (String) segmentRow[2];
        UUID warehouseId = uuid(segmentRow[3]);
        if (!warehouseId.equals(expectedWarehouseId)) {
            return;
        }

        List<DemandRow> demands = NativeQueryResults.objectArrayRows(
                        em.createNativeQuery("""
                                        SELECT id, goods_id, color_id,
                                               unit_id, required_qty
                                        FROM production_material_demands
                                        WHERE execution_segment_id = :segmentId
                                          AND is_deleted = FALSE
                                          AND status NOT IN (
                                              'RELEASED', 'REVERSED')
                                        ORDER BY goods_id,
                                                 color_id NULLS FIRST, id
                                        FOR UPDATE
                                        """)
                                .setParameter("segmentId", segmentId))
                .stream()
                .map(row -> new DemandRow(
                        uuid(row[0]), uuid(row[1]), uuid(row[2]),
                        uuid(row[3]), decimal(row[4])))
                .toList();
        if (demands.isEmpty()) {
            throw conflict("执行分段没有物料需求");
        }

        if (!isFullyAvailable(warehouseId, demands)) {
            return;
        }

        Map<UUID, List<ReceiptContribution>> contributions =
                receiptContributions(
                        demands,
                        triggeringReceiptId,
                        triggeringKind,
                        warehouseId);
        /*
         * V154 counts an unconsumed supply peg and a physical reservation
         * against the same demand capacity. Only an exact received conversion
         * may replace that future commitment; unrelated stock never silently
         * releases a purchase/subcontract peg.
         */
        if (!contributionsCoverOpenSupply(demands, contributions)) {
            return;
        }
        contributions.values().stream()
                .flatMap(List::stream)
                .forEach(this::updatePegConsumed);

        List<ProductionMaterialAllocationFacade.AllocationResult> allocated =
                stockAllocation.allocate(demands.stream()
                        .map(demand ->
                                new ProductionMaterialAllocationFacade
                                        .AllocationRequest(
                                        packageId,
                                        demand.id(),
                                        demand.goodsId(),
                                        demand.colorId(),
                                        warehouseId,
                                        demand.requiredQty(),
                                        packageId + ":REKIT:" + demand.id()
                                                + ":" + triggeringReceiptId,
                                        currentUser.requireId()))
                        .toList());
        Map<UUID, ProductionMaterialAllocationFacade.AllocationResult>
                allocationByDemand = allocated.stream().collect(
                        java.util.stream.Collectors.toMap(
                                ProductionMaterialAllocationFacade
                                        .AllocationResult::demandId,
                                value -> value));
        if (demands.stream().anyMatch(demand ->
                allocationByDemand.get(demand.id()) == null
                        || allocationByDemand.get(demand.id())
                                .allocatedQty()
                                .compareTo(demand.requiredQty()) != 0)) {
            throw conflict(
                    "齐套判定的可用库存在提升就绪时已变化，请刷新后重试");
        }

        StockDocument draw = createDraw(
                packageId,
                segmentId,
                planId,
                planNo,
                warehouseId);
        int lineNo = 0;
        Set<UUID> touched = new LinkedHashSet<>();
        for (DemandRow demand : demands) {
            BigDecimal receiptQty = BigDecimal.ZERO;
            for (ReceiptContribution contribution :
                    contributions.getOrDefault(
                            demand.id(), List.of())) {
                receiptQty = receiptQty.add(contribution.qty());
                UUID drawItemId = addDrawItem(
                        draw,
                        packageId,
                        demand,
                        contribution.qty(),
                        ++lineNo,
                        planNo,
                        contribution.kind().name()
                                + " receipt " + contribution.receiptId());
                recordReceiptAllocation(
                        contribution,
                        packageId,
                        demand.id(),
                        allocationByDemand.get(
                                demand.id()).allocationId(),
                        draw.getId(),
                        drawItemId);
            }
            BigDecimal genericQty =
                    demand.requiredQty().subtract(receiptQty);
            if (genericQty.signum() > 0) {
                addDrawItem(
                        draw,
                        packageId,
                        demand,
                        genericQty,
                        ++lineNo,
                        planNo,
                        "齐套现有库存");
            }
            touched.add(demand.id());
        }
        if (lineNo == 0) {
            throw conflict("执行分段领料单没有任何物料行");
        }
        stockDocumentItemRepo.flush();
        stockDocumentRepo.flush();

        int promoted = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET status = 'READY',
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE id = :segmentId
                          AND status = 'WAITING'
                          AND auto_promote_when_ready = TRUE
                          AND is_deleted = FALSE
                        """)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("segmentId", segmentId)
                .executeUpdate();
        if (promoted != 1) {
            throw conflict(
                    "提升就绪时执行分段已被并发修改，请刷新后重试");
        }
        ledger.refreshDemandStatuses(touched);
        chainNotice.notifyExecutionSegmentReady(
                segmentId,
                triggeringReceiptId,
                triggeringKind == null
                        ? "MANUAL_RELEASE"
                        : triggeringKind.name());
    }

    private boolean isFullyAvailable(
            UUID warehouseId,
            List<DemandRow> demands) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT d.id,
                                       GREATEST(
                                           COALESCE(balance.qty, 0)
                                           - COALESCE(reserved.qty, 0)
                                           - GREATEST(
                                               COALESCE(goods.min_qty, 0), 0),
                                           0
                                       ) AS available_qty
                                FROM production_material_demands d
                                JOIN goods
                                  ON goods.id = d.goods_id
                                LEFT JOIN stock_balances balance
                                  ON balance.goods_id = d.goods_id
                                 AND balance.color_id IS NOT DISTINCT
                                     FROM d.color_id
                                 AND balance.warehouse_id = :warehouseId
                                LEFT JOIN LATERAL (
                                    SELECT SUM(
                                        reservation.qty
                                        - reservation.consumed_qty
                                        - reservation.released_qty
                                    ) AS qty
                                    FROM stock_reservations reservation
                                    WHERE reservation.goods_id = d.goods_id
                                      AND reservation.color_id
                                          IS NOT DISTINCT FROM d.color_id
                                      AND (
                                          reservation.warehouse_id IS NULL
                                          OR reservation.warehouse_id =
                                             :warehouseId
                                      )
                                      AND reservation.status = :effective
                                      AND reservation.is_deleted = FALSE
                                ) reserved ON TRUE
                                WHERE d.id IN (:demandIds)
                                ORDER BY d.goods_id,
                                         d.color_id NULLS FIRST, d.id
                                """)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("effective", RESERVATION_EFFECTIVE)
                        .setParameter(
                                "demandIds",
                                demands.stream()
                                        .map(DemandRow::id)
                                        .toList()));
        Map<UUID, BigDecimal> available = new HashMap<>();
        rows.forEach(row -> available.put(
                uuid(row[0]), decimal(row[1])));
        return demands.stream().allMatch(demand ->
                available.getOrDefault(
                                demand.id(), BigDecimal.ZERO)
                        .compareTo(demand.requiredQty()) >= 0);
    }

    private void lockExecutionSegmentMaterialDimensions(
            UUID segmentId,
            UUID warehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT DISTINCT goods_id, color_id
                                FROM production_material_demands
                                WHERE execution_segment_id = :segmentId
                                  AND warehouse_id = :warehouseId
                                  AND is_deleted = FALSE
                                  AND status NOT IN (
                                      'RELEASED', 'REVERSED')
                                ORDER BY goods_id, color_id NULLS FIRST
                                """)
                        .setParameter("segmentId", segmentId)
                        .setParameter("warehouseId", warehouseId));
        stockAllocation.lockMaterialDimensions(rows.stream()
                .map(row -> new ProductionMaterialAllocationFacade
                        .MaterialDimension(
                        uuid(row[0]), uuid(row[1])))
                .toList());
    }

    private Map<UUID, List<ReceiptContribution>> receiptContributions(
            List<DemandRow> demands,
            UUID triggeringReceiptId,
            ReceiptKind triggeringKind,
            UUID warehouseId) {
        Map<UUID, List<ReceiptContribution>> result =
                new LinkedHashMap<>();
        for (DemandRow demand : demands) {
            BigDecimal remaining = demand.requiredQty();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT receipt.id,
                                           receipt_item.id,
                                           peg.id,
                                           LEAST(
                                               peg.allocated_qty
                                                   - peg.consumed_qty
                                                   - peg.released_qty,
                                               receipt_item.qty
                                                   * COALESCE(
                                                       receipt_item.unit_rate,
                                                       1)
                                                   - COALESCE((
                                                       SELECT SUM(
                                                           allocation
                                                               .allocated_qty)
                                                       FROM
                                                         production_material_receipt_allocations
                                                           allocation
                                                       WHERE allocation
                                                               .receipt_item_id
                                                             = receipt_item.id
                                                         AND allocation.status
                                                             = 'EFFECTIVE'
                                                   ), 0)
                                           ) AS available_qty,
                                           peg.allocated_qty
                                               - peg.consumed_qty
                                               - peg.released_qty
                                               AS peg_available_qty,
                                           'PURCHASE'::text AS receipt_kind,
                                           receipt.bill_date
                                    FROM production_material_supply_pegs peg
                                    JOIN purchase_receipt_items receipt_item
                                      ON receipt_item.order_item_id =
                                         peg.supply_item_id
                                     AND receipt_item.is_deleted = FALSE
                                    JOIN purchase_receipts receipt
                                      ON receipt.id =
                                         receipt_item.receipt_id
                                     AND receipt.is_deleted = FALSE
                                     AND receipt.warehouse_id = :warehouseId
                                    WHERE peg.demand_id = :demandId
                                      AND peg.supply_type =
                                          'PURCHASE_ORDER_ITEM'
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                      AND (
                                          receipt.status = 1
                                          OR receipt.id = :triggeringReceiptId
                                      )
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg, receipt_item, receipt
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id())
                            .setParameter(
                                    "triggeringReceiptId",
                                    triggeringKind == ReceiptKind.PURCHASE
                                            ? triggeringReceiptId
                                            : new UUID(0L, 0L)));
            List<ReceiptContribution> values = new ArrayList<>();
            rows.addAll(NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT receipt.id,
                                           receipt_item.id,
                                           peg.id,
                                           LEAST(
                                               peg.allocated_qty
                                                   - peg.consumed_qty
                                                   - peg.released_qty,
                                               receipt_item.qty
                                                   * COALESCE(
                                                       receipt_item.unit_rate,
                                                       1)
                                                   - COALESCE((
                                                       SELECT SUM(
                                                           allocation
                                                               .allocated_qty)
                                                       FROM
                                                         production_material_subcontract_receipt_allocations
                                                           allocation
                                                       WHERE allocation
                                                               .receipt_item_id
                                                             = receipt_item.id
                                                         AND allocation.status
                                                             = 'EFFECTIVE'
                                                   ), 0)
                                           ) AS available_qty,
                                           peg.allocated_qty
                                               - peg.consumed_qty
                                               - peg.released_qty
                                               AS peg_available_qty,
                                           'SUBCONTRACT'::text AS receipt_kind,
                                           receipt.bill_date
                                    FROM production_material_supply_pegs peg
                                    JOIN subcontract_receipt_items receipt_item
                                      ON receipt_item.order_item_id =
                                         peg.supply_item_id
                                     AND receipt_item.is_deleted = FALSE
                                    JOIN subcontract_receipts receipt
                                      ON receipt.id =
                                         receipt_item.receipt_id
                                     AND receipt.is_deleted = FALSE
                                     AND receipt.warehouse_id = :warehouseId
                                    WHERE peg.demand_id = :demandId
                                      AND peg.supply_type =
                                          'SUBCONTRACT_ORDER_ITEM'
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                      AND (
                                          receipt.status = 1
                                          OR receipt.id = :triggeringReceiptId
                                      )
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg, receipt_item, receipt
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id())
                            .setParameter(
                                    "triggeringReceiptId",
                                    triggeringKind == ReceiptKind.SUBCONTRACT
                                            ? triggeringReceiptId
                                            : new UUID(0L, 0L))));
            rows.addAll(NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT receipt.id,
                                           receipt_item.id,
                                           peg.id,
                                           LEAST(
                                               peg.allocated_qty
                                                   - peg.consumed_qty
                                                   - peg.released_qty,
                                               COALESCE(
                                                   receipt_item.base_qty,
                                                   receipt_item.qty
                                                       * COALESCE(
                                                           receipt_item.unit_rate,
                                                           1))
                                                   - COALESCE((
                                                       SELECT SUM(
                                                           allocation
                                                               .allocated_qty)
                                                       FROM
                                                         production_material_make_receipt_allocations
                                                           allocation
                                                       WHERE allocation
                                                               .receipt_item_id
                                                             = receipt_item.id
                                                         AND allocation.status
                                                             = 'EFFECTIVE'
                                                   ), 0)
                                           ) AS available_qty,
                                           peg.allocated_qty
                                               - peg.consumed_qty
                                               - peg.released_qty
                                               AS peg_available_qty,
                                           'MAKE'::text AS receipt_kind,
                                           receipt.bill_date
                                    FROM production_material_supply_pegs peg
                                    JOIN stock_document_items receipt_item
                                      ON receipt_item.upstream_item_id =
                                         peg.supply_item_id
                                     AND receipt_item.bill_type =
                                         'FINISHED_IN'
                                     AND receipt_item.is_deleted = FALSE
                                    JOIN stock_documents receipt
                                      ON receipt.id = receipt_item.doc_id
                                     AND receipt.doc_type = 'FINISHED_IN'
                                     AND receipt.is_deleted = FALSE
                                     AND receipt.warehouse_id = :warehouseId
                                    WHERE peg.demand_id = :demandId
                                      AND peg.supply_type =
                                          'PRODUCTION_PLAN_ITEM'
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                      AND receipt_item.goods_id = :goodsId
                                      AND receipt_item.color_id IS NOT DISTINCT
                                          FROM :colorId
                                      AND receipt_item.unit_id = :unitId
                                      AND (
                                          receipt.status = 1
                                          OR receipt.id = :triggeringReceiptId
                                      )
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg, receipt_item, receipt
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id())
                            .setParameter("goodsId", demand.goodsId())
                            .setParameter("colorId", demand.colorId())
                            .setParameter("unitId", demand.unitId())
                            .setParameter(
                                    "triggeringReceiptId",
                                    triggeringKind == ReceiptKind.MAKE
                                            ? triggeringReceiptId
                                            : new UUID(0L, 0L))));
            rows.sort(Comparator
                    .comparing(
                            (Object[] row) -> localDate(row[6]),
                            Comparator.nullsLast(
                                    Comparator.naturalOrder()))
                    .thenComparing(row -> uuid(row[0]))
                    .thenComparing(row -> uuid(row[1])));
            Map<UUID, BigDecimal> pegRemaining = new HashMap<>();
            for (Object[] row : rows) {
                if (remaining.signum() <= 0) break;
                UUID pegId = uuid(row[2]);
                BigDecimal pegAvailable =
                        pegRemaining.computeIfAbsent(
                                pegId,
                                ignored -> decimal(row[4])
                                        .max(BigDecimal.ZERO));
                BigDecimal available = decimal(row[3])
                        .max(BigDecimal.ZERO)
                        .min(pegAvailable);
                BigDecimal qty = available.min(remaining);
                if (qty.signum() <= 0) continue;
                values.add(new ReceiptContribution(
                        uuid(row[0]), uuid(row[1]),
                        pegId,
                        qty,
                        ReceiptKind.valueOf((String) row[5])));
                remaining = remaining.subtract(qty);
                pegRemaining.put(
                        pegId, pegAvailable.subtract(qty));
            }
            result.put(demand.id(), List.copyOf(values));
        }
        return result;
    }

    private boolean contributionsCoverOpenSupply(
            List<DemandRow> demands,
            Map<UUID, List<ReceiptContribution>> contributions) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT demand.id,
                                       COALESCE(SUM(
                                           peg.allocated_qty
                                           - peg.consumed_qty
                                           - peg.released_qty
                                       ) FILTER (
                                           WHERE peg.status <> 'REVERSED'
                                       ), 0)
                                FROM production_material_demands demand
                                LEFT JOIN production_material_supply_pegs peg
                                  ON peg.demand_id = demand.id
                                WHERE demand.id IN (:demandIds)
                                GROUP BY demand.id
                                """)
                .setParameter(
                        "demandIds",
                        demands.stream().map(DemandRow::id).toList()));
        Map<UUID, BigDecimal> openByDemand = new HashMap<>();
        rows.forEach(row -> openByDemand.put(
                uuid(row[0]), decimal(row[1])));
        return demands.stream().allMatch(demand -> {
            BigDecimal received = contributions
                    .getOrDefault(demand.id(), List.of())
                    .stream()
                    .map(ReceiptContribution::qty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            return received.compareTo(
                    openByDemand.getOrDefault(
                            demand.id(), BigDecimal.ZERO)) == 0;
        });
    }

    private StockDocument createDraw(
            UUID packageId,
            UUID segmentId,
            UUID planId,
            String planNo,
            UUID warehouseId) {
        StockDocument document = new StockDocument();
        document.setDocType("DRAW");
        document.setBillNo(
                docNumberService.nextNumber(
                        DocNumberPrefix.STOCK_DRAW));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(warehouseId);
        document.setPlanNo(planNo);
        document.setSourceDocNo(planNo);
        document.setRemark(
                "执行分段齐套就绪自动备料 "
                        + segmentId);
        document.setWorkerId(currentUser.requireEmployeeId());
        document.setMakerId(currentUser.requireEmployeeId());
        document.setStatus((short) 0);
        stockDocumentRepo.saveAndFlush(document);
        ledger.recordDocument(
                packageId,
                segmentId,
                "DRAW",
                document.getId(),
                document.getBillNo(),
                currentUser.requireId());
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(
                            plan_id, draw_id, created_by)
                        VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", planId)
                .setParameter("drawId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return document;
    }

    private UUID addDrawItem(
            StockDocument draw,
            UUID packageId,
            DemandRow demand,
            BigDecimal qty,
            int lineNo,
            String planNo,
            String remark) {
        StockDocumentItem item = new StockDocumentItem();
        item.setDocId(draw.getId());
        item.setBillType("DRAW");
        item.setBillNo(draw.getBillNo());
        item.setBillDate(draw.getBillDate());
        item.setLineNo(lineNo);
        item.setGoodsId(demand.goodsId());
        item.setColorId(demand.colorId());
        item.setUnitId(demand.unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(qty);
        item.setBaseQty(qty);
        item.setSourceDocNo(planNo);
        item.setRemark(remark);
        stockDocumentItemRepo.saveAndFlush(item);
        em.createNativeQuery("""
                        INSERT INTO
                            production_planning_package_document_items (
                                package_id, demand_id, document_type,
                                document_id, document_item_id, created_by)
                        VALUES (
                            :packageId, :demandId, 'DRAW',
                            :drawId, :itemId, :actorId)
                        """)
                .setParameter("packageId", packageId)
                .setParameter("demandId", demand.id())
                .setParameter("drawId", draw.getId())
                .setParameter("itemId", item.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return item.getId();
    }

    private void updatePegConsumed(
            ReceiptContribution contribution) {
        int updated = em.createNativeQuery("""
                        UPDATE production_material_supply_pegs
                        SET consumed_qty =
                                consumed_qty + :qty,
                            status = CASE
                                WHEN consumed_qty + released_qty
                                     + :qty = allocated_qty
                                THEN 'DONE'
                                ELSE 'EFFECTIVE'
                            END,
                            lock_version = lock_version + 1,
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE id = :pegId
                          AND allocated_qty - consumed_qty
                              - released_qty >= :qty
                        """)
                .setParameter("qty", contribution.qty())
                .setParameter("actorId", currentUser.requireId())
                .setParameter("pegId", contribution.pegId())
                .executeUpdate();
        if (updated != 1) {
            throw conflict("收货供给锚点已被并发修改，请刷新后重试");
        }
    }

    private void recordReceiptAllocation(
            ReceiptContribution contribution,
            UUID packageId,
            UUID demandId,
            UUID reservationId,
            UUID drawId,
            UUID drawItemId) {
        String table = allocationTable(contribution.kind());
        String pegColumn = allocationPegColumn(contribution.kind());
        em.createNativeQuery("""
                        INSERT INTO
                            %s (
                                receipt_id, receipt_item_id, package_id,
                                demand_id, %s, reservation_id,
                                draw_id, draw_item_id, allocated_qty,
                                status, idempotency_key,
                                created_at, updated_at,
                                created_by, updated_by)
                        VALUES (
                            :receiptId, :receiptItemId, :packageId,
                            :demandId, :pegId, :reservationId,
                            :drawId, :drawItemId, :qty,
                            'EFFECTIVE', :key,
                            now(), now(), :actorId, :actorId)
                        """.formatted(table, pegColumn))
                .setParameter(
                        "receiptId", contribution.receiptId())
                .setParameter(
                        "receiptItemId",
                        contribution.receiptItemId())
                .setParameter("packageId", packageId)
                .setParameter("demandId", demandId)
                .setParameter("pegId", contribution.pegId())
                .setParameter("reservationId", reservationId)
                .setParameter("drawId", drawId)
                .setParameter("drawItemId", drawItemId)
                .setParameter("qty", contribution.qty())
                .setParameter(
                        "key",
                        allocationKeyPrefix(contribution.kind())
                                + contribution.receiptItemId()
                                + ":"
                                + contribution.pegId()
                                + ":"
                                + reservationId)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }


    private static String allocationTable(ReceiptKind kind) {
        return switch (kind) {
            case PURCHASE ->
                    "production_material_receipt_allocations";
            case SUBCONTRACT ->
                    "production_material_subcontract_receipt_allocations";
            case MAKE ->
                    "production_material_make_receipt_allocations";
        };
    }

    private static String allocationPegColumn(ReceiptKind kind) {
        return kind == ReceiptKind.MAKE
                ? "supply_peg_id"
                : "order_peg_id";
    }

    private static String allocationKeyPrefix(ReceiptKind kind) {
        return switch (kind) {
            case PURCHASE -> "SEG-REKIT:";
            case SUBCONTRACT -> "SEG-SUB-REKIT:";
            case MAKE -> "SEG-MAKE-REKIT:";
        };
    }
    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static java.time.LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof java.time.LocalDate date) return date;
        if (value instanceof java.sql.Date date) {
            return date.toLocalDate();
        }
        throw conflict("收货日期类型无效");
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        if (value instanceof UUID uuid) return uuid;
        return UUID.fromString(value.toString());
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record DemandRow(
            UUID id,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requiredQty) {
    }

    private record ReceiptContribution(
            UUID receiptId,
            UUID receiptItemId,
            UUID pegId,
            BigDecimal qty,
            ReceiptKind kind) {
    }

    private record ReceiptAllocationRow(
            ReceiptKind kind,
            UUID id,
            UUID pegId,
            BigDecimal qty,
            UUID drawId) {
    }

    private enum ReceiptKind {
        PURCHASE,
        SUBCONTRACT,
        MAKE
    }
}
