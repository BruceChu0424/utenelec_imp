package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
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

    static final String EVENT_READY = "PRODUCTION_MATERIAL_ANALYSIS_READY";
    static final String AGGREGATE_TYPE = "PRODUCTION_MATERIAL_ANALYSIS";

    private final EntityManager em;
    private final MaterialAnalysisService materialAnalysisService;
    private final BusinessEventPublisher events;

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseReceiptApproved(UUID receiptId) {
        refreshReceipt("PURCHASE", receiptId, false, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterPurchaseReceiptReversed(UUID receiptId) {
        refreshReceipt("PURCHASE", receiptId, true, false);
    }

    /**
     * IQC 仓库确认入库（单张或批量，整批同事务）后的整批一轮唤醒：
     * 目标 = 本次确认的待检行维度 ∪ 该收货单 RESOLVED 维度上的活跃分析，
     * 按分析去重后每个分析只整棵刷新一次。聚合的 readyFinish 前后差值
     * 与旧「逐条明细刷新」的逐次差值之和完全一致（刷新是从当前库态的
     * 全量重算，最终态相同），通知从每条一条聚合为每批一条，
     * dedupe key 携带入库批次号避免跨批次碰撞。
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
        Map<UUID, UUID> makers = new TreeMap<>();
        for (AnalysisTarget target : inspectionStockInTargets(
                sourceType, receiptId, inspectionItemIds)) {
            makers.put(target.analysisId(), target.makerEmployeeId());
        }
        for (AnalysisTarget target : "PURCHASE".equals(sourceType)
                ? purchaseTargets(receiptId, false)
                : subcontractTargets(receiptId, false)) {
            makers.put(target.analysisId(), target.makerEmployeeId());
        }
        List<AnalysisTarget> targets = new ArrayList<>(makers.size());
        makers.forEach((analysisId, makerEmployeeId) ->
                targets.add(new AnalysisTarget(analysisId, makerEmployeeId)));
        refreshTargets(
                sourceType,
                receiptId,
                targets,
                true,
                warehouseStockInBatchId,
                ":IQC_STOCK_IN:" + warehouseStockInBatchId);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterSubcontractReceiptApproved(UUID receiptId) {
        refreshReceipt("SUBCONTRACT", receiptId, false, true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterSubcontractReceiptReversed(UUID receiptId) {
        refreshReceipt("SUBCONTRACT", receiptId, true, false);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(UUID stockDocumentId) {
        refreshTargets(
                "MAKE", stockDocumentId, finishedInboundTargets(stockDocumentId, 1), true, null, "");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundReversed(UUID stockDocumentId) {
        refreshTargets(
                "MAKE", stockDocumentId, finishedInboundTargets(stockDocumentId, -1), false, null, "");
    }

    private void refreshReceipt(
            String sourceType,
            UUID receiptId,
            boolean includeLegacyFallback,
            boolean publishIncrease) {
        List<AnalysisTarget> targets = "PURCHASE".equals(sourceType)
                ? purchaseTargets(receiptId, includeLegacyFallback)
                : subcontractTargets(receiptId, includeLegacyFallback);
        refreshTargets(sourceType, receiptId, targets, publishIncrease, null, "");
    }

    private void refreshTargets(
            String sourceType,
            UUID sourceDocumentId,
            List<AnalysisTarget> targets,
            boolean publishIncrease,
            UUID sourceEventId,
            String eventKeySuffix) {
        for (AnalysisTarget target : targets) {
            Map<UUID, BigDecimal> before = readyFinishByOpenItem(target.analysisId());
            materialAnalysisService.refreshLocked(target.analysisId());
            Map<UUID, BigDecimal> after = readyFinishByOpenItem(target.analysisId());
            if (!publishIncrease || target.makerEmployeeId() == null) continue;

            // Quantities from different analysis items may represent different
            // products and units, so they must never be scalar-summed. A mixed
            // reallocation (one line rises while another falls) is also not a
            // genuine readiness increase and must remain silent.
            boolean anyDecrease = before.entrySet().stream().anyMatch(entry ->
                    after.getOrDefault(entry.getKey(), BigDecimal.ZERO)
                            .compareTo(entry.getValue()) < 0);
            if (anyDecrease) continue;

            String sourceId = sourceDocumentId.toString();
            // 展示用来源单号：通知文案面向业务人员，禁止把 UUID 当单号展示。
            String sourceNo = sourceDocumentNo(sourceType, sourceDocumentId);
            for (Map.Entry<UUID, BigDecimal> entry : after.entrySet()) {
                UUID analysisItemId = entry.getKey();
                BigDecimal previous = before.getOrDefault(
                        analysisItemId, BigDecimal.ZERO);
                BigDecimal delta = entry.getValue().subtract(previous);
                if (delta.signum() <= 0) continue;
                Map<String, String> payload = new LinkedHashMap<>();
                payload.put("makerEmployeeId", target.makerEmployeeId().toString());
                payload.put("sourceType", sourceType);
                payload.put("sourceDocumentId", sourceId);
                payload.put("sourceDocumentNo", sourceNo);
                if (sourceEventId != null) {
                    payload.put("sourceEventId", sourceEventId.toString());
                }
                payload.put("analysisItemId", analysisItemId.toString());
                payload.put("readyFinishDelta", quantityText(delta));
                payload.put("readyFinishQty", quantityText(entry.getValue()));
                events.publishOnce(
                        EVENT_READY,
                        AGGREGATE_TYPE,
                        target.analysisId(),
                        Map.copyOf(payload),
                        EVENT_READY + ':' + target.analysisId() + ':'
                                + analysisItemId + ':' + sourceType + ':' + sourceId
                                + eventKeySuffix);
            }
        }
    }

    private List<AnalysisTarget> inspectionStockInTargets(
            String sourceType, UUID receiptId, Collection<UUID> inspectionItemIds) {
        return analysisTargets(em.createNativeQuery("""
                WITH passed_dimension AS (
                    SELECT inspection.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    WHERE inspection.id IN (:inspectionItemIds)
                      AND inspection.receipt_type = :sourceType
                      AND inspection.receipt_id = :sourceDocumentId
                      AND inspection.status IN ('PARTIAL', 'RESOLVED')
                      AND inspection.warehouse_stocked_base_qty > 0
                      AND (
                          (:sourceType = 'PURCHASE' AND EXISTS (
                              SELECT 1 FROM purchase_receipts receipt
                              WHERE receipt.id = inspection.receipt_id
                                AND receipt.status = 1
                                AND receipt.is_deleted = FALSE))
                          OR
                          (:sourceType = 'SUBCONTRACT' AND EXISTS (
                              SELECT 1 FROM subcontract_receipts receipt
                              WHERE receipt.id = inspection.receipt_id
                                AND receipt.status = 1
                                AND receipt.is_deleted = FALSE))
                      )
                )
                SELECT analysis.id, analysis.maker_id
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted = FALSE
                  AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND analysis.warehouse_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_materials material
                      JOIN passed_dimension dimension
                        ON dimension.warehouse_id = analysis.warehouse_id
                       AND dimension.goods_id = material.goods_id
                       AND dimension.color_id
                           IS NOT DISTINCT FROM material.color_id
                      WHERE material.analysis_id = analysis.id
                        AND material.active = TRUE)
                ORDER BY analysis.id
                FOR UPDATE OF analysis
                """)
                .setParameter("sourceType", sourceType)
                .setParameter("sourceDocumentId", receiptId)
                .setParameter("inspectionItemIds", inspectionItemIds));
    }

    private List<AnalysisTarget> purchaseTargets(
            UUID receiptId, boolean includeLegacyFallback) {
        return analysisTargets(em.createNativeQuery("""
                WITH dimensions AS (
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
                )
                SELECT analysis.id, analysis.maker_id
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted = FALSE
                  AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND analysis.warehouse_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_materials material
                      JOIN dimensions dimension
                        ON dimension.warehouse_id = analysis.warehouse_id
                       AND dimension.goods_id = material.goods_id
                       AND dimension.color_id
                           IS NOT DISTINCT FROM material.color_id
                      WHERE material.analysis_id = analysis.id
                        AND material.active = TRUE)
                ORDER BY analysis.id
                FOR UPDATE OF analysis
                """)
                .setParameter("sourceDocumentId", receiptId)
                .setParameter("includeLegacyFallback", includeLegacyFallback));
    }

    private List<AnalysisTarget> subcontractTargets(
            UUID receiptId, boolean includeLegacyFallback) {
        return analysisTargets(em.createNativeQuery("""
                WITH dimensions AS (
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
                )
                SELECT analysis.id, analysis.maker_id
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted = FALSE
                  AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND analysis.warehouse_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_materials material
                      JOIN dimensions dimension
                        ON dimension.warehouse_id = analysis.warehouse_id
                       AND dimension.goods_id = material.goods_id
                       AND dimension.color_id
                           IS NOT DISTINCT FROM material.color_id
                      WHERE material.analysis_id = analysis.id
                        AND material.active = TRUE)
                ORDER BY analysis.id
                FOR UPDATE OF analysis
                """)
                .setParameter("sourceDocumentId", receiptId)
                .setParameter("includeLegacyFallback", includeLegacyFallback));
    }

    private List<AnalysisTarget> finishedInboundTargets(
            UUID stockDocumentId, int requiredStatus) {
        return analysisTargets(em.createNativeQuery("""
                WITH dimensions AS (
                    SELECT DISTINCT document.warehouse_id,
                           item.goods_id, item.color_id
                    FROM stock_documents document
                    JOIN stock_document_items item
                      ON item.doc_id = document.id
                     AND item.is_deleted = FALSE
                    WHERE document.id = :sourceDocumentId
                      AND document.doc_type = 'FINISHED_IN'
                      AND document.status = :requiredStatus
                      AND document.is_deleted = FALSE
                      AND document.warehouse_id IS NOT NULL
                      AND item.goods_id IS NOT NULL
                )
                SELECT analysis.id, analysis.maker_id
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted = FALSE
                  AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND analysis.warehouse_id IS NOT NULL
                  AND EXISTS (
                      SELECT 1
                      FROM production_material_analysis_materials material
                      JOIN dimensions dimension
                        ON dimension.warehouse_id = analysis.warehouse_id
                       AND dimension.goods_id = material.goods_id
                       AND dimension.color_id
                           IS NOT DISTINCT FROM material.color_id
                      WHERE material.analysis_id = analysis.id
                        AND material.active = TRUE)
                ORDER BY analysis.id
                FOR UPDATE OF analysis
                """).setParameter("sourceDocumentId", stockDocumentId)
                .setParameter("requiredStatus", requiredStatus));
    }

    private List<AnalysisTarget> analysisTargets(Query query) {
        return NativeQueryResults.objectArrayRows(query).stream()
                .map(row -> new AnalysisTarget((UUID) row[0], (UUID) row[1]))
                .toList();
    }

    /** 按来源类型解析业务单号（采购收货 CJ/委外进仓 EJ/产成品入库 CR）；查不到返回空串。 */
    private String sourceDocumentNo(String sourceType, UUID sourceDocumentId) {
        String table = switch (sourceType) {
            case "PURCHASE" -> "purchase_receipts";
            case "SUBCONTRACT" -> "subcontract_receipts";
            case "MAKE" -> "stock_documents";
            default -> null;
        };
        if (table == null) return "";
        List<?> rows = em.createNativeQuery(
                "SELECT bill_no FROM " + table + " WHERE id = :id")
                .setParameter("id", sourceDocumentId)
                .getResultList();
        return rows.isEmpty() || rows.getFirst() == null
                ? "" : String.valueOf(rows.getFirst());
    }

    private Map<UUID, BigDecimal> readyFinishByOpenItem(UUID analysisId) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, ready_finish_qty
                FROM production_material_analysis_items
                WHERE analysis_id = :analysisId
                  AND is_deleted = FALSE
                  AND requested_qty - submitted_qty - approved_qty > 0
                ORDER BY id
                """).setParameter("analysisId", analysisId))) {
            result.put((UUID) row[0], decimal(row[1]));
        }
        return Map.copyOf(result);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static String quantityText(BigDecimal value) {
        return value.max(BigDecimal.ZERO).stripTrailingZeros().toPlainString();
    }

    record AnalysisTarget(UUID analysisId, UUID makerEmployeeId) {
    }
}
