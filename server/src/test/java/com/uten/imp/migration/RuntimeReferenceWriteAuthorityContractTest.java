package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RuntimeReferenceWriteAuthorityContractTest {

    @Test
    void financeMethodsAndOperatorsUseUuidAuthoritativeResolvers() throws IOException {
        String receipt = source("features/finance/receipt/FinanceReceiptService.java");
        String payment = source("features/finance/payment/FinancePaymentService.java");
        String expense = source("features/finance/expense/FinanceExpenseService.java");
        String income = source("features/finance/other_income/FinanceOtherIncomeService.java");

        assertTrue(receipt.contains("PaymentMethodReferenceResolver.resolve"));
        assertTrue(payment.contains("PaymentMethodReferenceResolver.resolve"));
        assertTrue(expense.contains("PaymentMethodReferenceResolver.resolve"));
        assertTrue(income.contains("PaymentMethodReferenceResolver.resolve"));
        assertTrue(receipt.contains("nameResolver.resolveForWrite"));
        assertTrue(payment.contains("nameResolver.resolveForWrite"));
        assertTrue(income.contains("nameResolver.resolveForWrite"));
        assertFalse(receipt.contains("setReceiptMethodLegacyId(req.getReceiptMethodLegacyId())"));
        assertFalse(payment.contains("setPaymentMethodLegacyId(req.getPaymentMethodLegacyId())"));
        assertFalse(expense.contains("setPaymentMethodLegacyId(req.getPaymentMethodLegacyId())"));
        assertFalse(payment.contains("setOperatorName(req.getOperatorName())"));
        assertFalse(income.contains("setReceiptMethodLegacyId(req.getReceiptMethodLegacyId())"));
    }

    @Test
    void subcontractRequestsCannotOverwriteActorHistoryShadows() throws IOException {
        String issue = source("features/subcontract/material_issue/SubcontractMaterialIssueService.java");
        String materialReturn = source(
                "features/subcontract/material_return/SubcontractMaterialReturnService.java");
        String receipt = source("features/subcontract/receipt/SubcontractReceiptService.java");
        String subcontractReturn = source("features/subcontract/ret/SubcontractReturnService.java");

        for (String service : new String[]{issue, materialReturn, receipt, subcontractReturn}) {
            assertFalse(service.contains("setMakerLegacyId(req.getMakerLegacyId())"));
            assertFalse(service.contains("setMakerName(req.getMakerName())"));
            assertFalse(service.contains("setApproverLegacyId(req.getApproverLegacyId())"));
            assertFalse(service.contains("setApproverName(req.getApproverName())"));
        }
        assertTrue(issue.contains("nameResolver.resolveForWrite"));
        assertTrue(materialReturn.contains("nameResolver.resolveForWrite"));
        assertTrue(receipt.contains("nameResolver.resolveForWrite"));
        assertFalse(issue.contains("setOperatorLegacyId(req.getOperatorLegacyId())"));
        assertFalse(materialReturn.contains("setOperatorLegacyId(req.getOperatorLegacyId())"));
        assertFalse(receipt.contains("setReceiverLegacyId(req.getReceiverLegacyId())"));
    }

    @Test
    void financeEntitiesMapExistingLegacyShadowsSoUuidWritesCanCanonicalizeThem()
            throws IOException {
        for (String entity : new String[]{
                "features/finance/receipt/FinanceReceipt.java",
                "features/finance/payment/FinancePayment.java",
                "features/finance/other_income/FinanceOtherIncome.java"}) {
            String text = source(entity);
            assertTrue(text.contains("operator_legacy_id"));
            assertTrue(text.contains("maker_legacy_id"));
            assertTrue(text.contains("approver_legacy_id"));
        }
    }

    private static String source(String relative) throws IOException {
        return Files.readString(Path.of("src/main/java/com/uten/imp").resolve(relative));
    }
}
