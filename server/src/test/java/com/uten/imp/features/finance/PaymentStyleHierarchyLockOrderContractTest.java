package com.uten.imp.features.finance;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PaymentStyleHierarchyLockOrderContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");
    private static final String HIERARCHY_LOCK = "PaymentStyleHierarchyLock.lock(em);";

    @Test
    void glAndAssetStyleConsumersLockHierarchyBeforeNarrowerBusinessLocks() throws Exception {
        for (LockOrderContract contract : contracts()) {
            String command = method(source(contract.relativePath()), contract.methodSignature());
            int hierarchyLock = command.indexOf(HIERARCHY_LOCK);
            int narrowerOperation = command.indexOf(contract.narrowerOperation());

            assertThat(hierarchyLock)
                    .as("hierarchy lock in %s of %s", contract.methodSignature(), contract.relativePath())
                    .isGreaterThanOrEqualTo(0);
            assertThat(narrowerOperation)
                    .as("narrower operation in %s of %s", contract.methodSignature(), contract.relativePath())
                    .isGreaterThanOrEqualTo(0);
            assertThat(hierarchyLock)
                    .as("lock order in %s of %s", contract.methodSignature(), contract.relativePath())
                    .isLessThan(narrowerOperation);
        }
    }

    @Test
    void everyAssetPostingCheckTreatsAnyUndeletedChildAsNonLeaf() throws Exception {
        List<MethodContract> checks = List.of(
                new MethodContract(
                        "features/finance/asset/application/FinanceAssetCategoryService.java",
                        "private void requirePostableStyle("),
                new MethodContract(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java",
                        "private void requirePostableStyle("),
                new MethodContract(
                        "features/finance/asset/application/FinanceAssetPostingService.java",
                        "private boolean postableStyle("));

        for (MethodContract check : checks) {
            String body = method(source(check.relativePath()), check.methodSignature());
            assertThat(body)
                    .as("leaf definition in %s", check.relativePath())
                    .contains("child.parent_id=s.id AND child.is_deleted=false)")
                    .doesNotContain("child.status='使用'");
        }
    }

    @Test void assetPostingAndReversalFollowTheUniqueControlledWriterHierarchyThenPeriodThenBusinessLockOrder() throws Exception {
        String adapter=source("features/finance/asset/application/FinanceAssetLedgerPostingService.java");
        assertThat(method(adapter,"public UUID post(")).contains("return journals.post(");
        assertThat(method(adapter,"public UUID reverse(")).contains("return journals.reverse(");
        String writer=source("features/finance/gl/FinanceControlledJournalService.java");
        String lock=method(writer,"private void lock(");
        assertThat(lock.indexOf(HIERARCHY_LOCK)).isGreaterThanOrEqualTo(0).isLessThan(lock.indexOf("periods.lockAutoProjectionPeriod(date);"));
        String post=method(writer,"public Posted post(");
        assertThat(post.indexOf("lock(voucherDate);")).isGreaterThanOrEqualTo(0).isLessThan(post.indexOf("lockStyles("));
        assertThat(post.indexOf("lockStyles(")).isLessThan(post.indexOf("return insert("));
        String reverse=method(writer,"public Posted reverse(");
        assertThat(reverse.indexOf("lock(voucherDate);")).isGreaterThanOrEqualTo(0).isLessThan(reverse.indexOf("FROM gl_vouchers WHERE id=? FOR UPDATE"));
        assertThat(reverse.indexOf("FROM gl_vouchers WHERE id=? FOR UPDATE")).isLessThan(reverse.indexOf("lockStyles("));
    }

    private static List<LockOrderContract> contracts() {
        return List.of(
                new LockOrderContract(
                        "features/finance/gl/GlPostingService.java",
                        "private int generatePeriod(",
                        "lockAutoProjectionPeriod(period);"),
                new LockOrderContract(
                        "features/finance/gl/GlPostingService.java",
                        "public UUID postExpenseDoc(",
                        "List<Object[]> docs = em.createNativeQuery("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetCategoryService.java",
                        "public AssetCategoryContracts.Category create(",
                        "em.createNativeQuery(\"SELECT pg_advisory_xact_lock"),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetCategoryService.java",
                        "public AssetCategoryContracts.Category update(",
                        "CategoryLock current = lock(id);"),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetCategoryService.java",
                        "public AssetCategoryContracts.Category activate(",
                        "CategoryLock current = lock(id);"),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java",
                        "public AssetWorkbenchResponses.WorkflowResult approve(",
                        "lockPostingStream("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java",
                        "public AssetWorkbenchResponses.WorkflowResult activate(",
                        "periods.ensureOpen("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java",
                        "public AssetWorkbenchResponses.WorkflowResult approveDisposal(",
                        "periods.ensureOpen("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java",
                        "public AssetWorkbenchResponses.WorkflowResult approveTermination(",
                        "periods.ensureOpen("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetPostingService.java",
                        "public AssetWorkbenchResponses.PostingRun preview(",
                        "periods.ensureOpen("),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetPostingService.java",
                        "public AssetWorkbenchResponses.PostingRun post(",
                        "Run locked = lock(runId);"),
                new LockOrderContract(
                        "features/finance/asset/application/FinanceAssetPostingService.java",
                        "public AssetWorkbenchResponses.PostingRun reverse(",
                        "Run original = lock(originalRunId);"),
                new LockOrderContract(
                        "features/finance/gl/FinanceControlledJournalService.java",
                        "private void lock(",
                        "periods.lockAutoProjectionPeriod(date);"));
    }

    private static String source(String relativePath) throws Exception {
        return Files.readString(JAVA.resolve(relativePath), StandardCharsets.UTF_8);
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        assertThat(start).as("method %s", signature).isGreaterThanOrEqualTo(0);
        int bodyStart = source.indexOf('{', start + signature.length());
        assertThat(bodyStart).as("method body %s", signature).isGreaterThan(start);
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char token = source.charAt(index);
            if (token == '{') {
                depth++;
            } else if (token == '}' && --depth == 0) {
                return source.substring(start, index + 1);
            }
        }
        throw new IllegalStateException("Unclosed method: " + signature);
    }

    private record LockOrderContract(
            String relativePath,
            String methodSignature,
            String narrowerOperation) {}

    private record MethodContract(String relativePath, String methodSignature) {}
}
