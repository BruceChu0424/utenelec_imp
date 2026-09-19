package com.uten.imp.features.production.fulfillment;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.features.production.analysis.PreplanOriginEntitlementHook;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.core.annotation.Order;
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
@Order(100)
@Service
@RequiredArgsConstructor
public class ProductionExecutionReadinessService
        implements PreplanOriginEntitlementHook {

    private static final short RESERVATION_EFFECTIVE = 0;
    private final PreplanAnalysisPegPort preplanAnalysisPeg;

    private final EntityManager em;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionFulfillmentLedgerService ledger;
    private final StockDocumentRepository stockDocumentRepo;
    private final StockDocumentItemRepository stockDocumentItemRepo;
    /**
     * 延迟解析打破环：StockDocService → ProductionCompletionReverseService → 本服务。
     * 只在用户触发的齐套提升后取用（issueLineSideDrawsAfterPromotion）。
     */
    private final org.springframework.beans.factory.ObjectProvider<StockDocService> stockDocs;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ChainNoticeService chainNotice;
    /** Re-evaluate affected WAITING segments after Cross priority has settled. */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyPriorityForOriginEvent(UUID originEventId) {
        List<Object[]> segments = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT segment.id, package.warehouse_id
                        FROM preplan_stock_entitlement_events origin
                        JOIN stock_reservations source_reservation
                          ON source_reservation.id = origin.stock_reservation_id
                        JOIN v_preplan_stock_entitlement_beneficiary_balance balance
                          ON balance.stock_reservation_id = origin.stock_reservation_id
                         AND balance.effective_qty > 0
                        JOIN production_plans plan
                          ON plan.material_analysis_id = balance.beneficiary_analysis_id
                         AND fn_analysis_plan_material_matches(
                             plan.material_analysis_item_id,
                             balance.beneficiary_analysis_material_id)
                         AND plan.is_deleted = FALSE
                        JOIN production_planning_packages package
                          ON package.plan_id = plan.id
                         AND (fn_warehouse_same_main(package.warehouse_id, source_reservation.warehouse_id)
                              OR fn_preplan_reservation_has_qualified_origin(source_reservation.id))
                         AND package.status = 'CONFIRMED'
                         AND package.execution_model_version = 1
                         AND package.is_deleted = FALSE
                        JOIN production_execution_segments segment
                          ON segment.package_id = package.id
                         AND segment.plan_id = plan.id
                         AND segment.status = 'WAITING'
                         AND segment.auto_promote_when_ready = TRUE
                         AND segment.is_deleted = FALSE
                        JOIN production_material_demands demand
                          ON demand.execution_segment_id = segment.id
                         AND demand.goods_id = source_reservation.goods_id
                         AND demand.color_id IS NOT DISTINCT FROM source_reservation.color_id
                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                         AND demand.is_deleted = FALSE
                        WHERE origin.id = :originEventId
                          AND origin.event_type IN ('ORIGIN_IQC', 'ORIGIN_MAKE')
                        ORDER BY segment.id
                        """).setParameter("originEventId", originEventId));
        for (Object[] row : segments) {
            tryPromote(
                    uuid(row[0]), originEventId, uuid(row[1]),
                    ReceiptKind.PREPLAN);
        }
    }


    @Transactional(propagation = Propagation.MANDATORY)
    public void onPurchaseReceiptApproved(
            UUID triggeringReceiptId,
            UUID warehouseId) {
        List<UUID> segmentIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT d.execution_segment_id
                        FROM purchase_receipt_items receipt_item
                        JOIN purchase_receipts receipt
                          ON receipt.id = receipt_item.receipt_id
                         AND receipt.status = 1
                         AND receipt.is_deleted = FALSE
                         AND fn_procurement_received_in_warehouse('PURCHASE',receipt_item.id,:warehouseId)>0
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
                        JOIN subcontract_receipts receipt
                          ON receipt.id = receipt_item.receipt_id
                         AND receipt.status = 1
                         AND receipt.is_deleted = FALSE
                         AND fn_procurement_received_in_warehouse('SUBCONTRACT',receipt_item.id,:warehouseId)>0
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

    /**
     * 成品入库变更前锁定相关物料维度：除入库明细本身外，一并锁定其喂给的可自动提升执行段的需求维度，
     * 使就绪提升不会与并发库存变动相互覆盖。
     */
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
                                 AND receipt.status = 1
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
        List<Object[]> candidates = NativeQueryResults.objectArrayRows(
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
                                """)
                        .setParameter("segmentId", segmentId));
        if (candidates.size() != 1
                || !ProductionExecutionSegment.STATUS_READY.equals(
                        candidates.getFirst()[1])) {
            throw conflict(
                    "收货关联的执行分段已不是未开工的「就绪」状态");
        }
        UUID packageId = uuid(candidates.getFirst()[0]);
        List<?> packageLock = em.createNativeQuery("""
                        SELECT id
                        FROM production_planning_packages
                        WHERE id = :packageId
                          AND status = 'CONFIRMED'
                          AND execution_model_version = 1
                          AND is_deleted = FALSE
                        FOR UPDATE
                        """)
                .setParameter("packageId", packageId)
                .getResultList();
        List<Object[]> segmentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT package_id, status
                                FROM production_execution_segments
                                WHERE id = :segmentId
                                  AND package_id = :packageId
                                  AND is_deleted = FALSE
                                FOR UPDATE
                                """)
                        .setParameter("segmentId", segmentId)
                        .setParameter("packageId", packageId));
        if (packageLock.size() != 1
                || segmentRows.size() != 1
                || !ProductionExecutionSegment.STATUS_READY.equals(
                        segmentRows.getFirst()[1])) {
            throw conflict(
                    "收货关联的执行分段已被并发修改或不再就绪");
        }
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
        preplanAnalysisPeg.restorePlanDemandTransfers(
                reservations.stream().map(row -> uuid(row[0])).toList(),
                "RECEIPT_SEGMENT_DEMOTED");


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

    @Transactional(propagation = Propagation.MANDATORY)
    public void promoteAfterMaterialRecheck(UUID segmentId, UUID warehouseId) {
        tryPromote(segmentId, segmentId, warehouseId, ReceiptKind.RECHECK);
    }

    /**
     * 「其它入库」到货即提升（V606 / ADR-091 批注）：开工路线确认步骤删除后，
     * 齐套路线不再有确认动作可挂「同事务补跑提升」——仓库一审核其它入库，就对本仓
     * 等待中、路线放行自动提升的段**尽力而为**补跑一次：物料没到齐静默留在 WAITING
     * 等既有到货链路；已可齐套则与旧「到货即提升」完全一致（整批预留、建领料单、
     * 升 READY、线边仓草稿就地出库）。路线门 {@code fn_execution_route_allows_auto_promote}
     * 在 {@code tryPromote} 的段锁查询里复核，分批/未开工持续生产不被顶掉。
     * 缺料要抛错解释的是人工重核路径，不是这里。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void onOtherInboundApproved(UUID stockDocumentId, UUID warehouseId) {
        if (stockDocumentId == null || warehouseId == null) {
            return;
        }
        List<Object[]> candidates = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT DISTINCT segment.id, package.warehouse_id
                        FROM stock_document_items item
                        JOIN production_material_demands demand
                          ON demand.goods_id = item.goods_id
                         AND demand.color_id IS NOT DISTINCT FROM item.color_id
                         AND demand.execution_segment_id IS NOT NULL
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        JOIN production_execution_segments segment
                          ON segment.id = demand.execution_segment_id
                         AND segment.status = 'WAITING'
                         AND segment.auto_promote_when_ready = TRUE
                         AND segment.is_deleted = FALSE
                        JOIN production_planning_packages package
                          ON package.id = segment.package_id
                         AND package.status = 'CONFIRMED'
                         AND package.is_deleted = FALSE
                        WHERE item.doc_id = :docId
                          AND item.is_deleted = FALSE
                        ORDER BY segment.id
                        """)
                .setParameter("docId", stockDocumentId));
        for (Object[] candidate : candidates) {
            // tryPromote 以「包仓库 == expectedWarehouseId」为放行前提；入库叶仓与发料仓
            // 可以不同（同主仓跨叶由齐套判定的合格来源口径处理），这里传段的包仓库。
            tryPromote(uuid(candidate[0]), stockDocumentId, uuid(candidate[1]),
                    ReceiptKind.RECHECK, null, true, false);
        }
    }

    /**
     * 「确认生产路线 = 齐套生产」的就地补跑提升(V599 / ADR-091)：确认前齐套自动提升被
     * 路线门 {@code fn_execution_route_allows_auto_promote} 抑制，确认的那一刻补跑一次——
     * **尽力而为**：物料还没到齐就静默留在 WAITING 等既有到货链路；已可齐套则与旧的
     * 「到货即提升」完全一致(整批预留、建领料单、升 READY、线边仓草稿就地出库)。
     * 缺料原因要抛错解释的是 {@link #promoteAfterMaterialRecheck} 那条人工重核路径，不是这里。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void promoteAfterRouteConfirmation(UUID segmentId, UUID warehouseId) {
        if (segmentId == null || warehouseId == null) {
            return;
        }
        tryPromote(segmentId, segmentId, warehouseId, ReceiptKind.RECHECK, null, true, false);
    }

    /**
     * 车间内部直送后的齐套重算(V584/ADR-087)：**尽力而为**——上层工单还缺别的料、
     * 或采购/委外供给未完成来源入库时都静默返回，料留在线边仓等既有就绪补偿，
     * 绝不把「上层没齐套」抛成报工审核的失败。缺料原因要抛错解释的是
     * {@link #promoteAfterMaterialRecheck} 那条人工重核路径，不是这里。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void promoteAfterWorkshopDirectTransfer(UUID segmentId, UUID warehouseId) {
        tryPromote(segmentId, segmentId, warehouseId, ReceiptKind.RECHECK, null, true, false);
    }

    /**
     * 「部分开工 · 持续生产」的齐套提升(V595 / ADR-089)：只对**仓库供给**的需求做齐套判定与
     * 整批预留(缺料时抛错解释缺什么)；同车间直送供给的需求(direct_supply)不参与齐套——
     * 线边仓里已经到了多少就先投多少，后面每一笔直送再补投。成功后段进 READY，线边仓领料单
     * 同事务出库；仓库部分照旧走车间领料申请与仓库发料。
     *
     * <p>调用方已把 continuous_supply / direct_supply 两个标记落库并持有段行锁。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void promoteContinuousSupply(UUID segmentId, UUID warehouseId) {
        tryPromote(segmentId, segmentId, warehouseId, ReceiptKind.RECHECK, null, false, true);
    }

    /**
     * 持续生产工单收到一笔同车间直送后的补投(V595)：料刚落进本车间线边仓，按那条直送需求的
     * 剩余量就地预留 → 线边仓领料单 → 同事务出库，上层接着做，不看齐套、不需要任何人点领料。
     * 超出需求剩余量的部分留在线边仓(只对直送指名的需求可见)，等下一批需求。
     *
     * <p>幂等：同一报工行的补投用同一个 {@code idempotencyKey}，预留与出库都按键重放。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void topUpDirectSupply(
            UUID segmentId, UUID demandId, UUID lineSideWarehouseId,
            BigDecimal qty, String idempotencyKey) {
        if (segmentId == null || demandId == null || lineSideWarehouseId == null
                || qty == null || qty.signum() <= 0) {
            return;
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT segment.package_id, segment.plan_id, plan.bill_no,
                               segment.workshop_department_id, segment.responsible_employee_id,
                               segment.status, segment.continuous_supply,
                               demand.goods_id, demand.color_id, demand.unit_id,
                               demand.required_qty, demand.direct_supply,
                               COALESCE((
                                   SELECT SUM(reservation.qty - reservation.released_qty)
                                   FROM stock_reservations reservation
                                   WHERE reservation.demand_id = demand.id
                                     AND reservation.is_deleted = FALSE), 0),
                               plan.material_analysis_id, package.warehouse_id
                        FROM production_execution_segments segment
                        JOIN production_material_demands demand
                          ON demand.id = :demandId
                         AND demand.execution_segment_id = segment.id
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        JOIN production_plans plan ON plan.id = segment.plan_id
                        JOIN production_planning_packages package
                          ON package.id = segment.package_id
                         AND package.status = 'CONFIRMED'
                         AND package.is_deleted = FALSE
                        WHERE segment.id = :segmentId
                          AND segment.is_deleted = FALSE
                        FOR UPDATE OF segment, demand
                        """)
                .setParameter("segmentId", segmentId)
                .setParameter("demandId", demandId));
        if (rows.isEmpty()) return;
        Object[] row = rows.getFirst();
        String status = (String) row[5];
        if (!Boolean.TRUE.equals(row[6]) || !Boolean.TRUE.equals(row[11])
                || !List.of(ProductionExecutionSegment.STATUS_READY,
                        ProductionExecutionSegment.STATUS_DISPATCHED,
                        ProductionExecutionSegment.STATUS_IN_PROGRESS).contains(status)) {
            return;
        }
        DemandRow demand = new DemandRow(
                demandId, uuid(row[7]), uuid(row[8]), uuid(row[9]), decimal(row[10]), true);
        BigDecimal remaining = demand.requiredQty().subtract(decimal(row[12]));
        BigDecimal take = qty.min(remaining);
        if (take.signum() <= 0) return;
        stockAllocation.lockMaterialDimensions(List.of(
                new ProductionMaterialAllocationFacade.MaterialDimension(
                        demand.goodsId(), demand.colorId())));
        PromotionActor actor = new PromotionActor(
                currentUser.requireId(), currentUser.requireEmployeeId());
        UUID packageId = uuid(row[0]);
        UUID planId = uuid(row[1]);
        String planNo = (String) row[2];
        List<ProductionMaterialAllocationFacade.AllocationResult> allocated =
                allocateDirectSupplyWithinLeaf(
                        packageId, uuid(row[14]), planId, uuid(row[13]), demand,
                        lineSideWarehouseId, take,
                        packageId + ":TOPUP:" + demandId + ":" + idempotencyKey, actor.userId());
        List<ProductionMaterialAllocationFacade.AllocationResult> fresh = allocated.stream()
                .filter(allocation -> !allocation.replayed() && allocation.allocatedQty().signum() > 0)
                .toList();
        if (!fresh.isEmpty()) {
            StockDocument draw = createDraw(
                    packageId, segmentId, planId, planNo,
                    lineSideWarehouseId, uuid(row[3]), uuid(row[4]), actor);
            Map<UUID, StockGoodsSnapshot> goodsSnapshots = StockGoodsSnapshot.fromMaster(
                    em, List.of(demand.goodsId()), StockGoodsSnapshot.MASTER_AT_SAVE);
            int lineNumber = 0;
            for (ProductionMaterialAllocationFacade.AllocationResult allocation : fresh) {
                addDrawItem(draw, packageId, demand, allocation.allocatedQty(), ++lineNumber, planNo,
                        "车间直送 · 持续生产补投",
                        StockGoodsSnapshot.require(goodsSnapshots, demand.goodsId(), "直送补投领料明细"),
                        actor.userId());
            }
            stockDocumentItemRepo.flush();
            stockDocumentRepo.flush();
            ledger.refreshDemandStatuses(List.of(demandId));
        } else if (allocated.stream().noneMatch(ProductionMaterialAllocationFacade.AllocationResult::replayed)) {
            return;
        }
        stockDocs.getObject().issueWorkshopDirectTransferDraws(
                segmentId, lineSideWarehouseId, idempotencyKey);
    }

    /**
     * 在一个线边仓里为一条直送需求就地预留(V595)。直送产出一入线边仓就被收料计划的分析备料
     * 权益预留(ORIGIN_MAKE)，不先把该线边仓里的权益批次转成需求预留，它就永远「没有可用量」；
     * 转完再取该线边仓里剩余的无主料，绝不外溢到同主仓其它叶仓。无分析来源的计划(手工计划)
     * 直接取线边仓里指名给它的料。返回本次的全部分配结果(含幂等重放的)。
     */
    private List<ProductionMaterialAllocationFacade.AllocationResult> allocateDirectSupplyWithinLeaf(
            UUID packageId, UUID packageWarehouseId, UUID planId, UUID analysisId, DemandRow demand,
            UUID lineSideWarehouseId, BigDecimal qty, String idempotencyKey, UUID actorId) {
        List<PreplanAnalysisPegPort.PreparedPlanTransfer> prepared = analysisId == null
                ? List.of()
                : preplanAnalysisPeg.transferToPlanDemandsWithinWarehouse(
                        analysisId, planId, lineSideWarehouseId,
                        List.of(new PreplanAnalysisPegPort.DemandSlice(
                                demand.id(), demand.goodsId(), demand.colorId(), qty)));
        List<ProductionMaterialAllocationFacade.AllocationResult> allocated =
                stockAllocation.allocateWithinLeaf(
                        new ProductionMaterialAllocationFacade.AllocationRequest(
                                packageId, demand.id(), demand.goodsId(), demand.colorId(),
                                packageWarehouseId, qty, idempotencyKey, actorId),
                        lineSideWarehouseId,
                        prepared.stream().map(value ->
                                new ProductionMaterialAllocationFacade.QualifiedSourcePreference(
                                        value.demandId(), value.warehouseId(), value.qty(),
                                        value.sourceEntitlementEventId(), value.sourceStockReservationId()))
                                .toList());
        preplanAnalysisPeg.formalizePlanDemandTransfersForCommand(packageId, prepared, allocated.stream()
                .filter(allocation -> allocation.allocationId() != null)
                .map(allocation -> new PreplanAnalysisPegPort.FormalReservationSlice(
                        allocation.demandId(), allocation.allocationId(), allocation.allocatedQty()))
                .toList(), idempotencyKey);
        return allocated;
    }

    /**
     * 本段在本次用户动作里是否可能出库线边仓领料单(V595)：本车间有与包仓同主仓的线边仓，且那里
     * 有本段未出完的领料单，或有指名给本段需求的余料。线边仓出库走仓库单据的审核/出库链，必须在
     * 履约足迹的完整预锁集合之内——调用方据此在进入任何库存锁之前先按计划预锁
     * ({@code ProductionPlanMutationFootprintService.beginPlan})，否则会撞
     * 「已进入库存锁阶段，不能再补商业来源前缀」。只读，不取锁。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean mayIssueLineSideDraws(UUID segmentId) {
        if (segmentId == null) return false;
        return Boolean.TRUE.equals(em.createNativeQuery("""
                        SELECT EXISTS (
                            SELECT 1
                            FROM production_execution_segments segment
                            JOIN production_planning_packages package ON package.id = segment.package_id
                            JOIN warehouses line_side
                              ON line_side.is_line_side
                             AND line_side.is_deleted = FALSE
                             AND line_side.workshop_department_id = segment.workshop_department_id
                             AND fn_warehouse_same_main(line_side.id, package.warehouse_id)
                            WHERE segment.id = :segmentId
                              AND segment.is_deleted = FALSE
                              AND (EXISTS (
                                       SELECT 1
                                       FROM production_planning_package_documents mapping
                                       JOIN stock_documents document
                                         ON document.id = mapping.document_id
                                        AND document.doc_type = 'DRAW'
                                        AND document.is_deleted = FALSE
                                        AND document.warehouse_id = line_side.id
                                       JOIN stock_document_items item
                                         ON item.doc_id = document.id
                                        AND item.is_deleted = FALSE
                                        AND COALESCE(item.issued_qty, 0) < item.qty
                                       WHERE mapping.document_type = 'DRAW'
                                         AND mapping.execution_segment_id = segment.id)
                                   OR EXISTS (
                                       SELECT 1
                                       FROM production_material_demands demand
                                       JOIN stock_balances balance
                                         ON balance.warehouse_id = line_side.id
                                        AND balance.goods_id = demand.goods_id
                                        AND balance.color_id IS NOT DISTINCT FROM demand.color_id
                                        AND balance.qty > 0
                                       WHERE demand.execution_segment_id = segment.id
                                         AND demand.is_deleted = FALSE
                                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                                         AND fn_line_side_stock_targets_demand(line_side.id, demand.id))))
                        """)
                .setParameter("segmentId", segmentId)
                .getSingleResult());
    }

    private void tryPromote(
            UUID segmentId,
            UUID triggeringReceiptId,
            UUID expectedWarehouseId,
            ReceiptKind triggeringKind) {
        tryPromote(segmentId, triggeringReceiptId, expectedWarehouseId, triggeringKind, null);
    }

    /** A distinct internal actor keeps automatic advancement from impersonating a staff member. */
    private record PromotionActor(UUID userId, UUID employeeId) {}

    @Transactional(propagation = Propagation.MANDATORY)
    public void reconcileWaitingSegment(UUID planId, UUID segmentId, UUID warehouseId) {
        if (currentUser.get().isPresent()) {
            throw new IllegalStateException("自动备料补偿不能冒用登录员工身份");
        }
        Number match = (Number) em.createNativeQuery("SELECT count(*) FROM production_execution_segments WHERE id=:segment AND plan_id=:plan AND is_deleted=FALSE")
                .setParameter("segment",segmentId).setParameter("plan",planId).getSingleResult();
        if (match.longValue() != 1) return;
        em.createNativeQuery("SELECT set_config('app.production_readiness_reconcile','v1',true), set_config('app.actor_id','',true), set_config('app.actor_account','系统自动核对备料',true)").getSingleResult();
        tryPromote(segmentId, segmentId, warehouseId, ReceiptKind.RECONCILE, new PromotionActor(null, null));
    }

    private void tryPromote(
            UUID segmentId,
            UUID triggeringReceiptId,
            UUID expectedWarehouseId,
            ReceiptKind triggeringKind,
            PromotionActor systemActor) {
        tryPromote(segmentId, triggeringReceiptId, expectedWarehouseId,
                triggeringKind, systemActor, false, false);
    }

    /**
     * @param tolerateShortage 车间直送路径为 true：缺料与供给未齐都静默返回，
     *                         不把「上层没齐套」抛成报工审核的失败(ADR-087 §2.3)。
     * @param continuous       持续生产(V595)：直送供给的需求不参与齐套，仓库需求缺料时抛错解释。
     */
    private void tryPromote(
            UUID segmentId,
            UUID triggeringReceiptId,
            UUID expectedWarehouseId,
            ReceiptKind triggeringKind,
            PromotionActor systemActor,
            boolean tolerateShortage,
            boolean continuous) {
        lockExecutionSegmentMaterialDimensions(
                segmentId, expectedWarehouseId);
        List<Object[]> segmentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT segment.package_id,
                                       segment.plan_id,
                                       plan.bill_no,
                                       package.warehouse_id,
                                       segment.status,
                                       plan.material_analysis_id,
                                       plan.material_analysis_item_id,
                                       segment.workshop_department_id,
                                       segment.responsible_employee_id,
                                       segment.lock_version
                                FROM production_execution_segments segment
                                JOIN production_planning_packages package
                                  ON package.id = segment.package_id
                                 AND package.status = 'CONFIRMED'
                                 AND package.execution_model_version = 1
                                 AND package.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = segment.plan_id
                                 AND plan.status = 1 AND plan.is_deleted = FALSE
                                 AND COALESCE(plan.is_closed,FALSE) = FALSE
                                 AND COALESCE(plan.is_canceled,FALSE) = FALSE
                                 AND COALESCE(plan.is_stopped,FALSE) = FALSE
                                WHERE segment.id = :segmentId
                                  AND segment.auto_promote_when_ready = TRUE
                                  AND fn_execution_route_allows_auto_promote(segment.id)
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
        UUID analysisId = uuid(segmentRow[5]);
        UUID analysisItemId = uuid(segmentRow[6]);
        UUID warehouseId = uuid(segmentRow[3]);
        UUID workshopDepartmentId = uuid(segmentRow[7]);
        UUID responsibleEmployeeId = uuid(segmentRow[8]);
        if (!warehouseId.equals(expectedWarehouseId)) {
            return;
        }

        List<DemandRow> allDemands = NativeQueryResults.objectArrayRows(
                        em.createNativeQuery("""
                                        SELECT id, goods_id, color_id,
                                               unit_id, required_qty, direct_supply
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
                        uuid(row[3]), decimal(row[4]), Boolean.TRUE.equals(row[5])))
                .toList();
        // 持续生产(V595)：同车间直送供给的需求不参与齐套判定与整批预留，
        // 线边仓里到了多少先投多少；仓库供给的需求照旧整批齐套。
        List<DemandRow> demands = continuous
                ? allDemands.stream().filter(demand -> !demand.directSupply()).toList()
                : allDemands;
        List<DemandRow> directDemands = continuous
                ? allDemands.stream().filter(DemandRow::directSupply).toList()
                : List.of();
        if (continuous && demands.isEmpty()) {
            promoteContinuousWithoutKitDemands(
                    segmentId, packageId, planId, planNo, warehouseId,
                    workshopDepartmentId, responsibleEmployeeId, allDemands, segmentRow);
            return;
        }
        if (demands.isEmpty()) {
            // A continuation with no incremental material still needs the
            // workshop's explicit batch command and prior physical issue proof.
            if (Boolean.TRUE.equals(em.createNativeQuery("""
                    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
                        JOIN production_execution_segment_splits split
                          ON segment.id IN(split.batch_segment_id,split.remaining_segment_id)
                        WHERE segment.id=:id AND segment.source_segment_id=split.source_segment_id
                          AND jsonb_array_length(segment.split_material_snapshot)>0
                          AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(segment.split_material_snapshot) material
                              WHERE (material->>'requiredQty')::numeric<>0))
                    """).setParameter("id",segmentId).getSingleResult())) return;
            throw conflict("执行分段没有物料需求");
        }

        if (!isFullyAvailable(warehouseId, demands, analysisId, analysisItemId,
                continuous || (!tolerateShortage
                        && triggeringKind == ReceiptKind.RECHECK))) {
            return;
        }

        Map<UUID, List<ReceiptContribution>> contributions =
                receiptContributions(
                        demands,
                        triggeringReceiptId,
                        triggeringKind,
                        warehouseId);
        /*
         * counts an unconsumed supply peg and a physical reservation
         * against the same demand capacity. Only an exact received conversion
         * may replace that future commitment; unrelated stock never silently
         * releases a purchase/subcontract peg.
         */
        if (!contributionsCoverOpenSupply(demands, contributions)) {
            if (!tolerateShortage && triggeringKind == ReceiptKind.RECHECK) {
                throw conflict("采购或委外供给尚未完成对应来源入库，仍须等待仓库实际入库");
            }
            return;
        }
        PromotionActor actor = systemActor == null
                ? new PromotionActor(currentUser.requireId(), currentUser.requireEmployeeId()) : systemActor;
        contributions.values().stream()
                .flatMap(List::stream)
                .forEach(contribution -> updatePegConsumed(contribution, actor.userId()));

        List<PreplanAnalysisPegPort.PreparedPlanTransfer> preparedTransfers =
                analysisId == null
                        ? List.of()
                        : systemActor == null ? preplanAnalysisPeg.transferToPlanDemands(
                                analysisId, planId, warehouseId, demandSlices(demands))
                        : preplanAnalysisPeg.transferToPlanDemands(
                                analysisId, planId, warehouseId, demandSlices(demands), actor.userId());
        List<ProductionMaterialAllocationFacade.AllocationRequest> requests = demands.stream()
                .map(demand -> new ProductionMaterialAllocationFacade.AllocationRequest(
                        packageId, demand.id(), demand.goodsId(), demand.colorId(),
                        warehouseId, demand.requiredQty(), packageId + ":REKIT:"
                                + demand.id() + ":" + triggeringReceiptId
                                + ":V" + segmentRow[9],
                        actor.userId())).toList();
        boolean sameMainWarehouse = analysisId != null
                && contributions.values().stream().allMatch(List::isEmpty);
        List<ProductionMaterialAllocationFacade.AllocationResult> allocated =
                sameMainWarehouse
                        ? stockAllocation.allocateWithQualifiedSources(requests,
                                preparedTransfers.stream().map(value ->
                                        new ProductionMaterialAllocationFacade.QualifiedSourcePreference(
                                                value.demandId(), value.warehouseId(), value.qty(),
                                                value.sourceEntitlementEventId(), value.sourceStockReservationId()))
                                        .toList())
                        : stockAllocation.allocate(requests);
        Map<UUID, BigDecimal> quantityByDemand = new HashMap<>();
        allocated.forEach(value -> quantityByDemand.merge(
                value.demandId(), value.allocatedQty(), BigDecimal::add));
        if (demands.stream().anyMatch(demand -> quantityByDemand
                .getOrDefault(demand.id(), BigDecimal.ZERO)
                .compareTo(demand.requiredQty()) != 0)) {
            throw conflict("齐套判定的可用库存在提升就绪时已变化，请刷新后重试");
        }

        var formalReservations = allocated.stream().filter(allocation -> allocation.allocationId() != null)
                .map(allocation -> new PreplanAnalysisPegPort.FormalReservationSlice(
                        allocation.demandId(), allocation.allocationId(), allocation.allocatedQty())).toList();
        if (systemActor == null) {
            preplanAnalysisPeg.formalizePlanDemandTransfers(packageId, preparedTransfers, formalReservations);
        } else {
            preplanAnalysisPeg.formalizePlanDemandTransfers(packageId, preparedTransfers, formalReservations, actor.userId());
        }

        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        allDemands.stream().map(DemandRow::goodsId).distinct().toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        Map<UUID, StockDocument> drawsByWarehouse = new LinkedHashMap<>();
        Map<UUID, Integer> lineNumbers = new HashMap<>();
        Set<UUID> touched = new LinkedHashSet<>();
        for (DemandRow demand : demands) {
            List<ReceiptContribution> demandContributions =
                    contributions.getOrDefault(demand.id(), List.of());
            for (ProductionMaterialAllocationFacade.AllocationResult allocation : allocated) {
                if (!demand.id().equals(allocation.demandId())
                        || allocation.allocatedQty().signum() <= 0) continue;
                UUID actualWarehouseId = allocation.warehouseId() == null
                        ? warehouseId : allocation.warehouseId();
                StockDocument draw = drawsByWarehouse.computeIfAbsent(actualWarehouseId,
                        ignored -> createDraw(packageId, segmentId, planId, planNo,
                                actualWarehouseId, workshopDepartmentId, responsibleEmployeeId, actor));
                BigDecimal receiptQty = BigDecimal.ZERO;
                for (ReceiptContribution contribution : demandContributions) {
                    receiptQty = receiptQty.add(contribution.qty());
                    UUID drawItemId = addDrawItem(draw, packageId, demand,
                            contribution.qty(), lineNumbers.merge(actualWarehouseId, 1, Integer::sum),
                            planNo, contribution.kind().name() + " receipt " + contribution.receiptId(),
                            StockGoodsSnapshot.require(goodsSnapshots, demand.goodsId(), "齐套领料明细"), actor.userId());
                    recordReceiptAllocation(contribution, packageId, demand.id(),
                            allocation.allocationId(), draw.getId(), drawItemId, actor.userId());
                }
                // Formal receipt conversion keeps the existing one-warehouse path.
                // Analysis entitlement conversion may produce several physical slices.
                BigDecimal genericQty = allocation.allocatedQty().subtract(receiptQty);
                if (genericQty.signum() < 0) {
                    throw conflict("收货来源数量超出实际领料预留");
                }
                if (genericQty.signum() > 0) {
                    addDrawItem(draw, packageId, demand, genericQty,
                            lineNumbers.merge(actualWarehouseId, 1, Integer::sum),
                            planNo, "齐套现有库存",
                            StockGoodsSnapshot.require(goodsSnapshots, demand.goodsId(), "齐套领料明细"), actor.userId());
                }
            }
            touched.add(demand.id());
        }
        if (drawsByWarehouse.isEmpty() && !continuous) {
            throw conflict("执行分段领料单没有任何物料行");
        }
        // 持续生产：直送需求按线边仓已到的量就地预留 + 线边仓领料单(部分到料也算数)。
        for (DemandRow demand : directDemands) {
            allocateDirectSupplyFromLineSide(
                    packageId, segmentId, planId, planNo, warehouseId, analysisId,
                    workshopDepartmentId, responsibleEmployeeId, demand,
                    demand.requiredQty(), packageId + ":REKIT:" + demand.id() + ":" + triggeringReceiptId
                            + ":V" + segmentRow[9],
                    actor, drawsByWarehouse, lineNumbers, goodsSnapshots);
            touched.add(demand.id());
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
                .setParameter("actorId", actor.userId())
                .setParameter("segmentId", segmentId)
                .executeUpdate();
        if (promoted != 1) {
            throw conflict(
                    "提升就绪时执行分段已被并发修改，请刷新后重试");
        }
        ledger.refreshDemandStatuses(touched);
        // 车间直送自动投入(V584/ADR-087，V595 扩到全部用户触发路径)：任何带用户身份的齐套
        // 提升(直送审核/分批领料/人工重核/采购或委外到货审核/持续生产开工)若把本车间线边仓的
        // 直送料切成了领料单，就地在同一事务出库——料是车间自产自检直送来的，再让车间提交
        // 领料申请等仓库发料，就回到了直送要砍掉的那一步。此前只有 RECHECK 路径出库，
        // 「先直送、后到货」的父件会留下一张要仓库替车间发线边仓料的领料单。
        // 系统对账(无用户身份)不经此分支：开工与领料申请两处会就地补出(V595)。
        if (systemActor == null) {
            issueLineSideDrawsAfterPromotion(
                    segmentId, workshopDepartmentId, warehouseId);
        }
        // Readiness alone does not submit a warehouse picking task.
        chainNotice.notifyExecutionSegmentReady(
                segmentId,
                triggeringReceiptId,
                triggeringKind == null
                        ? "MANUAL_RELEASE"
                        : triggeringKind.name());
    }

    /**
     * 用户动作(开工/领料申请)前就地出掉本段尚未出库的线边仓草稿领料单(V595)。
     * 系统对账把父件提升为齐套时没有用户身份，留下的线边仓草稿由第一个带身份的动作补出，
     * 车间不用再为直送料提交领料申请，仓库也不会收到替车间发线边仓料的任务。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void issuePendingLineSideDraws(UUID segmentId) {
        if (segmentId == null || !currentUser.get().isPresent()) return;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT segment.workshop_department_id, package.warehouse_id
                        FROM production_execution_segments segment
                        JOIN production_planning_packages package ON package.id = segment.package_id
                        WHERE segment.id = :segmentId
                          AND segment.is_deleted = FALSE
                          AND segment.status IN ('READY', 'DISPATCHED', 'IN_PROGRESS')
                        """).setParameter("segmentId", segmentId));
        if (rows.isEmpty() || rows.getFirst()[0] == null || rows.getFirst()[1] == null) return;
        issueLineSideDrawsAfterPromotion(
                segmentId, uuid(rows.getFirst()[0]), uuid(rows.getFirst()[1]));
    }

    /**
     * 出掉提升段在本车间线边仓(与包仓同主仓)的草稿领料单；无草稿或无线边仓时自然空转。
     *
     * <p>先按 {@code requireWorkshopDirectTransferDocument} 的口径预检「这个段在这个
     * 线边仓确有有效直送行」再调用——线边仓公共库存被无谱系任务占用时(ADR-087 遗留节)
     * 其草稿不合格，自动投入资格校验会拒绝；而 MANDATORY 代理调用一旦抛错会把共享事务
     * 标记 rollback-only，外层用户动作(直送审核/人工重核/分批提交)整单回滚。预检排除
     * 后，能进来的单据必然两证其一成立，不再有系统性拒绝。
     */
    private void issueLineSideDrawsAfterPromotion(
            UUID segmentId, UUID workshopDepartmentId, UUID warehouseId) {
        if (workshopDepartmentId == null) return;
        for (UUID lineSide : NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT line_side.id
                        FROM warehouses line_side
                        WHERE line_side.is_line_side
                          AND line_side.is_deleted = FALSE
                          AND line_side.workshop_department_id = :workshopId
                          AND fn_warehouse_same_main(line_side.id, :warehouseId)
                        ORDER BY line_side.id
                        """)
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("warehouseId", warehouseId), UUID.class)) {
            Boolean transferTouchesSegment = (Boolean) em.createNativeQuery("""
                            SELECT EXISTS (
                                SELECT 1
                                FROM production_workshop_direct_transfer_items transfer_item
                                JOIN production_workshop_direct_transfers transfer
                                  ON transfer.id = transfer_item.transfer_id
                                 AND transfer.line_side_warehouse_id = :lineSide
                                WHERE transfer_item.reversal_id IS NULL
                                  AND (transfer_item.to_execution_segment_id = :segmentId
                                       OR transfer_item.to_demand_id IN (
                                           SELECT COALESCE(demand.split_root_demand_id, demand.id)
                                           FROM production_material_demands demand
                                           WHERE demand.execution_segment_id = :segmentId
                                             AND demand.is_deleted = FALSE)))
                            """)
                    .setParameter("lineSide", lineSide)
                    .setParameter("segmentId", segmentId)
                    .getSingleResult();
            if (!Boolean.TRUE.equals(transferTouchesSegment)) continue;
            stockDocs.getObject().issueWorkshopDirectTransferDraws(
                    segmentId, lineSide, "PROMOTE-DT-" + segmentId + "-" + lineSide);
        }
    }

    /**
     * 持续生产且全部子件都由同车间直送供给(V595)：没有任何仓库需求要齐套，段直接进 READY，
     * 线边仓已到的直送料按需求就地预留出库；一件都还没到也照样可以「部分开工」。
     */
    private void promoteContinuousWithoutKitDemands(
            UUID segmentId, UUID packageId, UUID planId, String planNo, UUID warehouseId,
            UUID workshopDepartmentId, UUID responsibleEmployeeId,
            List<DemandRow> directDemands, Object[] segmentRow) {
        PromotionActor actor = new PromotionActor(
                currentUser.requireId(), currentUser.requireEmployeeId());
        Map<UUID, StockGoodsSnapshot> goodsSnapshots = StockGoodsSnapshot.fromMaster(
                em, directDemands.stream().map(DemandRow::goodsId).distinct().toList(),
                StockGoodsSnapshot.MASTER_AT_SAVE);
        Map<UUID, StockDocument> drawsByWarehouse = new LinkedHashMap<>();
        Map<UUID, Integer> lineNumbers = new HashMap<>();
        Set<UUID> touched = new LinkedHashSet<>();
        for (DemandRow demand : directDemands) {
            allocateDirectSupplyFromLineSide(
                    packageId, segmentId, planId, planNo, warehouseId, uuid(segmentRow[5]),
                    workshopDepartmentId, responsibleEmployeeId, demand,
                    demand.requiredQty(), packageId + ":REKIT:" + demand.id() + ":" + segmentId
                            + ":V" + segmentRow[9],
                    actor, drawsByWarehouse, lineNumbers, goodsSnapshots);
            touched.add(demand.id());
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
                .setParameter("actorId", actor.userId())
                .setParameter("segmentId", segmentId)
                .executeUpdate();
        if (promoted != 1) {
            throw conflict("提升就绪时执行分段已被并发修改，请刷新后重试");
        }
        ledger.refreshDemandStatuses(touched);
        issueLineSideDrawsAfterPromotion(segmentId, workshopDepartmentId, warehouseId);
        chainNotice.notifyExecutionSegmentReady(segmentId, segmentId, "CONTINUOUS_SUPPLY");
    }

    /**
     * 把直送指名给这条需求、且已经躺在本车间线边仓里的料预留出来并写进线边仓领料单(V595)。
     * 只动线边仓、只动指名给它的料(分析权益先转正式预留，再取无主料)；一件都没到时不留任何
     * 痕迹。返回用到的线边仓(无则 null)。
     */
    private UUID allocateDirectSupplyFromLineSide(
            UUID packageId, UUID segmentId, UUID planId, String planNo, UUID warehouseId,
            UUID analysisId, UUID workshopDepartmentId, UUID responsibleEmployeeId, DemandRow demand,
            BigDecimal ceiling, String idempotencyKey, PromotionActor actor,
            Map<UUID, StockDocument> drawsByWarehouse, Map<UUID, Integer> lineNumbers,
            Map<UUID, StockGoodsSnapshot> goodsSnapshots) {
        BigDecimal remaining = ceiling.subtract(decimal(em.createNativeQuery("""
                        SELECT COALESCE(SUM(reservation.qty - reservation.released_qty), 0)
                        FROM stock_reservations reservation
                        WHERE reservation.demand_id = :demandId
                          AND reservation.is_deleted = FALSE
                        """).setParameter("demandId", demand.id()).getSingleResult()));
        if (remaining.signum() <= 0) return null;
        UUID used = null;
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT line_side.id, COALESCE(balance.qty, 0)
                        FROM warehouses line_side
                        LEFT JOIN stock_balances balance
                          ON balance.warehouse_id = line_side.id
                         AND balance.goods_id = :goodsId
                         AND balance.color_id IS NOT DISTINCT FROM CAST(:colorId AS UUID)
                        WHERE line_side.is_line_side
                          AND line_side.is_deleted = FALSE
                          AND line_side.workshop_department_id = :workshopId
                          AND fn_warehouse_same_main(line_side.id, :warehouseId)
                          AND fn_line_side_stock_targets_demand(line_side.id, :demandId)
                          AND COALESCE(balance.qty, 0) > 0
                        ORDER BY line_side.id
                        """)
                .setParameter("goodsId", demand.goodsId())
                .setParameter("colorId", demand.colorId())
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("warehouseId", warehouseId)
                .setParameter("demandId", demand.id()))) {
            if (remaining.signum() <= 0) break;
            UUID lineSide = uuid(row[0]);
            for (ProductionMaterialAllocationFacade.AllocationResult allocation
                    : allocateDirectSupplyWithinLeaf(packageId, warehouseId, planId, analysisId, demand,
                            lineSide, remaining, idempotencyKey + ":LS:" + lineSide, actor.userId())) {
                if (allocation.allocatedQty().signum() <= 0) continue;
                remaining = remaining.subtract(allocation.allocatedQty());
                used = lineSide;
                if (allocation.replayed()) continue;
                StockDocument draw = drawsByWarehouse.computeIfAbsent(lineSide,
                        ignored -> createDraw(packageId, segmentId, planId, planNo,
                                lineSide, workshopDepartmentId, responsibleEmployeeId, actor));
                addDrawItem(draw, packageId, demand, allocation.allocatedQty(),
                        lineNumbers.merge(lineSide, 1, Integer::sum), planNo,
                        "车间直送 · 持续生产",
                        StockGoodsSnapshot.require(goodsSnapshots, demand.goodsId(), "直送领料明细"),
                        actor.userId());
            }
        }
        return used;
    }

    private static List<PreplanAnalysisPegPort.DemandSlice> demandSlices(List<DemandRow> demands) {
        return demands.stream().map(demand -> new PreplanAnalysisPegPort.DemandSlice(
                demand.id(), demand.goodsId(), demand.colorId(), demand.requiredQty())).toList();
    }

    private List<Object[]> availabilityRows(
            UUID warehouseId,
            List<UUID> demandIds,
            UUID analysisId,
            UUID analysisItemId) {
        return NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT demand.id, scope.id, COALESCE(balance.qty,0), COALESCE(reserved.qty,0),
                               COALESCE(own.qty,0), COALESCE(own.qualified_qty,0),
                               GREATEST(COALESCE(goods.min_qty,0),0)::numeric,
                               (NOT scope.is_defective AND fn_warehouse_same_main(scope.id,:warehouseId)
                                AND (NOT scope.is_line_side
                                     OR fn_line_side_stock_targets_demand(scope.id, demand.id))) AS public_allowed,
                               (fn_warehouse_same_main(scope.id,:warehouseId)
                                AND (NOT scope.is_line_side
                                     OR fn_line_side_stock_targets_demand(scope.id, demand.id))) AS may_allocate,
                               goods.code, goods.name, scope.name, scope.is_line_side
                        FROM production_material_demands demand
                        JOIN goods ON goods.id = demand.goods_id
                        JOIN warehouses scope ON scope.is_deleted = FALSE
                          AND scope.is_accountable = TRUE
                          AND NOT EXISTS (SELECT 1 FROM warehouses child
                              WHERE child.parent_id = scope.id AND child.is_deleted = FALSE)
                          AND (scope.id = :warehouseId OR fn_warehouse_same_main(scope.id, :warehouseId)
                               OR EXISTS (
                                   SELECT 1 FROM stock_reservations source
                                   JOIN v_preplan_stock_entitlement_beneficiary_balance entitlement
                                     ON entitlement.stock_reservation_id=source.id AND entitlement.effective_qty>0
                                   WHERE source.warehouse_id=scope.id AND source.goods_id=demand.goods_id
                                     AND source.color_id IS NOT DISTINCT FROM demand.color_id
                                     AND entitlement.beneficiary_analysis_id=:analysisId
                                     AND fn_analysis_plan_material_matches(:analysisItemId,entitlement.beneficiary_analysis_material_id)
                                     AND fn_preplan_reservation_has_qualified_origin(source.id)))
                        LEFT JOIN stock_balances balance
                          ON balance.goods_id = demand.goods_id
                         AND balance.color_id IS NOT DISTINCT FROM demand.color_id
                         AND balance.warehouse_id = scope.id
                        LEFT JOIN LATERAL (
                            SELECT SUM(reservation.qty
                                - reservation.consumed_qty
                                - reservation.released_qty) AS qty
                            FROM stock_reservations reservation
                            WHERE reservation.goods_id = demand.goods_id
                              AND reservation.color_id
                                  IS NOT DISTINCT FROM demand.color_id
                              AND (reservation.warehouse_id IS NULL
                                   OR reservation.warehouse_id = scope.id)
                              AND reservation.status = :effective
                              AND reservation.is_deleted = FALSE
                        ) reserved ON TRUE
                        LEFT JOIN LATERAL (
                            SELECT SUM(owned.qty) AS qty,
                                   SUM(CASE WHEN owned.qualified THEN owned.qty ELSE 0 END) AS qualified_qty
                            FROM (SELECT fn_preplan_reservation_has_qualified_origin(preplan_reservation.id) AS qualified,
                                CASE
                                WHEN EXISTS (
                                    SELECT 1
                                    FROM preplan_stock_entitlement_events tracked
                                    WHERE tracked.stock_reservation_id =
                                        preplan_reservation.id
                                ) THEN COALESCE((
                                    SELECT SUM(entitlement.effective_qty)
                                    FROM v_preplan_stock_entitlement_beneficiary_balance
                                         entitlement
                                    JOIN production_material_analysis_materials
                                         material
                                      ON material.analysis_id =
                                         entitlement.beneficiary_analysis_id
                                     AND material.id =
                                         entitlement.beneficiary_analysis_material_id
                                     AND material.active = TRUE
                                    WHERE entitlement.stock_reservation_id =
                                          preplan_reservation.id
                                      AND entitlement.beneficiary_analysis_id =
                                          :analysisId
                                      AND fn_analysis_plan_material_matches(
                                          :analysisItemId, material.id)
                                ), 0)
                                WHEN preplan_reservation.owner_id = :analysisId
                                THEN preplan_reservation.qty
                                     - preplan_reservation.consumed_qty
                                     - preplan_reservation.released_qty
                                ELSE 0
                            END AS qty
                            FROM stock_reservations preplan_reservation
                            WHERE preplan_reservation.is_deleted = FALSE
                              AND preplan_reservation.status = :effective
                              AND preplan_reservation.owner_type =
                                  'PREPLAN_ANALYSIS'
                              AND preplan_reservation.warehouse_id = scope.id
                              AND preplan_reservation.goods_id = demand.goods_id
                              AND preplan_reservation.color_id
                                  IS NOT DISTINCT FROM demand.color_id
                            ) owned
                        ) own ON TRUE
                        WHERE demand.id IN (:demandIds)
                        ORDER BY demand.goods_id,
                                 demand.color_id NULLS FIRST, demand.id, scope.id
                        """)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("effective", RESERVATION_EFFECTIVE)
                        .setParameter("analysisId", analysisId)
                        .setParameter("analysisItemId", analysisItemId)
                        .setParameter("demandIds", demandIds));
    }

    /** Same qualified-source/public-stock quantities used by the formal promotion command. */
    @Transactional(readOnly = true)
    public List<BatchAvailability> batchAvailability(UUID warehouseId, List<UUID> demandIds,
                                                    UUID analysisId, UUID analysisItemId) {
        if (demandIds.isEmpty()) return List.of();
        return availabilityRows(warehouseId, demandIds, analysisId, analysisItemId).stream().map(row -> {
            boolean publicAllowed = Boolean.TRUE.equals(row[7]);
            BigDecimal owned = publicAllowed ? decimal(row[4]) : decimal(row[5]);
            BigDecimal physical = decimal(row[2]).subtract(decimal(row[3])).add(owned).max(BigDecimal.ZERO);
            BigDecimal qualified = decimal(row[5]).max(BigDecimal.ZERO).min(physical);
            return new BatchAvailability(uuid(row[0]), uuid(row[1]), Objects.toString(row[11], ""),
                    qualified, publicAllowed && Boolean.TRUE.equals(row[8])
                            ? physical.subtract(qualified) : BigDecimal.ZERO,
                    decimal(row[6]), owned.signum() > 0, owned, publicAllowed && Boolean.TRUE.equals(row[8]),
                    Boolean.TRUE.equals(row[12]));
        }).toList();
    }

    public record BatchAvailability(UUID demandId, UUID warehouseId, String warehouseName,
                                    BigDecimal qualifiedQty, BigDecimal publicQty,
                                    BigDecimal safetyQty, boolean ownedFirst, BigDecimal ownedQty,
                                    boolean normalWarehouse, boolean lineSide) {}

    private boolean isFullyAvailable(UUID warehouseId, List<DemandRow> demands,
                                     UUID analysisId, UUID analysisItemId, boolean explainShortage) {
        List<Object[]> rows = availabilityRows(warehouseId,
                demands.stream().map(DemandRow::id).toList(), analysisId, analysisItemId);
        Map<UUID, BigDecimal[]> budgets = new HashMap<>();
        for (Object[] row : rows) {
            boolean publicAllowed = Boolean.TRUE.equals(row[7]);
            BigDecimal owned = publicAllowed ? decimal(row[4]) : decimal(row[5]);
            BigDecimal physical = decimal(row[2]).subtract(decimal(row[3])).add(owned).max(BigDecimal.ZERO);
            BigDecimal qualified = decimal(row[5]).max(BigDecimal.ZERO).min(physical);
            BigDecimal unprotected = publicAllowed ? physical.subtract(qualified) : BigDecimal.ZERO;
            BigDecimal[] budget = budgets.computeIfAbsent(uuid(row[0]), ignored -> new BigDecimal[]{
                    BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO});
            budget[0] = budget[0].add(unprotected);
            if (Boolean.TRUE.equals(row[8])) budget[1] = budget[1].add(unprotected);
            budget[2] = budget[2].add(qualified);
            budget[3] = budget[3].max(decimal(row[6]));
        }
        Map<UUID, BigDecimal> available = new HashMap<>();
        budgets.forEach((id, budget) -> available.put(id, budget[2].add(budget[1].min(
                com.uten.imp.common.inventory.MainWarehouseStockBudget.publicBudget(budget[0], budget[3])))));
        Map<ProductionMaterialAllocationFacade.MaterialDimension, BigDecimal> required =
                new LinkedHashMap<>();
        demands.forEach(demand -> required.merge(new ProductionMaterialAllocationFacade
                .MaterialDimension(demand.goodsId(), demand.colorId()),
                demand.requiredQty(), BigDecimal::add));
        List<String> shortages = new ArrayList<>();
        for (DemandRow demand : demands) {
            ProductionMaterialAllocationFacade.MaterialDimension key =
                    new ProductionMaterialAllocationFacade.MaterialDimension(
                            demand.goodsId(), demand.colorId());
            BigDecimal needed = required.remove(key);
            if (needed == null) continue;
            BigDecimal missing = needed.subtract(available
                    .getOrDefault(demand.id(), BigDecimal.ZERO));
            if (missing.signum() <= 0) continue;
            String label = rows.stream().filter(row -> demand.id().equals(uuid(row[0])))
                    .findFirst().map(row -> Objects.toString(row[9], "") + " "
                            + Objects.toString(row[10], "")).orElse(demand.goodsId().toString());
            shortages.add(label.strip() + " 缺 " + missing.stripTrailingZeros().toPlainString());
        }
        if (explainShortage && !shortages.isEmpty()) {
            throw conflict("按本任务已合格入库来源及可用公共库存核算后仍缺料: "
                    + String.join("; ", shortages.stream().limit(8).toList())
                    + (shortages.size() > 8 ? "; 另有 " + (shortages.size() - 8) + " 项" : ""));
        }
        return shortages.isEmpty();
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
                                               fn_procurement_received_in_warehouse('PURCHASE',receipt_item.id,:warehouseId)
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
                                                         AND EXISTS(SELECT 1 FROM stock_reservations actual
                                                             WHERE actual.id=allocation.reservation_id AND actual.warehouse_id=:warehouseId)
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
                                      AND fn_procurement_received_in_warehouse('PURCHASE',receipt_item.id,:warehouseId)>0
                                    LEFT JOIN procurement_inspection_items
                                      inspection
                                      ON inspection.receipt_type = 'PURCHASE'
                                     AND inspection.receipt_item_id =
                                         receipt_item.id
                                    WHERE peg.demand_id = :demandId
                                      AND peg.supply_type =
                                          'PURCHASE_ORDER_ITEM'
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                      AND receipt.status = 1
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id()));
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
                                               fn_procurement_received_in_warehouse('SUBCONTRACT',receipt_item.id,:warehouseId)
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
                                                         AND EXISTS(SELECT 1 FROM stock_reservations actual
                                                             WHERE actual.id=allocation.reservation_id AND actual.warehouse_id=:warehouseId)
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
                                      AND fn_procurement_received_in_warehouse('SUBCONTRACT',receipt_item.id,:warehouseId)>0
                                    LEFT JOIN procurement_inspection_items
                                      inspection
                                      ON inspection.receipt_type =
                                         'SUBCONTRACT'
                                     AND inspection.receipt_item_id =
                                         receipt_item.id
                                    WHERE peg.demand_id = :demandId
                                      AND peg.supply_type =
                                          'SUBCONTRACT_ORDER_ITEM'
                                      AND peg.status <> 'REVERSED'
                                      AND peg.allocated_qty
                                            - peg.consumed_qty
                                            - peg.released_qty > 0
                                      AND receipt.status = 1
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id())));
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
                                      AND receipt.status = 1
                                    ORDER BY receipt.bill_date,
                                             receipt.id, receipt_item.id
                                    FOR UPDATE OF peg
                                    """)
                            .setParameter("warehouseId", warehouseId)
                            .setParameter("demandId", demand.id())
                            .setParameter("goodsId", demand.goodsId())
                            .setParameter("colorId", demand.colorId())
                            .setParameter("unitId", demand.unitId())));
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
            UUID warehouseId,
            UUID workshopDepartmentId,
            UUID responsibleEmployeeId, PromotionActor actor) {
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
        document.setDepartmentId(workshopDepartmentId);
        document.setWorkerId(responsibleEmployeeId);
        document.setMakerId(actor.employeeId());
        document.setStatus((short) 0);
        stockDocumentRepo.saveAndFlush(document);
        ledger.recordDocument(
                packageId,
                segmentId,
                "DRAW",
                document.getId(),
                document.getBillNo(),
                actor.userId());
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(
                            plan_id, draw_id, created_by)
                        VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", planId)
                .setParameter("drawId", document.getId())
                .setParameter("actorId", actor.userId())
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
            String remark,
            StockGoodsSnapshot goodsSnapshot, UUID actorId) {
        StockDocumentItem item = new StockDocumentItem();
        item.setDocId(draw.getId());
        item.setBillType("DRAW");
        item.setBillNo(draw.getBillNo());
        item.setBillDate(draw.getBillDate());
        item.setLineNo(lineNo);
        item.setGoodsId(demand.goodsId());
        goodsSnapshot.applyTo(item, null);
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
                .setParameter("actorId", actorId)
                .executeUpdate();
        return item.getId();
    }

    private void updatePegConsumed(
            ReceiptContribution contribution, UUID actorId) {
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
                .setParameter("actorId", actorId)
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
            UUID drawItemId, UUID actorId) {
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
                .setParameter("actorId", actorId)
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
            case PREPLAN, RECHECK, RECONCILE -> throw new IllegalArgumentException(
                    "PREPLAN entitlement has no receipt-allocation table");
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
            case PREPLAN, RECHECK, RECONCILE -> throw new IllegalArgumentException(
                    "PREPLAN entitlement has no receipt-allocation key");
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
            BigDecimal requiredQty,
            boolean directSupply) {
        DemandRow(UUID id, UUID goodsId, UUID colorId, UUID unitId, BigDecimal requiredQty) {
            this(id, goodsId, colorId, unitId, requiredQty, false);
        }
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
        MAKE,
        PREPLAN,
        RECHECK,
        RECONCILE
    }
}
