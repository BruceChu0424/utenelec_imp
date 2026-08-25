package com.uten.imp.security;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class DocumentReversedDeleteProtectionContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void everyScopedStandardDeleteChecksOwnerThenRequiresDraft() throws Exception {
        for (Contract contract : contracts()) {
            String command = method(source(contract.relativePath()),
                    "public void delete(UUID id)");
            int ownerGate = command.indexOf(contract.ownerGate());
            int draftGate = command.indexOf(
                    "StandardDocumentLifecycleCapabilities.requireDraftForDelete(");
            int mutation = command.indexOf("setDeleted(true)");

            assertThat(ownerGate)
                    .as("owner gate in %s", contract.relativePath())
                    .isGreaterThanOrEqualTo(0);
            assertThat(draftGate)
                    .as("draft-only delete gate in %s", contract.relativePath())
                    .isGreaterThan(ownerGate);
            assertThat(mutation)
                    .as("soft-delete mutation in %s", contract.relativePath())
                    .isGreaterThan(draftGate);
            assertThat(command)
                    .as("no approved-only loophole in %s", contract.relativePath())
                    .doesNotContain("getStatus() == STATUS_APPROVED");
        }
    }

    @Test
    void stockDetailDeleteCapabilityIsDraftOnly() throws Exception {
        String detailMapper = method(
                source("features/stock/StockDocService.java"),
                "private StockDocDetail toDetail(");

        assertThat(detailMapper)
                .contains("boolean canDelete", "d.getStatus() == STATUS_DRAFT")
                .doesNotContain("d.getStatus() != STATUS_APPROVED");
    }

    @Test
    void dormantGeneratedSourceDeleteEntryPointsRemainDraftOnly()
            throws Exception {
        for (String path : List.of(
                "features/purchase/request/PurchaseRequestService.java",
                "features/subcontract/application/SubcontractApplicationService.java")) {
            String command = method(source(path), "public void delete(UUID id)");
            int draftGate = command.indexOf(
                    "StandardDocumentLifecycleCapabilities");
            int mutation = command.indexOf("setDeleted(true)");

            assertThat(draftGate)
                    .as("draft-only source delete gate in %s", path)
                    .isGreaterThanOrEqualTo(0);
            assertThat(mutation)
                    .as("source delete mutation in %s", path)
                    .isGreaterThan(draftGate);
            assertThat(command)
                    .doesNotContain("getStatus() == STATUS_APPROVED");
        }
    }

    @Test
    void generatedSourceFacadesDeleteOnlyDraftsAndCallersReverseApprovals()
            throws Exception {
        for (Contract contract : List.of(
                contract(
                        "features/purchase/request/ProductionPurchaseRequestFacade.java",
                        "public void cancelGeneratedDraft("),
                contract(
                        "features/subcontract/application/ProductionSubcontractRequestFacade.java",
                        "public void closeGeneratedDraft("))) {
            String command = method(
                    source(contract.relativePath()), contract.ownerGate());
            int draftGate = command.indexOf(
                    "StandardDocumentLifecycleCapabilities");
            int mutation = command.indexOf("setDeleted(true)");
            assertThat(draftGate)
                    .as("draft-only generated-source cancel in %s",
                            contract.relativePath())
                    .isGreaterThanOrEqualTo(0);
            assertThat(mutation).isGreaterThan(draftGate);
        }

        String packageCancel = method(source(
                        "features/production/mrp/ProductionPlanningPackageService.java"),
                "private PlanningPackageLifecycleResult lifecycle(");
        assertThat(packageCancel)
                .contains("ProductionPurchaseRequestFacade.LifecycleAction.REVERSE")
                .contains("ProductionSubcontractRequestPort.LifecycleAction.REVERSE")
                .doesNotContain("ProductionPurchaseRequestFacade.LifecycleAction.CANCEL")
                .doesNotContain("ProductionSubcontractRequestPort.LifecycleAction.CANCEL");

        String analysisCancel = method(source(
                        "features/production/analysis/MaterialAnalysisCommandService.java"),
                "private void cancelActionLocked(");
        assertThat(analysisCancel)
                .contains("ProductionPurchaseRequestFacade.LifecycleAction.REVERSE")
                .contains("ProductionSubcontractRequestPort.LifecycleAction.REVERSE")
                .doesNotContain("ProductionPurchaseRequestFacade.LifecycleAction.CANCEL")
                .doesNotContain("ProductionSubcontractRequestPort.LifecycleAction.CANCEL");
    }

    @Test
    void legacyAssetDeletesAreAbsentAndControllerUsesDraftWorkflow()
            throws Exception {
        assertThat(source("features/finance/asset/FixedAssetService.java"))
                .doesNotContain("public void deleteAsset(")
                .doesNotContain("public void deleteDeferred(");
        assertThat(source("features/finance/asset/FixedAssetController.java"))
                .contains("workflow.deleteDraft(id, false, expectedVersion)")
                .contains("workflow.deleteDraft(id, true, expectedVersion)");
        String workflowDelete = method(source(
                        "features/finance/asset/application/FinanceAssetWorkflowService.java"),
                "public void deleteDraft(");
        assertThat(workflowDelete)
                .contains("FinanceAssetStateMachine.requireDraft(")
                .contains("lifecycle_status='DRAFT'");
    }

    private static List<Contract> contracts() {
        return List.of(
                contract("features/sales/quote/SalesQuoteService.java",
                        "requireWritableQuote(id)"),
                contract("features/sales/order/SalesOrderService.java",
                        "requireWritableOrderForUpdate(id)"),
                contract("features/sales/other_shipment/SalesOtherShipmentService.java",
                        "requireWritableShipment(id)"),
                contract("features/sales/ret/SalesReturnService.java",
                        "requireWritableReturnForUpdate(id)"),
                contract("features/purchase/order/PurchaseOrderService.java",
                        "access.requireWritable("),
                contract("features/purchase/receipt/PurchaseReceiptService.java",
                        "access.requireWritable("),
                contract("features/purchase/ret/PurchaseReturnService.java",
                        "access.requireWritable("),
                contract("features/subcontract/inquiry/SubcontractInquiryService.java",
                        "access.requireWritable("),
                contract("features/subcontract/order/SubcontractOrderService.java",
                        "access.requireWritable("),
                contract("features/subcontract/material_issue/SubcontractMaterialIssueService.java",
                        "requireIssueWritable("),
                contract("features/subcontract/material_return/SubcontractMaterialReturnService.java",
                        "access.requireWritable("),
                contract("features/subcontract/receipt/SubcontractReceiptService.java",
                        "access.requireWritable("),
                contract("features/subcontract/ret/SubcontractReturnService.java",
                        "access.requireWritable("),
                contract("features/subcontract/waste/SubcontractWasteService.java",
                        "access.requireWritable("),
                contract("features/production/plan/ProductionPlanService.java",
                        "access.requireWritable("),
                contract("features/production/dailyreport/ProductionDailyReportService.java",
                        "access.requireWritable("),
                contract("features/stock/StockDocService.java",
                        "access.requireWritable("));
    }

    private static Contract contract(String path, String ownerGate) {
        return new Contract(path, ownerGate);
    }

    private static String source(String relativePath) throws Exception {
        return Files.readString(JAVA.resolve(relativePath), StandardCharsets.UTF_8);
    }

    private static String method(String source, String signature) {
        int start = source.indexOf(signature);
        assertThat(start).as(signature).isGreaterThanOrEqualTo(0);
        int bodyStart = source.indexOf('{', start + signature.length());
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char token = source.charAt(index);
            if (token == '{') depth++;
            if (token == '}' && --depth == 0) {
                return source.substring(start, index + 1);
            }
        }
        throw new IllegalStateException("Unclosed method: " + signature);
    }

    private record Contract(String relativePath, String ownerGate) {
    }
}
