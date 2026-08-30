package com.uten.imp.features.finance;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.payables.ProcurementPayablesController;
import com.uten.imp.features.finance.payables.ProcurementPayablesContracts.Detail;
import com.uten.imp.features.finance.payables.ProcurementPayablesContracts.Item;
import com.uten.imp.features.finance.payables.ProcurementPayablesService;
import com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.CaseDetail;
import com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.CaseSummary;
import com.uten.imp.features.finance.payables.SubcontractLossClaimController;
import com.uten.imp.features.finance.payables.SubcontractLossClaimService;
import com.uten.imp.features.finance.payables.SupplierSettlementContracts.BatchDetail;
import com.uten.imp.features.finance.payables.SupplierSettlementContracts.BatchSummary;
import com.uten.imp.features.finance.payables.SupplierSettlementController;
import com.uten.imp.features.finance.payables.SupplierSettlementService;
import com.uten.imp.features.warehouse.inbound.FinanceProcurementArrivalExceptionController;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalExceptionController;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AdditionalFinancialDetailViewAuditControllerTest {

    @Test
    void payableAndArrivalDetailsRecordOnlySafeDocumentNumbers() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);

        UUID settlementId = UUID.randomUUID();
        SupplierSettlementService settlements = mock(SupplierSettlementService.class);
        BatchDetail settlement = mock(BatchDetail.class);
        BatchSummary settlementSummary = mock(BatchSummary.class);
        when(settlement.summary()).thenReturn(settlementSummary);
        when(settlementSummary.batchNo()).thenReturn("DZ-2026-001");
        when(settlements.detail(settlementId)).thenReturn(settlement);
        assertSame(settlement,
                new SupplierSettlementController(settlements, audit).detail(settlementId));
        verify(audit).record(
                "view_supplier_settlement_detail", "supplier_settlements",
                settlementId, "DZ-2026-001", null, "供应商对账单");

        UUID claimId = UUID.randomUUID();
        SubcontractLossClaimService claims = mock(SubcontractLossClaimService.class);
        CaseDetail claim = mock(CaseDetail.class);
        CaseSummary claimSummary = mock(CaseSummary.class);
        when(claim.summary()).thenReturn(claimSummary);
        when(claimSummary.wasteBillNo()).thenReturn("WS-2026-002");
        when(claims.detail(claimId)).thenReturn(claim);
        assertSame(claim,
                new SubcontractLossClaimController(claims, audit).detail(claimId));
        verify(audit).record(
                "view_subcontract_loss_claim_detail", "subcontract_loss_claims",
                claimId, "WS-2026-002", null, "委外损耗索赔");

        UUID payableId = UUID.randomUUID();
        ProcurementPayablesService payables = mock(ProcurementPayablesService.class);
        Detail payable = mock(Detail.class);
        Item item = mock(Item.class);
        when(payable.item()).thenReturn(item);
        when(item.sourceDocNo()).thenReturn("PR-2026-003");
        when(payables.detail(payableId)).thenReturn(payable);
        assertSame(payable,
                new ProcurementPayablesController(payables, audit).detail(payableId));
        verify(audit).record(
                "view_procurement_payable_detail", "procurement_payables",
                payableId, "PR-2026-003", null, "采购应付明细");

        UUID ownerExceptionId = UUID.randomUUID();
        ProcurementArrivalControlService ownerService =
                mock(ProcurementArrivalControlService.class);
        ArrivalExceptionTask ownerException = mock(ArrivalExceptionTask.class);
        when(ownerException.receiptBillNo()).thenReturn("RK-2026-004");
        when(ownerService.ownerDetail(ownerExceptionId)).thenReturn(ownerException);
        assertSame(ownerException,
                new ProcurementArrivalExceptionController(ownerService, audit)
                        .detail(ownerExceptionId));
        verify(audit).record(
                "view_procurement_arrival_exception_detail",
                "procurement_arrival_exceptions",
                ownerExceptionId, "RK-2026-004", null, "采购到货异常");

        UUID financeExceptionId = UUID.randomUUID();
        ProcurementArrivalControlService financeService =
                mock(ProcurementArrivalControlService.class);
        ArrivalExceptionTask financeException = mock(ArrivalExceptionTask.class);
        when(financeException.orderBillNo()).thenReturn("PO-2026-005");
        when(financeService.financeDetail(financeExceptionId)).thenReturn(financeException);
        assertSame(financeException,
                new FinanceProcurementArrivalExceptionController(financeService, audit)
                        .detail(financeExceptionId));
        verify(audit).record(
                "view_finance_procurement_arrival_exception_detail",
                "procurement_arrival_exceptions",
                financeExceptionId, "PO-2026-005", null, "采购到货异常财务审批");
    }

    @Test
    void failedAdditionalFinancialDetailDoesNotWriteSuccessfulView() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        SupplierSettlementService service = mock(SupplierSettlementService.class);
        UUID id = UUID.randomUUID();
        RuntimeException failure = new RuntimeException("detail failed");
        when(service.detail(id)).thenThrow(failure);

        assertSame(failure, assertThrows(RuntimeException.class,
                () -> new SupplierSettlementController(service, audit).detail(id)));
        verifyNoInteractions(audit);
    }
}
