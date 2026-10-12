package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionInspectionStockInPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** Preserves receipt-level supply provenance while refreshing each affected analysis once. */
@Service
@RequiredArgsConstructor
public class ProductionInspectionStockInService implements ProductionInspectionStockInPort {
    private final ProductionPurchaseSupplyTransitionService purchaseSupply;
    private final ProductionSubcontractSupplyTransitionService subcontractSupply;
    private final MaterialAnalysisSupplyWakeupService materialAnalysisWakeup;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches) {
        if (batches.isEmpty()) return;
        advanceBatches(batches);
        materialAnalysisWakeup.afterInspectionStockInConfirmed(batches);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterQualityReceiptResolved(String receiptType, UUID receiptId, List<ReceiptStockIn> batches) {
        advanceQualityReceipt(receiptType, receiptId, batches);
        if (!batches.isEmpty()) materialAnalysisWakeup.notifyInspectionStockIn(batches);
        switch (receiptType) {
            case "PURCHASE" -> materialAnalysisWakeup.afterPurchaseReceiptApproved(receiptId);
            case "SUBCONTRACT" -> materialAnalysisWakeup.afterSubcontractReceiptApproved(receiptId);
            default -> throw new IllegalStateException("Validated receipt type changed");
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void withQualityReport(java.util.function.Consumer<QualityReport> work) {
        var owner = org.springframework.transaction.interceptor.TransactionAspectSupport.currentTransactionStatus();
        QualityReportFollowupScope.run(new QualityReport() {
            @Override public void afterQualityReceiptResolved(String type, UUID receipt, List<ReceiptStockIn> batches) {
                advanceQualityReceipt(type, receipt, batches);
                // Keep each original batch's notice identity and its position relative to source advancement.
                if (!batches.isEmpty()) materialAnalysisWakeup.notifyInspectionStockIn(batches);
            }
            @Override public void afterInspectionStockInConfirmed(List<ReceiptStockIn> batches) {
                advanceBatches(batches);
                materialAnalysisWakeup.notifyInspectionStockIn(batches);
            }
        }, materialAnalysisWakeup::afterQualityReportCompleted, owner::setRollbackOnly, work);
    }

    private void advanceQualityReceipt(String receiptType, UUID receiptId, List<ReceiptStockIn> batches) {
        if (receiptId == null || !("PURCHASE".equals(receiptType) || "SUBCONTRACT".equals(receiptType))
                || batches.stream().anyMatch(batch -> !receiptType.equals(batch.receiptType())
                        || !receiptId.equals(batch.receiptId()))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "品质结案与自动入库的收货来源不一致");
        }
        if (batches.isEmpty()) {
            advanceReceipt(receiptType, receiptId, null);
        } else {
            advanceBatches(batches);
        }
    }

    private void advanceBatches(List<ReceiptStockIn> batches) {
        for (ReceiptStockIn batch : batches) {
            advanceReceipt(batch.receiptType(), batch.receiptId(), batch.batchId());
        }
    }

    private void advanceReceipt(String receiptType, UUID receiptId, UUID batchId) {
        switch (receiptType) {
            case "PURCHASE" -> purchaseSupply.advanceInspectionStockInState(receiptId, batchId);
            case "SUBCONTRACT" -> subcontractSupply.advanceInspectionStockInState(receiptId);
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "入库生产联动的收货类型不正确");
        }
    }
}
