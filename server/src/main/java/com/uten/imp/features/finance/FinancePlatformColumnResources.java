package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.features.finance.receipt.FinanceReceipt;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.payment.FinancePayment;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.expense.FinanceExpense;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncome;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransfer;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.*;
import java.util.function.Function;

/** Finance reference fields never change settlement/GL facts or reopen historical money records. */
@Configuration
@RequiredArgsConstructor
public class FinancePlatformColumnResources {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final FinanceDocumentAccessPolicy access;
    private final FinanceReceiptService receipts;
    private final FinancePaymentService payments;
    private final FinanceExpenseService expenses;
    private final FinanceOtherIncomeService incomes;
    private final FinanceBankTransferService transfers;

    @Bean PlatformColumnResourceAdapter financeReceiptFields() {
        return resource("finance_receipt", "销售收款", FinanceReceipt.class, null, receipts::detail);
    }
    @Bean PlatformColumnResourceAdapter financeReceiptLineFields() {
        return resource("finance_receipt_item", "销售收款明细", FinanceReceipt.class,
                "SELECT id, receipt_id FROM finance_receipt_lines WHERE id IN (:ids)", receipts::detail)
                .documentRows("SELECT id FROM finance_receipt_lines WHERE receipt_id=:document");
    }
    @Bean PlatformColumnResourceAdapter financePaymentFields() {
        return resource("finance_payment", "采购付款", FinancePayment.class, null, payments::detail);
    }
    @Bean PlatformColumnResourceAdapter financePaymentLineFields() {
        return resource("finance_payment_item", "采购付款明细", FinancePayment.class,
                "SELECT id, payment_id FROM finance_payment_lines WHERE id IN (:ids)", payments::detail)
                .documentRows("SELECT id FROM finance_payment_lines WHERE payment_id=:document");
    }
    @Bean PlatformColumnResourceAdapter financeExpenseFields() {
        return resource("finance_expense", "一般费用", FinanceExpense.class, null, expenses::detail);
    }
    @Bean PlatformColumnResourceAdapter financeExpenseLineFields() {
        return resource("finance_expense_item", "一般费用明细", FinanceExpense.class,
                "SELECT id, expense_id FROM finance_expense_items WHERE id IN (:ids)", expenses::detail)
                .documentRows("SELECT id FROM finance_expense_items WHERE expense_id=:document");
    }
    @Bean PlatformColumnResourceAdapter financeIncomeFields() {
        return resource("finance_other_income", "其它收入", FinanceOtherIncome.class, null, incomes::detail);
    }
    @Bean PlatformColumnResourceAdapter financeIncomeLineFields() {
        return resource("finance_other_income_item", "其它收入明细", FinanceOtherIncome.class,
                "SELECT id, income_id FROM finance_other_income_items WHERE id IN (:ids)", incomes::detail)
                .documentRows("SELECT id FROM finance_other_income_items WHERE income_id=:document");
    }
    @Bean PlatformColumnResourceAdapter financeTransferFields() {
        return resource("finance_bank_transfer", "银行存取款", FinanceBankTransfer.class, null, transfers::detail);
    }
    @Bean PlatformColumnResourceAdapter financeTransferLineFields() {
        return resource("finance_bank_transfer_item", "银行存取款明细", FinanceBankTransfer.class,
                "SELECT id, transfer_id FROM finance_bank_transfer_lines WHERE id IN (:ids)", transfers::detail)
                .documentRows("SELECT id FROM finance_bank_transfer_lines WHERE transfer_id=:document");
    }

    private DocumentPlatformColumnAdapter resource(String scope, String label, Class<?> entity,
            String lineParents, Function<UUID, Object> detail) {
        String permission = scope.endsWith("_item") ? scope.substring(0, scope.length()-5) : scope;
        return new DocumentPlatformColumnAdapter(scope, label, current, em, json,
                Set.of(permission + ":view"), Set.of(permission + ":edit"),
                Set.of(permission + ":view"), entity, lineParents, detail,
                (id, header) -> DocumentPlatformColumnAdapter.draft(header)
                        && (!header.hasNonNull("legacyId"))
                        && access.canWrite(DocumentPlatformColumnAdapter.uuid(header, "makerId")),
                List.of(new FactDefinition("amountOriginal", "原币金额", true),
                        new FactDefinition("amountLocal", "本币金额", true),
                        new FactDefinition("exchangeRate", "汇率", true),
                        new FactDefinition("writeOffAmount", "冲销金额", true),new FactDefinition("writeOffLocal", "本币冲销金额", true),
                        new FactDefinition("appliedAmountLocal", "本币核销金额", true),
                        new FactDefinition("balanceBeforeOriginal", "核销前原币余额", true),
                        new FactDefinition("balanceAfterOriginal", "核销后原币余额", true),
                        new FactDefinition("qty", "数量", false), new FactDefinition("price", "单价", true)))
                .documentCreateAuthorities(Set.of(permission + ":create"));
    }
}
