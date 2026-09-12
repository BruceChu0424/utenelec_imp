package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

/**
 * Rechecks active material analyses after qualified stock really changes.
 *
 * <p>The source document transaction remains authoritative: this service runs
 * with {@link Propagation#MANDATORY}, locks matching analyses in stable id order,
 * refreshes each one, and lets any failure roll the source transaction back.
 * Receipt units are deliberately ignored because inventory and BOM consumption
 * are already expressed in the goods basic unit.</p>
 */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisSupplyWakeupService {

    private final EntityManager em;
    private final MaterialAnalysisService materialAnalysisService;
    private final com.uten.imp.application.concurrency.FulfillmentMutationLocks mutationLocks;
    private final com.uten.imp.application.port.ProductionMutationFootprintPort mutationFootprints;

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseReceiptApproved(UUID receiptId) {
        refreshReceipt("PURCHASE", receiptId, false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseReceiptReversed(UUID receiptId) {
        refreshReceipt("PURCHASE", receiptId, true);
    }

    /**
     * IQC 仓库确认入库（单张或批量，整批同事务）后的整批一轮唤醒：
     * 目标 = 本次确认的待检行维度 ∪ 该收货单 RESOLVED 维度上的活跃分析，
     * 按分析去重后每个分析只刷新一次。到货更新实际物料进度，
     * 不再向计划制单人发送“物料已可下达”的旧提醒；车间就绪通知由
     * 执行段实际状态变化单独发送。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterInspectionStockInConfirmed(
            String sourceType,
            UUID receiptId,
            UUID warehouseStockInBatchId,
            Collection<UUID> inspectionItemIds) {
        if (warehouseStockInBatchId == null
                || inspectionItemIds == null || inspectionItemIds.isEmpty()) {
            return;
        }
        afterInspectionStockInConfirmed(List.of(new ReceiptStockIn(
                sourceType, receiptId, warehouseStockInBatchId,
                List.copyOf(inspectionItemIds))));
    }

    /**
     * The caller has written every receipt's physical stock and entitlement slices.
     * Resolve the union of affected dimensions once, then refresh each analysis once
     * in the same transaction. A later failure still rolls back the entire stock-in.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches) {
        Map<UUID, UUID> makers = new TreeMap<>();
        for (AnalysisTarget target : inspectionStockInTargets(batches)) {
            makers.put(target.analysisId(), target.makerEmployeeId());
        }
        List<AnalysisTarget> targets = new ArrayList<>(makers.size());
        makers.forEach((analysisId, makerEmployeeId) ->
                targets.add(new AnalysisTarget(analysisId, makerEmployeeId)));
        refreshTargets(targets);
    }

    private List<AnalysisTarget> inspectionStockInTargets(List<ReceiptStockIn> batches) {
        if (batches == null || batches.isEmpty()) return List.of();
        List<UUID> purchaseReceiptIds = new ArrayList<>();
        List<UUID> subcontractReceiptIds = new ArrayList<>();
        var inspectionItemIds = new LinkedHashSet<UUID>();
        for (ReceiptStockIn batch : batches) {
            if (batch.batchId() == null || batch.inspectionItemIds().isEmpty()) continue;
            switch (batch.receiptType()) {
                case "PURCHASE" -> purchaseReceiptIds.add(batch.receiptId());
                case "SUBCONTRACT" -> subcontractReceiptIds.add(batch.receiptId());
                default -> throw new IllegalArgumentException("Unsupported stock-in receipt type");
            }
            inspectionItemIds.addAll(batch.inspectionItemIds());
        }
        if (inspectionItemIds.isEmpty()) return List.of();
        // UUID arrays avoid IN () for a one-type batch, and bind each receipt to
        // its document type. Resolved siblings retain the old rejection wakeup.
        return analysisTargets(candidateQuery("""
                    SELECT DISTINCT inspection.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    WHERE (
                        (inspection.receipt_type = 'PURCHASE'
                         AND inspection.receipt_id = ANY(CAST(string_to_array(:purchaseReceiptIds, ',') AS uuid[]))
                         AND EXISTS (SELECT 1 FROM purchase_receipts receipt
                             WHERE receipt.id = inspection.receipt_id
                               AND receipt.status = 1 AND receipt.is_deleted = FALSE))
                        OR
                        (inspection.receipt_type = 'SUBCONTRACT'
                         AND inspection.receipt_id = ANY(CAST(string_to_array(:subcontractReceiptIds, ',') AS uuid[]))
                         AND EXISTS (SELECT 1 FROM subcontract_receipts receipt
                             WHERE receipt.id = inspection.receipt_id
                               AND receipt.status = 1 AND receipt.is_deleted = FALSE))
                    )
                    AND (inspection.status = 'RESOLVED'
                         OR (inspection.id IN (:inspectionItemIds)
                             AND inspection.status = 'PARTIAL'
                             AND inspection.warehouse_stocked_base_qty > 0))
                """)
                .setParameter("purchaseReceiptIds", uuidParameter(purchaseReceiptIds))
                .setParameter("subcontractReceiptIds", uuidParameter(subcontractReceiptIds))
                .setParameter("inspectionItemIds", List.copyOf(inspectionItemIds)));
    }

    private static String uuidParameter(Collection<UUID> ids) {
        return ids.stream().distinct().sorted().map(UUID::toString)
                .collect(java.util.stream.Collectors.joining(","));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterSubcontractReceiptApproved(UUID receiptId) {
        refreshReceipt("SUBCONTRACT", receiptId, false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterSubcontractReceiptReversed(UUID receiptId) {
        refreshReceipt("SUBCONTRACT", receiptId, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(UUID stockDocumentId) {
        refreshTargets(finishedInboundTargets(stockDocumentId, 1));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(Collection<UUID> stockDocumentIds) {
        refreshTargets(finishedInboundTargets(stockDocumentIds, 1));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundReversed(UUID stockDocumentId) {
        refreshTargets(finishedInboundTargets(stockDocumentId, -1));
    }

    private void refreshReceipt(
            String sourceType,
            UUID receiptId,
            boolean includeLegacyFallback) {
        List<AnalysisTarget> targets = "PURCHASE".equals(sourceType)
                ? purchaseTargets(receiptId, includeLegacyFallback)
                : subcontractTargets(receiptId, includeLegacyFallback);
        refreshTargets(targets);
    }

    private void refreshTargets(List<AnalysisTarget> targets) {
        if (!targets.isEmpty()) {
            mutationLocks.requireCovered(mutationFootprints.forAnalyses(
                    targets.stream().map(AnalysisTarget::analysisId).toList()));
        }
        for (AnalysisTarget target : targets) {
            materialAnalysisService.refreshLocked(target.analysisId());
        }
        // Planning can issue tasks before materials arrive. A stock receipt must
        // update these facts, not ask the plan maker to issue the same work again.
        // Actual WAITING -> READY notifications belong to the exact workshop task.
    }

    private List<AnalysisTarget> purchaseTargets(
            UUID receiptId, boolean includeLegacyFallback) {
        return analysisTargets(candidateQuery("""
                    SELECT DISTINCT inspection.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    JOIN purchase_receipts receipt
                      ON receipt.id = inspection.receipt_id
                     AND receipt.is_deleted = FALSE
                    WHERE inspection.receipt_type = 'PURCHASE'
                      AND inspection.receipt_id = :sourceDocumentId
                      AND (
                          (:includeLegacyFallback = FALSE
                           AND receipt.status = 1
                           AND inspection.status = 'RESOLVED')
                          OR
                          (:includeLegacyFallback = TRUE
                           AND receipt.status = -1
                           AND inspection.status = 'REVERSED')
                      )
                    UNION
                    SELECT receipt.warehouse_id, item.goods_id, item.color_id
                    FROM purchase_receipts receipt
                    JOIN purchase_receipt_items item
                      ON item.receipt_id = receipt.id
                     AND item.is_deleted = FALSE
                    WHERE :includeLegacyFallback = TRUE
                      AND receipt.id = :sourceDocumentId
                      AND receipt.is_deleted = FALSE
                      AND receipt.warehouse_id IS NOT NULL
                      AND receipt.status = -1
                      AND NOT EXISTS (
                          SELECT 1 FROM procurement_inspection_items inspection
                          WHERE inspection.receipt_type = 'PURCHASE'
                            AND inspection.receipt_id = receipt.id)
                """)
                .setParameter("sourceDocumentId", receiptId)
                .setParameter("includeLegacyFallback", includeLegacyFallback));
    }

    private List<AnalysisTarget> subcontractTargets(
            UUID receiptId, boolean includeLegacyFallback) {
        return analysisTargets(candidateQuery("""
                    SELECT DISTINCT inspection.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    JOIN subcontract_receipts receipt
                      ON receipt.id = inspection.receipt_id
                     AND receipt.is_deleted = FALSE
                    WHERE inspection.receipt_type = 'SUBCONTRACT'
                      AND inspection.receipt_id = :sourceDocumentId
                      AND (
                          (:includeLegacyFallback = FALSE
                           AND receipt.status = 1
                           AND inspection.status = 'RESOLVED')
                          OR
                          (:includeLegacyFallback = TRUE
                           AND receipt.status = -1
                           AND inspection.status = 'REVERSED')
                      )
                    UNION
                    SELECT receipt.warehouse_id, item.goods_id, item.color_id
                    FROM subcontract_receipts receipt
                    JOIN subcontract_receipt_items item
                      ON item.receipt_id = receipt.id
                     AND item.is_deleted = FALSE
                    WHERE :includeLegacyFallback = TRUE
                      AND receipt.id = :sourceDocumentId
                      AND receipt.is_deleted = FALSE
                      AND receipt.warehouse_id IS NOT NULL
                      AND receipt.status = -1
                      AND NOT EXISTS (
                          SELECT 1 FROM procurement_inspection_items inspection
                          WHERE inspection.receipt_type = 'SUBCONTRACT'
                            AND inspection.receipt_id = receipt.id)
                """)
                .setParameter("sourceDocumentId", receiptId)
                .setParameter("includeLegacyFallback", includeLegacyFallback));
    }

    private List<AnalysisTarget> finishedInboundTargets(
            UUID stockDocumentId, int requiredStatus) {
        return finishedInboundTargets(List.of(stockDocumentId), requiredStatus);
    }

    private List<AnalysisTarget> finishedInboundTargets(
            Collection<UUID> stockDocumentIds, int requiredStatus) {
        if (stockDocumentIds == null || stockDocumentIds.isEmpty()) return List.of();
        return analysisTargets(candidateQuery("""
                    SELECT DISTINCT document.warehouse_id,
                           item.goods_id, item.color_id
                    FROM stock_documents document
                    JOIN stock_document_items item
                      ON item.doc_id = document.id
                     AND item.is_deleted = FALSE
                    WHERE document.id IN (:sourceDocumentIds)
                      AND document.doc_type = 'FINISHED_IN'
                      AND document.status = :requiredStatus
                      AND document.is_deleted = FALSE
                      AND document.warehouse_id IS NOT NULL
                      AND item.goods_id IS NOT NULL
                """).setParameter("sourceDocumentIds", stockDocumentIds.stream().distinct().sorted().toList())
                .setParameter("requiredStatus", requiredStatus));
    }

    /** Materialize this event's dimensions before evaluating warehouse ancestry or fulfillment. */
    private Query candidateQuery(String dimensionSql) {
        return em.createNativeQuery("WITH dimensions AS MATERIALIZED (\n" + dimensionSql + """
                ), candidates AS MATERIALIZED (
                    SELECT DISTINCT analysis.id, analysis.maker_id, analysis.status,
                           analysis.warehouse_id, dimension.warehouse_id AS source_warehouse_id,
                           material.id AS source_material_id, material.goods_id, material.color_id
                    FROM dimensions dimension
                    JOIN production_material_analysis_materials material
                      ON dimension.goods_id = material.goods_id
                     AND dimension.color_id IS NOT DISTINCT FROM material.color_id
                     AND material.active = TRUE
                    JOIN production_material_analyses analysis
                      ON analysis.id = material.analysis_id
                    WHERE analysis.is_deleted = FALSE
                      AND analysis.warehouse_id IS NOT NULL
                )
                SELECT DISTINCT analysis.id, analysis.maker_id
                FROM candidates analysis
                WHERE (analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                    OR analysis.status='COMPLETED'
                      AND fn_material_analysis_fulfillment_status(analysis.id)<>'COMPLETED')
                  AND (fn_warehouse_same_main(analysis.source_warehouse_id,analysis.warehouse_id)
                """ + " OR " + MaterialAnalysisWakeupScopeSql.ownsQualifiedAt(
                        "analysis.id", "analysis.source_material_id", "analysis.source_warehouse_id",
                        "analysis.goods_id", "analysis.color_id") + """
                    )
                ORDER BY analysis.id
                """);
    }

    private List<AnalysisTarget> analysisTargets(Query query) {
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(row -> new AnalysisTarget((UUID) row[0], (UUID) row[1]))
                .toList();
    }

    record AnalysisTarget(UUID analysisId, UUID makerEmployeeId) {
    }
}
