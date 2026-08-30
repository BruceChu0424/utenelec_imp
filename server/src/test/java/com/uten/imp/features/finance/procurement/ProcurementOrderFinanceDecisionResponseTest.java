package com.uten.imp.features.finance.procurement;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalDecisionRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.RejectionDecisionRequest;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.purchase.order.PurchaseOrderFinanceDecisionCommandService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderFinanceDecisionCommandService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementOrderFinanceDecisionResponseTest {

    @Test
    void approveDelegatesToTransactionalDecisionCommandForBothOrderTypes() {
        UUID purchaseId = UUID.randomUUID();
        PurchaseOrderService purchase = mock(PurchaseOrderService.class);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        PurchaseOrderFinanceDecisionCommandService purchaseDecision =
                mock(PurchaseOrderFinanceDecisionCommandService.class);
        var purchaseDetail = mock(
                com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        when(purchaseDecision.approve(purchaseId, 3L)).thenReturn(purchaseDetail);

        assertSame(purchaseDetail,
                new PurchaseOrderController(
                        purchase,
                        purchaseApproval,
                        purchaseDecision,
                        mock(AuditDetailViewRecorder.class))
                        .approve(purchaseId, new ApprovalDecisionRequest(3L)));
        verify(purchaseDecision).approve(purchaseId, 3L);
        verify(purchaseApproval, never()).approve("PURCHASE", purchaseId, 3L);

        UUID subcontractId = UUID.randomUUID();
        SubcontractOrderService subcontract = mock(SubcontractOrderService.class);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderFinanceDecisionCommandService subcontractDecision =
                mock(SubcontractOrderFinanceDecisionCommandService.class);
        var subcontractDetail = mock(
                com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(subcontractDecision.approve(subcontractId, 4L))
                .thenReturn(subcontractDetail);

        assertSame(subcontractDetail,
                new SubcontractOrderController(
                        subcontract, subcontractApproval, subcontractDecision,
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderProgressService.class),
                        mock(AuditDetailViewRecorder.class))
                        .approve(subcontractId, new ApprovalDecisionRequest(4L)));
        verify(subcontractDecision).approve(subcontractId, 4L);
        verify(subcontractApproval, never())
                .approve("SUBCONTRACT", subcontractId, 4L);
    }

    @Test
    void rejectDelegatesToTransactionalDecisionCommandForBothOrderTypes() {
        UUID purchaseId = UUID.randomUUID();
        PurchaseOrderService purchase = mock(PurchaseOrderService.class);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        PurchaseOrderFinanceDecisionCommandService purchaseDecision =
                mock(PurchaseOrderFinanceDecisionCommandService.class);
        var purchaseDetail = mock(
                com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        when(purchaseDecision.reject(purchaseId, 5L, "price correction"))
                .thenReturn(purchaseDetail);

        assertSame(purchaseDetail,
                new PurchaseOrderController(
                        purchase,
                        purchaseApproval,
                        purchaseDecision,
                        mock(AuditDetailViewRecorder.class))
                        .reject(purchaseId,
                                new RejectionDecisionRequest(
                                        5L, "price correction")));
        verify(purchaseDecision).reject(purchaseId, 5L, "price correction");
        verify(purchaseApproval, never()).reject(
                "PURCHASE", purchaseId, 5L, "price correction");

        UUID subcontractId = UUID.randomUUID();
        SubcontractOrderService subcontract = mock(SubcontractOrderService.class);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderFinanceDecisionCommandService subcontractDecision =
                mock(SubcontractOrderFinanceDecisionCommandService.class);
        var subcontractDetail = mock(
                com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(subcontractDecision.reject(
                subcontractId, 6L, "supplier correction"))
                .thenReturn(subcontractDetail);

        assertSame(subcontractDetail,
                new SubcontractOrderController(
                        subcontract, subcontractApproval, subcontractDecision,
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderProgressService.class),
                        mock(AuditDetailViewRecorder.class))
                        .reject(subcontractId,
                                new RejectionDecisionRequest(
                                        6L, "supplier correction")));
        verify(subcontractDecision).reject(
                subcontractId, 6L, "supplier correction");
        verify(subcontractApproval, never()).reject(
                "SUBCONTRACT", subcontractId, 6L, "supplier correction");
    }

    @Test
    void submitFinanceStillReturnsOrdinaryOwnerScopedDetail() {
        UUID purchaseId = UUID.randomUUID();
        PurchaseOrderService purchase = mock(PurchaseOrderService.class);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        PurchaseOrderFinanceDecisionCommandService purchaseDecision =
                mock(PurchaseOrderFinanceDecisionCommandService.class);
        var purchaseDetail = mock(
                com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        when(purchase.detail(purchaseId)).thenReturn(purchaseDetail);

        assertSame(purchaseDetail,
                new PurchaseOrderController(
                        purchase,
                        purchaseApproval,
                        purchaseDecision,
                        mock(AuditDetailViewRecorder.class))
                        .submitFinance(purchaseId));
        verify(purchaseApproval).submit("PURCHASE", purchaseId);
        verify(purchaseDecision, never()).approve(purchaseId, 1L);

        UUID subcontractId = UUID.randomUUID();
        SubcontractOrderService subcontract = mock(SubcontractOrderService.class);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderFinanceDecisionCommandService subcontractDecision =
                mock(SubcontractOrderFinanceDecisionCommandService.class);
        var subcontractDetail = mock(
                com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(subcontract.detail(subcontractId)).thenReturn(subcontractDetail);

        assertSame(subcontractDetail,
                new SubcontractOrderController(
                        subcontract, subcontractApproval, subcontractDecision,
                        mock(com.uten.imp.features.subcontract.order.SubcontractOrderProgressService.class),
                        mock(AuditDetailViewRecorder.class))
                        .submitFinance(subcontractId));
        verify(subcontractApproval).submit("SUBCONTRACT", subcontractId);
        verify(subcontractDecision, never()).approve(subcontractId, 1L);
    }
}
