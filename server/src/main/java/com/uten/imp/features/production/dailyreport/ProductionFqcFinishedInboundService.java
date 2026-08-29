package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Builds the warehouse draft for one exact FQC PASS decision.
 *
 * <p>The source report, plan line and execution segment are re-read under
 * locks. Mutable numbers or goods names never establish identity.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFqcFinishedInboundService
        implements ProductionFinishedInboundReleasePort {

    private final EntityManager em;
    private final StockDocumentRepository documentRepository;
    private final StockDocumentItemRepository itemRepository;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ChainNoticeService chainNotice;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public CreatedDraft createReleasedDraft(ReleaseRequest request) {
        if (request == null
                || request.inspectionId() == null
                || request.decisionEventId() == null
                || request.sourceReportId() == null
                || request.sourceReportItemId() == null) {
            throw validation("FQC 合格入库缺少来源 UUID");
        }
        BigDecimal quantity = request.quantity();
        if (quantity == null
                || quantity.signum() <= 0
                || quantity.scale() > 4) {
            throw validation("FQC 合格入库数量必须为最多 4 位小数的正数");
        }

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT report.id, report.status,
                               report.warehouse_id, report.bill_no,
                               report.worker_id, report.maker_id,
                               report_item.id, report_item.plan_item_id,
                               report_item.execution_segment_id,
                               report_item.execution_segment_sales_allocation_id,
                               report_item.goods_id, report_item.color_id,
                               report_item.unit_id,
                               COALESCE(report_item.unit_rate, 1),
                               plan_item.plan_id, plan.bill_no,
                               report_item.qty,
                               segment.status,
                               inspection.id,
                               decision.id
                        FROM production_daily_reports report
                        JOIN production_daily_report_items report_item
                          ON report_item.report_id = report.id
                         AND report_item.is_deleted = FALSE
                        JOIN production_plan_items plan_item
                          ON plan_item.id = report_item.plan_item_id
                         AND plan_item.is_deleted = FALSE
                        JOIN production_plans plan
                          ON plan.id = plan_item.plan_id
                         AND plan.is_deleted = FALSE
                        JOIN production_execution_segments segment
                          ON segment.id = report_item.execution_segment_id
                         AND segment.is_deleted = FALSE
                        JOIN production_fqc_inspections inspection
                          ON inspection.id = :inspectionId
                         AND inspection.source_report_id = report.id
                         AND inspection.source_report_item_id = report_item.id
                        JOIN production_fqc_decision_events decision
                          ON decision.id = :decisionEventId
                         AND decision.inspection_id = inspection.id
                         AND decision.pass_qty = :quantity
                        WHERE report.id = :reportId
                          AND report_item.id = :reportItemId
                          AND report.status = 1
                          AND report.is_deleted = FALSE
                          AND report.warehouse_id IS NOT NULL
                          AND report.maker_id IS NOT NULL
                          AND plan.status = 1
                          AND plan.is_closed = FALSE
                          AND plan.is_canceled = FALSE
                          AND plan.is_stopped = FALSE
                          AND segment.status = 'IN_PROGRESS'
                        FOR UPDATE OF report, report_item, plan_item,
                                      plan, segment, inspection, decision
                        """)
                .setParameter("inspectionId", request.inspectionId())
                .setParameter("decisionEventId", request.decisionEventId())
                .setParameter("quantity", quantity)
                .setParameter("reportId", request.sourceReportId())
                .setParameter("reportItemId", request.sourceReportItemId())
                .getResultList();
        if (rows.size() != 1) {
            throw conflict(
                    "FQC 合格放行与报工、计划或执行段状态不一致，未生成入库任务");
        }
        Object[] row = rows.getFirst();
        UUID planId = (UUID) row[14];
        UUID goodsId = (UUID) row[10];
        BigDecimal unitRate = (BigDecimal) row[13];
        if (unitRate.signum() <= 0) {
            throw conflict("报工单位换算率无效，禁止生成合格入库");
        }

        StockDocument document = new StockDocument();
        document.setDocType("FINISHED_IN");
        document.setBillNo(docNumberService.nextNumber(
                DocNumberPrefix.STOCK_FINISHED_IN));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId((UUID) row[2]);
        document.setPlanNo((String) row[15]);
        document.setSourceDailyReportId((UUID) row[0]);
        document.setSourceDocNo((String) row[3]);
        document.setRemark(
                "FQC 合格放行 · 报工 " + row[3]);
        document.setWorkerId(
                row[4] == null ? (UUID) row[5] : (UUID) row[4]);
        document.setMakerId((UUID) row[5]);
        document.setStatus((short) 0);
        documentRepository.saveAndFlush(document);

        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        List.of(goodsId),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        StockDocumentItem item = new StockDocumentItem();
        item.setDocId(document.getId());
        item.setBillType("FINISHED_IN");
        item.setBillNo(document.getBillNo());
        item.setBillDate(document.getBillDate());
        item.setLineNo(1);
        item.setGoodsId(goodsId);
        StockGoodsSnapshot.require(
                        goodsSnapshots, goodsId, "FQC 合格入库明细")
                .applyTo(item, null);
        item.setColorId((UUID) row[11]);
        item.setUnitId((UUID) row[12]);
        item.setUnitRate(unitRate);
        item.setQty(quantity);
        item.setReportedQty(quantity);
        item.setBaseQty(quantity.multiply(unitRate));
        item.setUpstreamItemId((UUID) row[7]);
        item.setExecutionSegmentId((UUID) row[8]);
        item.setExecutionSegmentSalesAllocationId((UUID) row[9]);
        item.setSourceDailyReportItemId((UUID) row[6]);
        item.setSourceDocNo((String) row[3]);
        itemRepository.saveAndFlush(item);

        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(
                            plan_id, draw_id, created_by)
                        VALUES (:planId, :documentId, :actorId)
                        """)
                .setParameter("planId", planId)
                .setParameter("documentId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        chainNotice.notifyFinishedInboundPending(document.getId());
        return new CreatedDraft(document.getId(), item.getId());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
