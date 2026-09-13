package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.mockito.Mockito.*;

class ProductionInspectionStockInServiceTest {
    @Test
    void mixedReceiptsAdvanceBeforeTheSingleAnalysisRefresh() {
        var purchase = mock(ProductionPurchaseSupplyTransitionService.class);
        var subcontract = mock(ProductionSubcontractSupplyTransitionService.class);
        var wakeup = mock(MaterialAnalysisSupplyWakeupService.class);
        var service = new ProductionInspectionStockInService(purchase, subcontract, wakeup);
        var first = new ReceiptStockIn("PURCHASE", UUID.randomUUID(), UUID.randomUUID(), List.of(UUID.randomUUID()));
        var second = new ReceiptStockIn("SUBCONTRACT", UUID.randomUUID(), UUID.randomUUID(), List.of(UUID.randomUUID()));
        var batches = List.of(first, second);

        service.afterInspectionStockInConfirmed(batches);

        var order = inOrder(purchase, subcontract, wakeup);
        order.verify(purchase).advanceInspectionStockInState(first.receiptId(), first.batchId());
        order.verify(subcontract).advanceInspectionStockInState(second.receiptId());
        order.verify(wakeup).afterInspectionStockInConfirmed(batches);
        verifyNoMoreInteractions(purchase, subcontract, wakeup);
    }
}
