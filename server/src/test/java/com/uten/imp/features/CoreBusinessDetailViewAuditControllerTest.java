package com.uten.imp.features;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportController;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ReportablePlanLineQueryService;
import com.uten.imp.features.production.plan.ProductionPlanController;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionController;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcTaskAccessPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrderController;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptController;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestController;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.ret.PurchaseReturnController;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.stock.StockDocController;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationController;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.inquiry.SubcontractInquiryController;
import com.uten.imp.features.subcontract.inquiry.SubcontractInquiryService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueController;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnController;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.order.SubcontractOrderController;
import com.uten.imp.features.subcontract.order.SubcontractOrderProgressService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptController;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.ret.SubcontractReturnController;
import com.uten.imp.features.subcontract.ret.SubcontractReturnService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteController;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class CoreBusinessDetailViewAuditControllerTest {

    private final AuditDetailViewRecorder recorder =
            mock(AuditDetailViewRecorder.class);

    @Test
    void purchaseDetailsRecordOnlySafeDocumentIdentityAfterSuccessfulLookup() {
        UUID requestId = UUID.randomUUID();
        PurchaseRequestService requestService = mock(PurchaseRequestService.class);
        var request = mock(
                com.uten.imp.features.purchase.request.dto.RequestDetail.class);
        when(request.getBillNo()).thenReturn("CGSQ-001");
        when(request.getLegacyId()).thenReturn(101);
        when(requestService.detail(requestId)).thenReturn(request);
        assertSame(
                request,
                new PurchaseRequestController(requestService, recorder)
                        .detail(requestId));
        verify(recorder).record(
                "view_purchase_request_detail",
                "purchase_requests",
                requestId,
                "CGSQ-001",
                101,
                "采购申请单");

        UUID orderId = UUID.randomUUID();
        PurchaseOrderService orderService = mock(PurchaseOrderService.class);
        var order = mock(
                com.uten.imp.features.purchase.order.dto.OrderDetail.class);
        when(order.getBillNo()).thenReturn("CGDD-002");
        when(order.getLegacyId()).thenReturn(102);
        when(orderService.detail(orderId)).thenReturn(order);
        assertSame(
                order,
                        new PurchaseOrderController(
                                orderService,
                                mock(ProcurementFinanceApprovalService.class),
                                recorder)
                        .detail(orderId));
        verify(recorder).record(
                "view_purchase_order_detail",
                "purchase_orders",
                orderId,
                "CGDD-002",
                102,
                "采购订货单");

        UUID receiptId = UUID.randomUUID();
        PurchaseReceiptService receiptService = mock(PurchaseReceiptService.class);
        var receipt = mock(
                com.uten.imp.features.purchase.receipt.dto.ReceiptDetail.class);
        when(receipt.getBillNo()).thenReturn("CGSH-003");
        when(receipt.getLegacyId()).thenReturn(103);
        when(receiptService.detail(receiptId)).thenReturn(receipt);
        assertSame(
                receipt,
                new PurchaseReceiptController(receiptService, recorder)
                        .detail(receiptId));
        verify(recorder).record(
                "view_purchase_receipt_detail",
                "purchase_receipts",
                receiptId,
                "CGSH-003",
                103,
                "采购收货单");

        UUID returnId = UUID.randomUUID();
        PurchaseReturnService returnService = mock(PurchaseReturnService.class);
        var purchaseReturn = mock(
                com.uten.imp.features.purchase.ret.dto.ReturnDetail.class);
        when(purchaseReturn.getBillNo()).thenReturn("CGTH-004");
        when(purchaseReturn.getLegacyId()).thenReturn(104);
        when(returnService.detail(returnId)).thenReturn(purchaseReturn);
        assertSame(
                purchaseReturn,
                new PurchaseReturnController(returnService, recorder)
                        .detail(returnId));
        verify(recorder).record(
                "view_purchase_return_detail",
                "purchase_returns",
                returnId,
                "CGTH-004",
                104,
                "采购退货单");
    }

    @Test
    void subcontractDetailsRecordOnlySafeDocumentIdentityAfterSuccessfulLookup() {
        UUID applicationId = UUID.randomUUID();
        SubcontractApplicationService applicationService =
                mock(SubcontractApplicationService.class);
        var application = mock(
                com.uten.imp.features.subcontract.application.dto.ApplicationDetail.class);
        when(application.getBillNo()).thenReturn("WWSQ-001");
        when(application.getLegacyId()).thenReturn(201);
        when(applicationService.detail(applicationId)).thenReturn(application);
        assertSame(
                application,
                new SubcontractApplicationController(applicationService, recorder)
                        .detail(applicationId));
        verify(recorder).record(
                "view_subcontract_application_detail",
                "subcontract_applications",
                applicationId,
                "WWSQ-001",
                201,
                "委外申请单");

        UUID inquiryId = UUID.randomUUID();
        SubcontractInquiryService inquiryService =
                mock(SubcontractInquiryService.class);
        var inquiry = mock(
                com.uten.imp.features.subcontract.inquiry.dto.InquiryDetail.class);
        when(inquiry.getBillNo()).thenReturn("WWXJ-002");
        when(inquiry.getLegacyId()).thenReturn(202);
        when(inquiryService.detail(inquiryId)).thenReturn(inquiry);
        assertSame(
                inquiry,
                new SubcontractInquiryController(inquiryService, recorder)
                        .detail(inquiryId));
        verify(recorder).record(
                "view_subcontract_inquiry_detail",
                "subcontract_inquiries",
                inquiryId,
                "WWXJ-002",
                202,
                "委外询价单");

        UUID orderId = UUID.randomUUID();
        SubcontractOrderService orderService = mock(SubcontractOrderService.class);
        var order = mock(
                com.uten.imp.features.subcontract.order.dto.OrderDetail.class);
        when(order.getBillNo()).thenReturn("WWDD-003");
        when(order.getLegacyId()).thenReturn(203);
        when(orderService.detail(orderId)).thenReturn(order);
        assertSame(
                order,
                        new SubcontractOrderController(
                                orderService,
                                mock(ProcurementFinanceApprovalService.class),
                                mock(SubcontractOrderProgressService.class),
                                recorder)
                        .detail(orderId));
        verify(recorder).record(
                "view_subcontract_order_detail",
                "subcontract_orders",
                orderId,
                "WWDD-003",
                203,
                "委外订货单");

        UUID receiptId = UUID.randomUUID();
        SubcontractReceiptService receiptService =
                mock(SubcontractReceiptService.class);
        var receipt = mock(
                com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail.class);
        when(receipt.getBillNo()).thenReturn("WWJC-004");
        when(receipt.getLegacyId()).thenReturn(204);
        when(receiptService.detail(receiptId)).thenReturn(receipt);
        assertSame(
                receipt,
                new SubcontractReceiptController(receiptService, recorder)
                        .detail(receiptId));
        verify(recorder).record(
                "view_subcontract_receipt_detail",
                "subcontract_receipts",
                receiptId,
                "WWJC-004",
                204,
                "委外进仓单");

        UUID returnId = UUID.randomUUID();
        SubcontractReturnService returnService =
                mock(SubcontractReturnService.class);
        var subcontractReturn = mock(
                com.uten.imp.features.subcontract.ret.dto.ReturnDetail.class);
        when(subcontractReturn.getBillNo()).thenReturn("WWTH-005");
        when(subcontractReturn.getLegacyId()).thenReturn(205);
        when(returnService.detail(returnId)).thenReturn(subcontractReturn);
        assertSame(
                subcontractReturn,
                new SubcontractReturnController(returnService, recorder)
                        .detail(returnId));
        verify(recorder).record(
                "view_subcontract_return_detail",
                "subcontract_returns",
                returnId,
                "WWTH-005",
                205,
                "委外退货单");

        UUID issueId = UUID.randomUUID();
        SubcontractMaterialIssueService issueService =
                mock(SubcontractMaterialIssueService.class);
        var issue = mock(
                com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail.class);
        when(issue.getBillNo()).thenReturn("WWFL-006");
        when(issue.getLegacyId()).thenReturn(206);
        when(issueService.detail(issueId)).thenReturn(issue);
        assertSame(
                issue,
                new SubcontractMaterialIssueController(issueService, recorder)
                        .detail(issueId));
        verify(recorder).record(
                "view_subcontract_material_issue_detail",
                "subcontract_material_issues",
                issueId,
                "WWFL-006",
                206,
                "委外材料出仓单");

        UUID materialReturnId = UUID.randomUUID();
        SubcontractMaterialReturnService materialReturnService =
                mock(SubcontractMaterialReturnService.class);
        var materialReturn = mock(
                com.uten.imp.features.subcontract.material_return.dto.MaterialReturnDetail.class);
        when(materialReturn.getBillNo()).thenReturn("WWTL-007");
        when(materialReturn.getLegacyId()).thenReturn(207);
        when(materialReturnService.detail(materialReturnId))
                .thenReturn(materialReturn);
        assertSame(
                materialReturn,
                new SubcontractMaterialReturnController(
                                materialReturnService, recorder)
                        .detail(materialReturnId));
        verify(recorder).record(
                "view_subcontract_material_return_detail",
                "subcontract_material_returns",
                materialReturnId,
                "WWTL-007",
                207,
                "委外材料退货单");

        UUID wasteId = UUID.randomUUID();
        SubcontractWasteService wasteService = mock(SubcontractWasteService.class);
        var waste = mock(
                com.uten.imp.features.subcontract.waste.dto.WasteDetail.class);
        when(waste.getBillNo()).thenReturn("WWSH-008");
        when(waste.getLegacyId()).thenReturn(208);
        when(wasteService.detail(wasteId)).thenReturn(waste);
        assertSame(
                waste,
                new SubcontractWasteController(wasteService, recorder)
                        .detail(wasteId));
        verify(recorder).record(
                "view_subcontract_waste_detail",
                "subcontract_wastes",
                wasteId,
                "WWSH-008",
                208,
                "委外材料损耗单");
    }

    @Test
    void productionAndStockDetailsRecordOnlySafeBusinessReferences() {
        UUID planId = UUID.randomUUID();
        ProductionPlanService planService = mock(ProductionPlanService.class);
        var plan = mock(
                com.uten.imp.features.production.plan.dto.PlanDetail.class);
        when(plan.getBillNo()).thenReturn("SCJH-001");
        when(plan.getLegacyId()).thenReturn(301);
        when(planService.detail(planId)).thenReturn(plan);
        assertSame(
                plan,
                new ProductionPlanController(planService, recorder)
                        .detail(planId));
        verify(recorder).record(
                "view_production_plan_detail",
                "production_plans",
                planId,
                "SCJH-001",
                301,
                "生产计划单");

        UUID reportId = UUID.randomUUID();
        ProductionDailyReportService reportService =
                mock(ProductionDailyReportService.class);
        var report = mock(
                com.uten.imp.features.production.dailyreport.dto.DailyReportDetail.class);
        when(report.getBillNo()).thenReturn("SCRB-002");
        when(report.getLegacyId()).thenReturn(302);
        when(reportService.detail(reportId)).thenReturn(report);
        assertSame(
                report,
                new ProductionDailyReportController(
                                reportService,
                                mock(ReportablePlanLineQueryService.class),
                                recorder)
                        .detail(reportId));
        verify(recorder).record(
                "view_production_daily_report_detail",
                "production_daily_reports",
                reportId,
                "SCRB-002",
                302,
                "生产日报");

        UUID inspectionId = UUID.randomUUID();
        ProductionFqcInspectionService inspectionService =
                mock(ProductionFqcInspectionService.class);
        var inspection = mock(
                com.uten.imp.features.production.quality.ProductionFqcContracts.InspectionView.class);
        when(inspection.reportNo()).thenReturn("SCRB-002");
        when(inspectionService.detail(inspectionId)).thenReturn(inspection);
        assertSame(
                inspection,
                new ProductionFqcInspectionController(
                                inspectionService,
                                mock(ProductionFqcTaskAccessPolicy.class),
                                recorder)
                        .detail(inspectionId));
        verify(recorder).record(
                "view_production_fqc_inspection_detail",
                "production_fqc_inspections",
                inspectionId,
                "SCRB-002",
                null,
                "生产终检任务");

        UUID stockId = UUID.randomUUID();
        StockDocService stockService = mock(StockDocService.class);
        var stock = mock(
                com.uten.imp.features.stock.dto.StockDocDetail.class);
        when(stock.getBillNo()).thenReturn("CKDJ-003");
        when(stock.getLegacyId()).thenReturn(303);
        when(stockService.detail(stockId)).thenReturn(stock);
        assertSame(
                stock,
                new StockDocController(stockService, recorder).detail(stockId));
        verify(recorder).record(
                "view_stock_document_detail",
                "stock_documents",
                stockId,
                "CKDJ-003",
                303,
                "库存单据");
    }

    @Test
    void notFoundForbiddenOrUnexpectedFailureNeverRecordsSuccessfulView() {
        UUID missingId = UUID.randomUUID();
        PurchaseRequestService requestService = mock(PurchaseRequestService.class);
        when(requestService.detail(missingId))
                .thenThrow(new ApiException(ErrorCode.NOT_FOUND));
        assertThrows(
                ApiException.class,
                () -> new PurchaseRequestController(requestService, recorder)
                        .detail(missingId));

        UUID forbiddenId = UUID.randomUUID();
        SubcontractInquiryService inquiryService =
                mock(SubcontractInquiryService.class);
        when(inquiryService.detail(forbiddenId))
                .thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        assertThrows(
                ApiException.class,
                () -> new SubcontractInquiryController(inquiryService, recorder)
                        .detail(forbiddenId));

        UUID failedId = UUID.randomUUID();
        StockDocService stockService = mock(StockDocService.class);
        when(stockService.detail(failedId))
                .thenThrow(new IllegalStateException("query failed"));
        assertThrows(
                IllegalStateException.class,
                () -> new StockDocController(stockService, recorder)
                        .detail(failedId));

        verifyNoInteractions(recorder);
    }
}
