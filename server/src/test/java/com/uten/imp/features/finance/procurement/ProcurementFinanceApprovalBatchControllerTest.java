package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchApprovalRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchRejectionRequest;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementFinanceApprovalBatchControllerTest {

    @Test
    void forwardsKeywordAndTypeToThePagedTaskQuery() {
        ProcurementFinanceApprovalService service =
                mock(ProcurementFinanceApprovalService.class);
        ProcurementFinanceApprovalController controller =
                new ProcurementFinanceApprovalController(service);
        @SuppressWarnings("unchecked")
        PageResponse<ProcurementApprovalContracts.ApprovalTask> response =
                mock(PageResponse.class);
        when(service.tasks(2, 30, "PURCHASE", "供应商A"))
                .thenReturn(response);

        assertSame(
                response,
                controller.tasks(2, 30, "PURCHASE", "供应商A"));
        verify(service).tasks(2, 30, "PURCHASE", "供应商A");
    }

    @Test
    void delegatesCaseBoundApproveAndRejectBatches() {
        ProcurementFinanceApprovalService service =
                mock(ProcurementFinanceApprovalService.class);
        ProcurementFinanceApprovalController controller =
                new ProcurementFinanceApprovalController(service);
        List<BatchDecisionItem> items = List.of(
                new BatchDecisionItem(UUID.randomUUID(), 3L),
                new BatchDecisionItem(UUID.randomUUID(), 4L));
        BatchDecisionResponse approved =
                new BatchDecisionResponse(2, List.of());
        BatchDecisionResponse rejected =
                new BatchDecisionResponse(2, List.of());
        when(service.approveBatch(items, null)).thenReturn(approved);
        when(service.approveBatch(items, "留意供应商账期")).thenReturn(approved);
        when(service.rejectBatch(items, "统一原因")).thenReturn(rejected);

        assertSame(
                approved,
                controller.approveBatch(new BatchApprovalRequest(items, null)));
        assertSame(
                approved,
                controller.approveBatch(
                        new BatchApprovalRequest(items, "留意供应商账期")));
        assertSame(
                rejected,
                controller.rejectBatch(
                        new BatchRejectionRequest(items, "统一原因")));

        verify(service).approveBatch(items, null);
        verify(service).approveBatch(items, "留意供应商账期");
        verify(service).rejectBatch(items, "统一原因");
    }

    @Test
    void reviewEndpointDelegatesToCaseBoundProjection() {
        ProcurementFinanceApprovalService service =
                mock(ProcurementFinanceApprovalService.class);
        ProcurementFinanceApprovalController controller =
                new ProcurementFinanceApprovalController(service);
        UUID caseId = UUID.randomUUID();
        ProcurementApprovalContracts.ApprovalReview review =
                new ProcurementApprovalContracts.ApprovalReview(
                        caseId, "PURCHASE", UUID.randomUUID(), "CG20260001",
                        "PENDING", 1, 1L, List.of("APPROVE"),
                        "提交人", null, null, "供应商A", "S001", null,
                        "人民币", null, "月结", null, null, null, null, null,
                        null, null, null, 0, List.of(), List.of());

        when(service.review(caseId)).thenReturn(review);
        assertSame(review, controller.review(caseId));
        verify(service).review(caseId);
    }

    @Test
    void orderDetailControllersKeepBusinessViewAndFinanceTaskViewGates() throws Exception {
        String purchase = PurchaseOrderController.class
                .getMethod("detail", UUID.class)
                .getAnnotation(PreAuthorize.class)
                .value();
        String subcontract = SubcontractOrderController.class
                .getMethod("detail", UUID.class)
                .getAnnotation(PreAuthorize.class)
                .value();

        assertTrue(purchase.contains("purchase_order:view"));
        assertTrue(purchase.contains("finance_order_approval:view"));
        assertTrue(subcontract.contains("subcontract_order:view"));
        assertTrue(subcontract.contains("finance_order_approval:view"));
    }
}
