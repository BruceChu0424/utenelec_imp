package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.util.NativeQueryResults;
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

        // 归属候选：该外部明细被哪些仍有效的分析的未取消供应行动分摊过。
        List<Object[]> claimants = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT allocation.analysis_id,
                               SUM(allocation.allocated_qty)::numeric
                        FROM preplan_supply_action_allocations allocation
                        JOIN preplan_supply_actions action
                          ON action.id = allocation.action_id
                         AND action.status <> 'CANCELLED'
                        JOIN production_material_analyses analysis
                          ON analysis.id = allocation.analysis_id
                         AND analysis.is_deleted = FALSE
                         AND analysis.status IN ('ACTIVE', 'PARTIALLY_PLANNED')
                        WHERE allocation.external_item_id = :externalItemId
                        GROUP BY allocation.analysis_id
                        ORDER BY allocation.analysis_id
                        """).setParameter("externalItemId", externalItemId));

        BigDecimal remaining = passedBaseQty;
        for (Object[] claimant : claimants) {
            if (remaining.signum() <= 0) {
                break;
            }
            UUID analysisId = (UUID) claimant[0];
            BigDecimal allocatedCap = decimal(claimant[1]);
            BigDecimal alreadyAttributed = decimal(em.createNativeQuery("""
                            SELECT COALESCE(SUM(qty), 0)
                            FROM stock_reservations
                            WHERE is_deleted = FALSE
                              AND owner_type = :ownerType
                              AND owner_id = :analysisId
                              AND supply_type = :supplyType
                              AND supply_id = :externalItemId
                              AND released_qty < qty
                            """)
                    .setParameter("ownerType", OWNER_TYPE)
                    .setParameter("analysisId", analysisId)
                    .setParameter("supplyType", supplyType)
                    .setParameter("externalItemId", externalItemId)
                    .getSingleResult());
            BigDecimal headroom = allocatedCap.subtract(alreadyAttributed);
            BigDecimal take = remaining.min(headroom.max(BigDecimal.ZERO));
            if (take.signum() <= 0) {
                continue;
            }
            insertReservation(
                    analysisId, warehouseId, goodsId, colorId, take,
                    supplyType, externalItemId,
                    receiptType + "_RECEIPT", receiptId,
                    "PREPLAN-PEG:" + dispositionEventId + ":" + analysisId);
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

    // ============================ 对称释放 ============================

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseForReceipt(String receiptType, UUID receiptId) {
        tx.bind();
        releaseRows(
                "r.source_doc_type = :sourceDocType AND r.source_doc_id = :sourceDocId",
                Map.of(
                        "sourceDocType", receiptType + "_RECEIPT",
                        "sourceDocId", receiptId),
                "PREPLAN_RECEIPT_REVERSED");
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
            UUID analysisId, UUID warehouseId, List<DemandSlice> demands) {
        tx.bind();
        if (analysisId == null || warehouseId == null
                || demands == null || demands.isEmpty()) {
            return;
        }
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
                            SELECT id, qty, consumed_qty, released_qty
                            FROM stock_reservations
                            WHERE is_deleted = FALSE
                              AND status = :effective
                              AND owner_type = :ownerType
                              AND owner_id = :analysisId
                              AND warehouse_id = :warehouseId
                              AND goods_id = :goodsId
                              AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                            ORDER BY created_at, id
                            FOR UPDATE
                            """)
                    .setParameter("effective", STATUS_EFFECTIVE)
                    .setParameter("ownerType", OWNER_TYPE)
                    .setParameter("analysisId", analysisId)
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

    /** 对称释放：生效中预留逐行释放完结；已转移/已释放的行幂等跳过。 */
    private void releaseRows(
            String whereClause,
            Map<String, Object> params,
            String releaseReason) {
        jakarta.persistence.Query query = em.createNativeQuery("""
                SELECT r.id, r.qty, r.consumed_qty, r.released_qty,
                       r.goods_id, r.color_id
                FROM stock_reservations r
                WHERE r.is_deleted = FALSE
                  AND r.status = :effective
                  AND r.owner_type = :ownerType
                  AND %s
                ORDER BY r.created_at, r.id
                FOR UPDATE OF r
                """.formatted(whereClause))
                .setParameter("effective", STATUS_EFFECTIVE)
                .setParameter("ownerType", OWNER_TYPE);
        params.forEach(query::setParameter);
        applyRelease(NativeQueryResults.objectArrayRows(query), releaseReason);
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
