package com.uten.imp.features.finance;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.expenseclaim.ExpenseClaimController;
import com.uten.imp.features.expenseclaim.ExpenseClaimService;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.finance.arap.ArApLedgerController;
import com.uten.imp.features.finance.arap.ArApLedgerQueryService;
import com.uten.imp.features.finance.arap.dto.ArApLedgerDetail;
import com.uten.imp.features.finance.asset.FixedAssetController;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.application.FinanceAssetCategoryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPeriodService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPostingService;
import com.uten.imp.features.finance.asset.application.FinanceAssetQueryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetWorkflowService;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferDetail;
import com.uten.imp.features.finance.expense.FinanceExpenseController;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseDetail;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeController;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeDetail;
import com.uten.imp.features.finance.payment.FinancePaymentController;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.receipt.FinanceReceiptController;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class FinanceSensitiveDetailViewAuditControllerTest {

    private final AuditDetailViewRecorder recorder = mock(AuditDetailViewRecorder.class);
    private final AuditService audit = mock(AuditService.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);

    @Test
    void moneyDocumentDetailsRecordOnlySafeDocumentIdentityAfterSuccessfulLookup() {
        UUID receiptId = UUID.randomUUID();
        FinanceReceiptService receiptService = mock(FinanceReceiptService.class);
        FinanceReceiptDetail receipt = mock(FinanceReceiptDetail.class);
        when(receipt.getBillNo()).thenReturn("SK-2026-001");
        when(receipt.getLegacyId()).thenReturn(101);
        when(receiptService.detail(receiptId)).thenReturn(receipt);
        assertSame(receipt, new FinanceReceiptController(
                receiptService, audit, currentUser, recorder).detail(receiptId));
        verify(recorder).record("view_finance_receipt_detail", "finance_receipts",
                receiptId, "SK-2026-001", 101, "销售收款单");

        UUID paymentId = UUID.randomUUID();
        FinancePaymentService paymentService = mock(FinancePaymentService.class);
        FinancePaymentDetail payment = mock(FinancePaymentDetail.class);
        when(payment.getBillNo()).thenReturn("FK-2026-002");
        when(payment.getLegacyId()).thenReturn(null);
        when(paymentService.detail(paymentId)).thenReturn(payment);
        assertSame(payment, new FinancePaymentController(
                paymentService, audit, currentUser, recorder).detail(paymentId));
        verify(recorder).record("view_finance_payment_detail", "finance_payments",
                paymentId, "FK-2026-002", null, "采购付款单");

        UUID expenseId = UUID.randomUUID();
        FinanceExpenseService expenseService = mock(FinanceExpenseService.class);
        FinanceExpenseDetail expense = mock(FinanceExpenseDetail.class);
        when(expense.getBillNo()).thenReturn("FY-2026-003");
        when(expense.getLegacyId()).thenReturn(null);
        when(expenseService.detail(expenseId)).thenReturn(expense);
        assertSame(expense, new FinanceExpenseController(
                expenseService, audit, currentUser, recorder).detail(expenseId));
        verify(recorder).record("view_finance_expense_detail", "finance_expenses",
                expenseId, "FY-2026-003", null, "一般费用单");

        UUID incomeId = UUID.randomUUID();
        FinanceOtherIncomeService incomeService = mock(FinanceOtherIncomeService.class);
        FinanceOtherIncomeDetail income = mock(FinanceOtherIncomeDetail.class);
        when(income.getBillNo()).thenReturn("QT-2026-004");
        when(income.getLegacyId()).thenReturn(null);
        when(incomeService.detail(incomeId)).thenReturn(income);
        assertSame(income, new FinanceOtherIncomeController(
                incomeService, audit, currentUser, recorder).detail(incomeId));
        verify(recorder).record("view_finance_other_income_detail", "finance_other_incomes",
                incomeId, "QT-2026-004", null, "其它收入单");

        UUID transferId = UUID.randomUUID();
        FinanceBankTransferService transferService = mock(FinanceBankTransferService.class);
        FinanceBankTransferDetail transfer = mock(FinanceBankTransferDetail.class);
        when(transfer.getBillNo()).thenReturn("ZZ-2026-005");
        when(transfer.getLegacyId()).thenReturn(null);
        when(transferService.detail(transferId)).thenReturn(transfer);
        assertSame(transfer, new FinanceBankTransferController(
                transferService, audit, currentUser, recorder).detail(transferId));
        verify(recorder).record("view_finance_bank_transfer_detail", "finance_bank_transfers",
                transferId, "ZZ-2026-005", null, "银行存取款单");
    }

    @Test
    void ledgerAndClaimDetailsUseOnlyDocumentNumberOrTitle() {
        UUID ledgerId = UUID.randomUUID();
        ArApLedgerQueryService ledgerService = mock(ArApLedgerQueryService.class);
        ArApLedgerDetail ledger = mock(ArApLedgerDetail.class);
        when(ledger.getSourceDocNo()).thenReturn("SO-2026-006");
        when(ledger.getLegacyId()).thenReturn(606);
        when(ledgerService.detail(ledgerId)).thenReturn(ledger);
        assertSame(ledger, new ArApLedgerController(ledgerService, recorder).detail(ledgerId));
        verify(recorder).record("view_ar_ap_ledger_detail", "ar_ap_ledger",
                ledgerId, "SO-2026-006", 606, "应收应付台账");

        UUID claimId = UUID.randomUUID();
        ExpenseClaimService claimService = mock(ExpenseClaimService.class);
        ExpenseClaimDto claim = mock(ExpenseClaimDto.class);
        when(claim.title()).thenReturn("八月差旅报销");
        when(claimService.detail(claimId)).thenReturn(claim);
        assertSame(claim, new ExpenseClaimController(claimService, recorder).detail(claimId));
        verify(recorder).record("view_expense_claim_detail", "expense_claims",
                claimId, "八月差旅报销", null, "费用报销单");
    }

    @Test
    void assetDetailsUseCodeAndPostingRunFallsBackToPeriod() {
        FinanceAssetQueryService query = mock(FinanceAssetQueryService.class);
        FinanceAssetPostingService posting = mock(FinanceAssetPostingService.class);
        FixedAssetController controller = assetController(query, posting);

        UUID fixedId = UUID.randomUUID();
        AssetWorkbenchResponses.Detail fixed = mock(AssetWorkbenchResponses.Detail.class);
        AssetWorkbenchResponses.Summary fixedSummary = mock(AssetWorkbenchResponses.Summary.class);
        when(fixed.summary()).thenReturn(fixedSummary);
        when(fixedSummary.code()).thenReturn("FA-2026-001");
        when(query.fixedAsset(fixedId)).thenReturn(fixed);
        assertSame(fixed, controller.fixedAsset(fixedId));
        verify(recorder).record("view_fixed_asset_detail", "fixed_assets",
                fixedId, "FA-2026-001", null, "固定资产");

        UUID deferredId = UUID.randomUUID();
        AssetWorkbenchResponses.Detail deferred = mock(AssetWorkbenchResponses.Detail.class);
        AssetWorkbenchResponses.Summary deferredSummary = mock(AssetWorkbenchResponses.Summary.class);
        when(deferred.summary()).thenReturn(deferredSummary);
        when(deferredSummary.code()).thenReturn("DA-2026-001");
        when(query.deferredExpense(deferredId)).thenReturn(deferred);
        assertSame(deferred, controller.deferredExpense(deferredId));
        verify(recorder).record("view_deferred_expense_detail", "deferred_expenses",
                deferredId, "DA-2026-001", null, "递延费用");

        UUID runId = UUID.randomUUID();
        AssetWorkbenchResponses.PostingRun run = mock(AssetWorkbenchResponses.PostingRun.class);
        when(run.period()).thenReturn("2026-08");
        when(posting.get(runId)).thenReturn(run);
        assertSame(run, controller.postingRun(runId));
        verify(recorder).record("view_asset_posting_run_detail", "finance_asset_posting_runs",
                runId, "2026-08", null, "资产过账批次");
    }

    @Test
    void failedOrForbiddenLookupsNeverWriteSuccessfulViewAudit() {
        UUID missingId = UUID.randomUUID();
        FinanceReceiptService receiptService = mock(FinanceReceiptService.class);
        when(receiptService.detail(missingId))
                .thenThrow(new ApiException(ErrorCode.NOT_FOUND, "收款单不存在"));
        FinanceReceiptController receiptController = new FinanceReceiptController(
                receiptService, audit, currentUser, recorder);
        assertThrows(ApiException.class, () -> receiptController.detail(missingId));

        UUID forbiddenId = UUID.randomUUID();
        ExpenseClaimService claimService = mock(ExpenseClaimService.class);
        when(claimService.detail(forbiddenId))
                .thenThrow(new ApiException(ErrorCode.FORBIDDEN, "无权查看该报销单"));
        ExpenseClaimController claimController = new ExpenseClaimController(claimService, recorder);
        assertThrows(ApiException.class, () -> claimController.detail(forbiddenId));

        UUID failedId = UUID.randomUUID();
        FinanceAssetQueryService query = mock(FinanceAssetQueryService.class);
        when(query.fixedAsset(failedId)).thenThrow(new IllegalStateException("query failed"));
        assertThrows(IllegalStateException.class,
                () -> assetController(query, mock(FinanceAssetPostingService.class)).fixedAsset(failedId));

        verifyNoInteractions(recorder);
    }

    private FixedAssetController assetController(
            FinanceAssetQueryService query,
            FinanceAssetPostingService posting) {
        return new FixedAssetController(
                query,
                mock(FinanceAssetWorkflowService.class),
                mock(FinanceAssetCategoryService.class),
                posting,
                mock(FinanceAssetPeriodService.class),
                mock(FixedAssetService.class),
                recorder);
    }
}
