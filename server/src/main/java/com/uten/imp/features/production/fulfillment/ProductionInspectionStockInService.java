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
        if (receiptId == null || !("PURCHASE".equals(receiptType) || "SUBCONTRACT".equals(receiptType))
                || batches.stream().anyMatch(batch -> !receiptType.equals(batch.receiptType())
                        || !receiptId.equals(batch.receiptId()))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "品质结案与自动入库的收货来源不一致");
        }
        if (batches.isEmpty()) {
            advanceReceipt(receiptType, receiptId, null);
        } else {
            advanceBatches(batches);
            materialAnalysisWakeup.notifyInspectionStockIn(batches);
        }
        switch (receiptType) {
            case "PURCHASE" -> materialAnalysisWakeup.afterPurchaseReceiptApproved(receiptId);
            case "SUBCONTRACT" -> materialAnalysisWakeup.afterSubcontractReceiptApproved(receiptId);
            default -> throw new IllegalStateException("Validated receipt type changed");
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
