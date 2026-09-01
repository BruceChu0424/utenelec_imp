package com.uten.imp.features.finance.procurement;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderProgressService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementOrderFinanceDecisionResponseTest {

    @Test
    @SuppressWarnings("removal")
    void legacySingleDecisionEndpointsFailClosedForBothOrderTypes() {
        PurchaseOrderService purchase = mock(PurchaseOrderService.class);
        ProcurementFinanceApprovalService purchaseApproval =
                mock(ProcurementFinanceApprovalService.class);
        PurchaseOrderController purchaseController = new PurchaseOrderController(
                purchase,
                purchaseApproval,
                mock(AuditDetailViewRecorder.class));

        assertLegacyDecisionDisabled(
                assertThrows(ApiException.class,
                        () -> purchaseController.approve(UUID.randomUUID())));
        assertLegacyDecisionDisabled(
                assertThrows(ApiException.class,
                        () -> purchaseController.reject(UUID.randomUUID())));
        verifyNoInteractions(purchase, purchaseApproval);

        SubcontractOrderService subcontract = mock(SubcontractOrderService.class);
        ProcurementFinanceApprovalService subcontractApproval =
                mock(ProcurementFinanceApprovalService.class);
        SubcontractOrderProgressService progress =
                mock(SubcontractOrderProgressService.class);
        SubcontractOrderController subcontractController =
                new SubcontractOrderController(
                        subcontract,
                        subcontractApproval,
                        progress,
                        mock(AuditDetailViewRecorder.class));

        assertLegacyDecisionDisabled(
                assertThrows(ApiException.class,
                        () -> subcontractController.approve(UUID.randomUUID())));
        assertLegacyDecisionDisabled(
                assertThrows(ApiException.class,
                        () -> subcontractController.reject(UUID.randomUUID())));
        verifyNoInteractions(subcontract, subcontractApproval, progress);
    }

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

    private static void assertLegacyDecisionDisabled(ApiException error) {
        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("订货审批任务中心"));
    }
}
