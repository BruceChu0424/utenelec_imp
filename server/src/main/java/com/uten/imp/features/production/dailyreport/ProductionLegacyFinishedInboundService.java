package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.security.SecurityContextCurrentUser;
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
 * Explicit compatibility path for pre-execution-V1 plan rows.
 *
 * <p>New Flutter workflows cannot create these rows. They have no exact
 * execution segment and therefore cannot be retroactively labelled as FQC.
 * The UUID source and warehouse confirmation rules remain enforced.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionLegacyFinishedInboundService {

    private final EntityManager em;
    private final StockDocumentRepository documentRepository;
    private final StockDocumentItemRepository itemRepository;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final ChainNoticeService chainNotice;

    @Transactional(propagation = Propagation.MANDATORY)
    public void createDraft(
            ProductionDailyReport report,
            UUID planId,
            List<ProductionDailyReportItem> reportItems) {
        if (report == null
                || report.getStatus() == null
                || report.getStatus() != 1
                || report.getWarehouseId() == null
                || planId == null
                || reportItems == null
                || reportItems.isEmpty()
                || reportItems.stream().anyMatch(item ->
                    item.getPlanItemId() == null
                            || item.getExecutionSegmentId() != null)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "旧式完工入库仅允许已审核、无执行段且有精确计划行的历史报工");
        }
        String planNo = (String) em.createNativeQuery("""
                        SELECT bill_no
                        FROM production_plans
                        WHERE id = :id
                          AND is_deleted = FALSE
                        """)
                .setParameter("id", planId)
                .getSingleResult();
        StockDocument document = new StockDocument();
        document.setDocType("FINISHED_IN");
        document.setBillNo(docNumberService.nextNumber(
                DocNumberPrefix.STOCK_FINISHED_IN));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(report.getWarehouseId());
        document.setPlanNo(planNo);
        document.setSourceDailyReportId(report.getId());
        document.setSourceDocNo(report.getBillNo());
        document.setRemark(
                "历史兼容报工 " + report.getBillNo() + " 自动生成");
        document.setWorkerId(
                report.getWorkerId() != null
                        ? report.getWorkerId()
                        : currentUser.requireEmployeeId());
        document.setMakerId(currentUser.requireEmployeeId());
        document.setStatus((short) 0);
        documentRepository.saveAndFlush(document);

        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        reportItems.stream()
                                .map(ProductionDailyReportItem::getGoodsId)
                                .toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        int lineNo = 0;
        for (ProductionDailyReportItem reportItem : reportItems) {
            BigDecimal unitRate = reportItem.getUnitRate() == null
                    ? BigDecimal.ONE
                    : reportItem.getUnitRate();
            if (reportItem.getQty() == null
                    || reportItem.getQty().signum() <= 0
                    || unitRate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "历史兼容报工数量或单位换算率无效");
            }
            StockDocumentItem item = new StockDocumentItem();
            item.setDocId(document.getId());
            item.setBillType("FINISHED_IN");
            item.setBillNo(document.getBillNo());
            item.setBillDate(document.getBillDate());
            item.setLineNo(++lineNo);
            item.setGoodsId(reportItem.getGoodsId());
            StockGoodsSnapshot.require(
                            goodsSnapshots,
                            reportItem.getGoodsId(),
                            "历史兼容完工入库明细")
                    .applyTo(item, null);
            item.setColorId(reportItem.getColorId());
            item.setUnitId(reportItem.getUnitId());
            item.setUnitRate(unitRate);
            item.setQty(reportItem.getQty());
            item.setReportedQty(reportItem.getQty());
            item.setBaseQty(reportItem.getQty().multiply(unitRate));
            item.setUpstreamItemId(reportItem.getPlanItemId());
            item.setSourceDailyReportItemId(reportItem.getId());
            item.setSourceDocNo(report.getBillNo());
            itemRepository.save(item);
        }
        itemRepository.flush();
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
    }
}
