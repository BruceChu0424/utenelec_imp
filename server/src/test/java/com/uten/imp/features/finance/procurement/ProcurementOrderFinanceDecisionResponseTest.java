package com.uten.imp.features.finance.procurement;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderProgressService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementOrderFinanceDecisionResponseTest {

    @Test
    void submitFinanceStillReturnsOrdinaryOwnerScopedDetail() {
        UUID purchaseId = UUID.randomUUID();
        PurchaseOrderService purchase = mock(PurchaseOrderService.class);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        var purchaseDetail = mock(
                com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        when(purchase.detail(purchaseId)).thenReturn(purchaseDetail);

        assertSame(
                purchaseDetail,
                new PurchaseOrderController(
                        purchase,
                        purchaseApproval,
                        mock(AuditDetailViewRecorder.class))
                        .submitFinance(purchaseId));
        verify(purchaseApproval).submit("PURCHASE", purchaseId);

        UUID subcontractId = UUID.randomUUID();
        SubcontractOrderService subcontract = mock(SubcontractOrderService.class);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        var subcontractDetail = mock(
                com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(subcontract.detail(subcontractId)).thenReturn(subcontractDetail);

        assertSame(
                subcontractDetail,
                new SubcontractOrderController(
                        subcontract,
                        subcontractApproval,
                        mock(SubcontractOrderProgressService.class),
                        mock(AuditDetailViewRecorder.class))
                        .submitFinance(subcontractId));
        verify(subcontractApproval).submit("SUBCONTRACT", subcontractId);
    }
}
