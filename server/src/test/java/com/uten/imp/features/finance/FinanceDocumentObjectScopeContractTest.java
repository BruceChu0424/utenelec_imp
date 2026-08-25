package com.uten.imp.features.finance;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class FinanceDocumentObjectScopeContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");
    private static final Path MIGRATIONS = Path.of("src/main/resources/db/migration");

    @Test
    void everyFinanceDocumentServiceScopesListsAndSingleDocumentReads() throws Exception {
        for (String relative : services()) {
            String source = source(relative);

            assertThat(source).contains("private final FinanceDocumentAccessPolicy access;");
            assertThat(method(source, " list(")).contains(
                    "var readScope = access.scope();",
                    "access.readablePredicate(root, cb, \"makerId\", readScope)");
            String detail = method(source, " detail(");
            assertThat(detail).contains("access.requireReadable(");
            int childLoad = firstIndexOf(detail, "lineRepo.findBy", "itemRepo.findBy");
            assertThat(childLoad).as("detail child load in %s", relative).isGreaterThanOrEqualTo(0);
            assertThat(detail.indexOf("access.requireReadable("))
                    .isLessThan(childLoad);
            assertThat(method(source, " create("))
                    .contains(".setMakerId(currentUser.requireEmployeeId())");
        }
    }

    @Test
    void everyExposedSingleDocumentMutationRequiresWriteScope() throws Exception {
        assertMutations("features/finance/payment/FinancePaymentService.java",
                " update(", " delete(", " approve(", " reverse(");
        assertMutations("features/finance/receipt/FinanceReceiptService.java",
                " update(", " delete(", " approve(", " reverse(");
        assertMutations("features/finance/expense/FinanceExpenseService.java",
                " update(", " delete(", " approve(", " reverse(", " glConfirm(");
        assertMutations("features/finance/bank_transfer/FinanceBankTransferService.java",
                " update(", " delete(", " approve(", " reverse(");
        assertMutations("features/finance/other_income/FinanceOtherIncomeService.java",
                " update(", " delete(", " approve(", " reverse(");
    }

    @Test
    void databaseAndAdminScopesIncludeFinanceWithoutDroppingExistingScopes() throws Exception {
        String migration = Files.readString(
                MIGRATIONS.resolve("V245__restore_finance_object_scope.sql"),
                StandardCharsets.UTF_8);
        String admin = source("features/admin/DataScopeAdminService.java");

        assertThat(migration).contains(
                "'goods'", "'client'", "'sales'", "'finance'",
                "'purchase'", "'subcontract'", "'production_plan'", "'stock_doc'");
        assertThat(admin).contains(
                "\"goods\", \"client\", \"sales\", \"finance\"",
                "case \"finance\" ->",
                "FROM finance_payments",
                "FROM finance_receipts",
                "FROM finance_expenses",
                "FROM finance_bank_transfers",
                "FROM finance_other_incomes");
    }

    private static void assertMutations(String relative, String... signatures) throws Exception {
        String source = source(relative);
        for (String signature : signatures) {
            assertThat(method(source, signature))
                    .as("%s in %s", signature.trim(), relative)
                    .containsAnyOf(
                            "access.requireWritable(",
                            "access.requireScopedOperationWritable(");
        }
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        assertThat(start).as("method %s", signature.trim()).isGreaterThanOrEqualTo(0);
        int bodyStart = source.indexOf('{', start + signature.length());
        assertThat(bodyStart).as("method body %s", signature.trim()).isGreaterThan(start);
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char token = source.charAt(index);
            if (token == '{') {
                depth++;
            } else if (token == '}' && --depth == 0) {
                return source.substring(start, index + 1);
            }
        }
        throw new IllegalStateException("Unclosed method: " + signature.trim());
    }

    private static int firstIndexOf(String source, String... candidates) {
        int result = -1;
        for (String candidate : candidates) {
            int index = source.indexOf(candidate);
            if (index >= 0 && (result < 0 || index < result)) {
                result = index;
            }
        }
        return result;
    }

    private static List<String> services() {
        return List.of(
                "features/finance/payment/FinancePaymentService.java",
                "features/finance/receipt/FinanceReceiptService.java",
                "features/finance/expense/FinanceExpenseService.java",
                "features/finance/bank_transfer/FinanceBankTransferService.java",
                "features/finance/other_income/FinanceOtherIncomeService.java");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
