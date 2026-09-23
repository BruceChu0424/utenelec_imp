package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
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
    private final com.uten.imp.features.notice.ChainNoticeService chainNotices;

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
        afterInspectionStockInConfirmed(batches, true);
    }

    /**
     * {@code refreshAnalyses=false}：只发到货进展通知，不刷分析。仅供「整单在同一次品质结论里结案」的
     * 自动转正调用——结案回调随后按整单 RESOLVED 维度(是本批维度的超集)刷新同一批分析，
     * 同一事务里先刷一遍是白算(2026-09-21 品质批量审批提速)。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches, boolean refreshAnalyses) {
        if (refreshAnalyses) {
            Map<UUID, UUID> makers = new TreeMap<>();
            for (AnalysisTarget target : inspectionStockInTargets(batches)) {
                makers.put(target.analysisId(), target.makerEmployeeId());
            }
            List<AnalysisTarget> targets = new ArrayList<>(makers.size());
            makers.forEach((analysisId, makerEmployeeId) ->
                    targets.add(new AnalysisTarget(analysisId, makerEmployeeId)));
            refreshTargets(targets);
        }
        // 到货进展通知(V599)：这次真的写进库存的量，按维度命中还在等待的车间工单发聚合卡。
        notifyWaitingSegmentsAboutArrival(
                "IQC:" + triggerFingerprint(batches == null ? List.of() : batches.stream()
                        .map(ReceiptStockIn::batchId).toList()),
                iqcArrivalDimensions(batches), "IQC_STOCK_IN", batches == null ? List.of() :
                        batches.stream().map(ReceiptStockIn::batchId).filter(java.util.Objects::nonNull).distinct().toList());
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
                    SELECT DISTINCT actual.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    CROSS JOIN LATERAL (
                        SELECT inspection.warehouse_id WHERE inspection.warehouse_id IS NOT NULL
                        UNION SELECT stock.warehouse_id FROM procurement_iqc_stock_in_batch_items stock
                        WHERE stock.inspection_item_id=inspection.id
                    ) actual
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
        // 单张审核与批量点收同一入口：都触达货进展(数量口径一致，见 triggerFingerprint)。
        afterFinishedInboundApproved(List.of(stockDocumentId));
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(Collection<UUID> stockDocumentIds) {
        refreshTargets(finishedInboundTargets(stockDocumentIds, 1));
        notifyWaitingSegmentsAboutArrival(
                "FIN:" + triggerFingerprint(stockDocumentIds),
                finishedInboundArrivalDimensions(stockDocumentIds), "FINISHED_IN", stockDocumentIds);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundReversed(UUID stockDocumentId) {
        refreshTargets(finishedInboundTargets(stockDocumentId, -1));
        notifyWaitingSegmentsAboutArrival("FIN-REVERSE:" + stockDocumentId,
                finishedInboundSourceDimensions(List.of(stockDocumentId), -1), "CURRENT_STATE", List.of());
    }

    private void refreshReceipt(
            String sourceType,
            UUID receiptId,
            boolean includeLegacyFallback) {
        List<AnalysisTarget> targets = "PURCHASE".equals(sourceType)
                ? purchaseTargets(receiptId, includeLegacyFallback)
                : subcontractTargets(receiptId, includeLegacyFallback);
        refreshTargets(targets);
        if (includeLegacyFallback) {
            notifyWaitingSegmentsAboutArrival(sourceType + "-REVERSE:" + receiptId,
                    reversedReceiptDimensions(sourceType, receiptId), "CURRENT_STATE", List.of());
        }
    }

    private void refreshTargets(List<AnalysisTarget> targets) {
        if (!targets.isEmpty()) {
            // 被唤醒的分析在本事务预锁时已整体展开并复核过, 这里只在内存里确认覆盖(ADR-107)。
            mutationLocks.requireAnalysesCovered(targets.stream().map(AnalysisTarget::analysisId).toList());
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
                    SELECT DISTINCT actual.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    CROSS JOIN LATERAL (
                        SELECT inspection.warehouse_id WHERE inspection.warehouse_id IS NOT NULL
                        UNION SELECT stock.warehouse_id FROM procurement_iqc_stock_in_batch_items stock
                        WHERE stock.inspection_item_id=inspection.id
                    ) actual
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
                    SELECT DISTINCT actual.warehouse_id,
                           inspection.goods_id, inspection.color_id
                    FROM procurement_inspection_items inspection
                    CROSS JOIN LATERAL (
                        SELECT inspection.warehouse_id WHERE inspection.warehouse_id IS NOT NULL
                        UNION SELECT stock.warehouse_id FROM procurement_iqc_stock_in_batch_items stock
                        WHERE stock.inspection_item_id=inspection.id
                    ) actual
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
                    -- 线边仓(车间直送)的完工入库不进公共可用量，不唤醒任何分析(V595)。
                    JOIN warehouses source_warehouse
                      ON source_warehouse.id = document.warehouse_id
                     AND source_warehouse.is_line_side = FALSE
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

    private static String joinedIds(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) {
            return "";
        }
        return ids.stream()
                .filter(java.util.Objects::nonNull)
                .map(UUID::toString)
                .sorted()
                .collect(java.util.stream.Collectors.joining(","));
    }

    /**
     * 去重键指纹：业务事件的触发单据集合压成 SHA-256 摘要。不能直接拼 UUID 列表——
     * business_outbox.dedupe_key 只有 VARCHAR(240)，批量入库/批量质检处置一次可达
     * 5-20 张单，裸拼 4 个 UUID 就超长并炸掉整笔入库事务。
     */
    private static String triggerFingerprint(Collection<UUID> ids) {
        String joined = joinedIds(ids);
        if (joined.isEmpty()) {
            return "";
        }
        return PlanningPackageFingerprint.sha256(List.of(joined)).substring(0, 32);
    }

    /** IQC 确认入库的到货维度(V599)：仓×货品×颜色 → 本次入库基础量(只算真写进库存的)。 */
    private List<Object[]> iqcArrivalDimensions(List<ReceiptStockIn> batches) {
        if (batches == null || batches.isEmpty()) {
            return List.of();
        }
        List<UUID> batchIds = batches.stream()
                .map(ReceiptStockIn::batchId)
                .filter(java.util.Objects::nonNull)
                .distinct()
                .sorted()
                .toList();
        if (batchIds.isEmpty()) {
            return List.of();
        }
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT stock.warehouse_id, stock.goods_id, stock.color_id,
                       SUM(stock.base_qty), goods.name, goods.code, COALESCE(color.name, '')
                FROM procurement_iqc_stock_in_batch_items stock
                JOIN goods ON goods.id = stock.goods_id
                LEFT JOIN colors color ON color.id = stock.color_id
                WHERE stock.batch_id IN (:batchIds)
                GROUP BY stock.warehouse_id, stock.goods_id, stock.color_id,
                         goods.name, goods.code, color.name
                ORDER BY goods.name, goods.code
                """).setParameter("batchIds", batchIds));
    }

    /** Reversal keeps original physical dimensions even though the source is no longer available. */
    private List<Object[]> reversedReceiptDimensions(String sourceType, UUID receiptId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT stock.warehouse_id, stock.goods_id, stock.color_id,
                       SUM(stock.base_qty), goods.name, goods.code, COALESCE(color.name, '')
                FROM procurement_iqc_stock_in_batch_items stock
                JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
                JOIN goods ON goods.id=stock.goods_id
                LEFT JOIN colors color ON color.id=stock.color_id
                WHERE inspection.receipt_type=:sourceType AND inspection.receipt_id=:receiptId
                GROUP BY stock.warehouse_id,stock.goods_id,stock.color_id,goods.name,goods.code,color.name
                ORDER BY goods.name,goods.code
                """).setParameter("sourceType", sourceType).setParameter("receiptId", receiptId));
    }

    /** 自制产成品入库的到货维度(V599)：线边仓(车间直送)不进公共可用量，不算到货进展。 */
    private List<Object[]> finishedInboundArrivalDimensions(Collection<UUID> stockDocumentIds) {
        return finishedInboundSourceDimensions(stockDocumentIds, 1);
    }

    private List<Object[]> finishedInboundSourceDimensions(Collection<UUID> stockDocumentIds, int status) {
        if (stockDocumentIds == null || stockDocumentIds.isEmpty()) {
            return List.of();
        }
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT document.warehouse_id, item.goods_id, item.color_id,
                       SUM(COALESCE(item.base_qty, item.qty * COALESCE(item.unit_rate, 1))),
                       goods.name, goods.code, COALESCE(color.name, '')
                FROM stock_documents document
                JOIN stock_document_items item
                  ON item.doc_id = document.id
                 AND item.is_deleted = FALSE
                JOIN goods ON goods.id = item.goods_id
                LEFT JOIN colors color ON color.id = item.color_id
                JOIN warehouses source_warehouse
                  ON source_warehouse.id = document.warehouse_id
                 AND source_warehouse.is_line_side = FALSE
                WHERE document.id IN (:documentIds)
                  AND document.doc_type = 'FINISHED_IN'
                  AND document.status = :status
                  AND document.is_deleted = FALSE
                  AND document.warehouse_id IS NOT NULL
                  AND item.goods_id IS NOT NULL
                GROUP BY document.warehouse_id, item.goods_id, item.color_id,
                         goods.name, goods.code, color.name
                ORDER BY goods.name, goods.code
                """).setParameter("documentIds",
                stockDocumentIds.stream().distinct().sorted().toList()).setParameter("status", status));
    }

    /** Match exact goods/color and main-warehouse scope; page every affected task. */
    private void notifyWaitingSegmentsAboutArrival(
            String triggerKey, List<Object[]> dimensions, String evidenceType, Collection<UUID> evidenceIds) {
        if (dimensions == null || dimensions.isEmpty()) return;
        List<Map<String,Object>> arrivals = new ArrayList<>();
        for (Object[] dimension : dimensions) {
            Map<String,Object> value = new java.util.LinkedHashMap<>();
            value.put("warehouse_id", dimension[0]);
            value.put("goods_id", dimension[1]);
            value.put("color_id", dimension[2]);
            value.put("quantity", dimension[3]);
            value.put("goods_name", dimension[4]);
            value.put("goods_code", dimension[5]);
            value.put("color_name", dimension[6]);
            arrivals.add(value);
        }
        String payload = new com.fasterxml.jackson.databind.ObjectMapper().valueToTree(arrivals).toString();
        UUID after = new UUID(0,0);
        while (true) {
            List<Object[]> targets = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    WITH arrivals AS (
                        SELECT * FROM jsonb_to_recordset(CAST(:arrivals AS jsonb))
                        AS a(warehouse_id uuid, goods_id uuid, color_id uuid, quantity numeric,
                             goods_name text, goods_code text, color_name text)
                    ), matches AS (
                        SELECT DISTINCT segment.id, a.goods_id, a.color_id, a.warehouse_id,
                               a.goods_name, a.goods_code, a.color_name, a.quantity
                        FROM arrivals a
                        JOIN production_material_demands demand
                          ON demand.goods_id=a.goods_id
                         AND demand.color_id IS NOT DISTINCT FROM a.color_id
                         AND NOT demand.is_deleted AND demand.status NOT IN ('RELEASED','REVERSED')
                         AND (:reversed OR demand.status <> 'FULFILLED')
                         AND fn_warehouse_same_main(demand.warehouse_id,a.warehouse_id)
                        JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                         AND NOT segment.is_deleted AND segment.workshop_department_id IS NOT NULL
                         AND segment.status IN ('WAITING','READY','DISPATCHED','IN_PROGRESS')
                         AND (:reversed OR segment.status='WAITING' OR segment.continuous_supply)
                        JOIN production_planning_packages package ON package.id=segment.package_id
                         AND package.status='CONFIRMED' AND NOT package.is_deleted
                        WHERE segment.id>CAST(:after AS uuid)
                    ), page AS (
                        SELECT id FROM matches GROUP BY id ORDER BY id LIMIT 200
                    ), ranked AS (
                        SELECT matches.*, row_number() OVER (PARTITION BY matches.id
                            ORDER BY goods_name,goods_id,color_id,warehouse_id) AS position
                        FROM matches JOIN page USING(id)
                    )
                    SELECT id, '本次合格入库：' || string_agg(
                        goods_name || ' ' || goods_code ||
                        CASE WHEN COALESCE(color_name,'')='' THEN '' ELSE '(' || color_name || ')' END
                        || ' ' || trim_scale(quantity)::text || '（基本单位）', '、' ORDER BY position) FILTER(WHERE position<=6)
                        || CASE WHEN count(*)>6 THEN '；共 ' || count(*) || ' 项' ELSE '' END
                        || '（仓库本次实收量，本单可领量以领料核对为准）'
                    FROM ranked GROUP BY id ORDER BY id
                    """).setParameter("arrivals",payload).setParameter("after",after)
                    .setParameter("reversed", "CURRENT_STATE".equals(evidenceType)));
            if ("CURRENT_STATE".equals(evidenceType)) {
                chainNotices.resolveProductionWorkshopTasks(targets.stream().map(row -> (UUID) row[0]).toList(),
                        "SOURCE_REVERSED");
            }
            for (Object[] target : targets) {
                chainNotices.notifyWorkshopMaterialArrival((UUID)target[0], triggerKey,
                        "CURRENT_STATE".equals(evidenceType) ? "物料来源已撤回，请核对当前任务" : (String)target[1],
                        evidenceType, evidenceIds);
            }
            if (targets.size()<200) return;
            after=(UUID)targets.getLast()[0];
        }
    }
    record AnalysisTarget(UUID analysisId, UUID makerEmployeeId) {
    }
}
