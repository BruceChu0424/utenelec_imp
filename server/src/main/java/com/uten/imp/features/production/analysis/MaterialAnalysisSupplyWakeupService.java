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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
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
                "MAKE", stockDocumentId, finishedInboundTargets(stockDocumentId, 1), true);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundReversed(UUID stockDocumentId) {
        refreshTargets(
                "MAKE", stockDocumentId, finishedInboundTargets(stockDocumentId, -1), false);
    }

    private void refreshReceipt(
            String sourceType,
            UUID receiptId,
            boolean includeLegacyFallback,
            boolean publishIncrease) {
        List<AnalysisTarget> targets = "PURCHASE".equals(sourceType)
                ? purchaseTargets(receiptId, includeLegacyFallback)
                : subcontractTargets(receiptId, includeLegacyFallback);
        refreshTargets(sourceType, receiptId, targets, publishIncrease);
    }

    private void refreshTargets(
            String sourceType,
            UUID sourceDocumentId,
            List<AnalysisTarget> targets,
            boolean publishIncrease) {
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
            for (Map.Entry<UUID, BigDecimal> entry : after.entrySet()) {
                UUID analysisItemId = entry.getKey();
                BigDecimal previous = before.getOrDefault(
                        analysisItemId, BigDecimal.ZERO);
                BigDecimal delta = entry.getValue().subtract(previous);
                if (delta.signum() <= 0) continue;
                Map<String, String> payload = Map.of(
                        "makerEmployeeId", target.makerEmployeeId().toString(),
                        "sourceType", sourceType,
                        "sourceDocumentId", sourceId,
                        "analysisItemId", analysisItemId.toString(),
                        "readyFinishDelta", quantityText(delta),
                        "readyFinishQty", quantityText(entry.getValue()));
                events.publishOnce(
                        EVENT_READY,
                        AGGREGATE_TYPE,
                        target.analysisId(),
                        payload,
                        EVENT_READY + ':' + target.analysisId() + ':'
                                + analysisItemId + ':' + sourceType + ':' + sourceId);
            }
        }
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
