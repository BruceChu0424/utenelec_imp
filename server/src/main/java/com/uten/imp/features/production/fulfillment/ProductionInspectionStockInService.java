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
        for (ReceiptStockIn batch : batches) {
            switch (batch.receiptType()) {
                case "PURCHASE" -> purchaseSupply.advanceInspectionStockInState(
                        batch.receiptId(), batch.batchId());
                case "SUBCONTRACT" -> subcontractSupply.advanceInspectionStockInState(
                        batch.receiptId());
                default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "入库生产联动的收货类型无效");
            }
        }
        // Run after every source has advanced, so mixed purchase/subcontract receipts
        // cannot repeatedly rebuild the same analysis from intermediate batch states.
        materialAnalysisWakeup.afterInspectionStockInConfirmed(batches);
    }
}
