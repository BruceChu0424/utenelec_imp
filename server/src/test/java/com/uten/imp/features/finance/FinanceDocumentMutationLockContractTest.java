package com.uten.imp.features.finance;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class FinanceDocumentMutationLockContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void everyMutableFinanceCommandLocksAndRechecksTheHeaderBeforeAuthorization() throws Exception {
        for (ServiceContract contract : services()) {
            String source = source(contract.relativePath());
            assertThat(method(source, " detail("))
                    .as("read-only detail in %s", contract.relativePath())
                    .contains("= require(id);")
                    .doesNotContain("lockActive(id)");
            String lockHelper = lastMethod(source, " lockActive(");
            assertThat(lockHelper)
                    .as("lock helper in %s", contract.relativePath())
                    .contains("em.refresh(", "PESSIMISTIC_WRITE", ".isDeleted()", "ErrorCode.NOT_FOUND");

            for (String signature : contract.mutations()) {
                String command = method(source, signature);
                String expectedLock = contract.projectionMutations().contains(signature)
                        ? "= lockActiveForProjection(id);"
                        : "= lockActive(id);";
                assertThat(command)
                        .as("%s in %s", signature.trim(), contract.relativePath())
                        .contains(expectedLock);
                assertThat(command.indexOf(expectedLock))
                        .isLessThan(Math.max(
                                command.indexOf("access.requireWritable("),
                                command.indexOf("access.requireScopedOperationWritable(")));
            }
            if (!contract.projectionMutations().isEmpty()) {
                assertThat(lastMethod(source, " lockActiveForProjection("))
                        .as("projection lock helper in %s", contract.relativePath())
                        .contains("glPosting.lockAutoProjectionPeriod(",
                                "em.refresh(", "PESSIMISTIC_WRITE",
                                ".isDeleted()", "ErrorCode.NOT_FOUND");
            }
        }
    }

    @Test
    void softDeleteIsRestrictedToDraftDocuments() throws Exception {
        for (ServiceContract contract : services()) {
            String delete = method(source(contract.relativePath()), " delete(");
            assertThat(delete)
                    .as("delete in %s", contract.relativePath())
                    .contains("getStatus() == null", "getStatus() != STATUS_DRAFT");
        }
    }

    private static List<ServiceContract> services() {
        return List.of(
                new ServiceContract(
                        "features/finance/receipt/FinanceReceiptService.java",
                        List.of(" update(", " delete(", " approve(", " reverse("),
                        List.of()),
                new ServiceContract(
                        "features/finance/other_income/FinanceOtherIncomeService.java",
                        List.of(" update(", " delete(", " approve(", " reverse("),
                        List.of()),
                new ServiceContract(
                        "features/finance/bank_transfer/FinanceBankTransferService.java",
                        List.of(" update(", " delete(", " approve(", " reverse("),
                        List.of()),
                new ServiceContract(
                        "features/finance/expense/FinanceExpenseService.java",
                        List.of(" update(", " delete(", " approve(", " reverse(", " glConfirm("),
                        List.of(" approve(", " reverse(", " glConfirm(")));
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        assertThat(start).as("method %s", signature.trim()).isGreaterThanOrEqualTo(0);
        return methodAt(source, signature, start);
    }

    private static String lastMethod(String source, String signature) {
        int start = source.lastIndexOf(signature);
        assertThat(start).as("method %s", signature.trim()).isGreaterThanOrEqualTo(0);
        return methodAt(source, signature, start);
    }

    private static String methodAt(String source, String signature, int start) {
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

    private record ServiceContract(
            String relativePath,
            List<String> mutations,
            List<String> projectionMutations) {}
}
