package com.uten.imp.features.procurement;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.request.PurchaseRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestItemRepository;
import com.uten.imp.features.purchase.request.PurchaseRequestRepository;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import com.uten.imp.support.DraftMutationSourceContract;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementDocumentStateLockTest {

    private static final List<LockedService> LOCKED_SERVICES = List.of(
            // V812 死代码清理删掉手动 reverse(4→3)：申请已是计划下达的只读事实。
            financeOrderService(
                    "purchase/request/PurchaseRequestService.java",
                    "PurchaseRequest", "requireRequestForUpdate", "update", "delete", "approve"),
            financeOrderService(
                    "purchase/order/PurchaseOrderService.java",
                    "PurchaseOrder", "requireOrderForUpdate", "update", "delete", "cancel",
                    "requireFinanceSubmitterWritable", "lockAndValidateFinanceSubmission", "applyFinanceApproval",
                    "reverse", "isFinanceApproved", "lockFinanceReconfirmationSnapshot", "changeQty"),
            service("purchase/receipt/PurchaseReceiptService.java", "PurchaseReceipt", "requireReceiptForUpdate"),
            service("purchase/ret/PurchaseReturnService.java", "PurchaseReturn", "requireReturnForUpdate"),
            // V812 死代码清理删掉手动 approve/reverse(4→2)：申请=计划下达只读事实，
            // 审批快照由 ProductionSubcontractRequestFacade 承担。
            financeOrderService(
                    "subcontract/application/SubcontractApplicationService.java",
                    "SubcontractApplication", "requireApplicationForUpdate", "update", "delete"),
            financeOrderService(
                    "subcontract/order/SubcontractOrderService.java",
                    "SubcontractOrder", "requireOrderForUpdate", "update", "delete", "requireFinanceSubmitterWritable",
                    "lockAndValidateFinanceSubmission", "isFinanceApproved",
                    "lockFinanceReconfirmationSnapshot", "changeQtyInternal", "applyFinanceApproval", "reverse"),
            service("subcontract/receipt/SubcontractReceiptService.java", "SubcontractReceipt", "requireReceiptForUpdate"),
            service("subcontract/ret/SubcontractReturnService.java", "SubcontractReturn", "requireReturnForUpdate"),
            service("subcontract/material_issue/SubcontractMaterialIssueService.java", "SubcontractMaterialIssue", "requireIssueForUpdate"),
            service("subcontract/material_return/SubcontractMaterialReturnService.java", "SubcontractMaterialReturn", "requireReturnForUpdate"),
            service("subcontract/waste/SubcontractWasteService.java", "SubcontractWaste", "requireWasteForUpdate"));

    @Test
    void allScopedMutationsAcquireTheHeaderWithDirectPessimisticFind() throws IOException {
        for (LockedService service : LOCKED_SERVICES) {
            String source = Files.readString(Path.of("src/main/java/com/uten/imp/features")
                    .resolve(service.relativePath()));

            var lockingMethods = DraftMutationSourceContract.methodNamesCalling(
                    source, "= " + service.helper() + "(id);");
            org.assertj.core.api.Assertions.assertThat(lockingMethods)
                    .as("explicit scoped transition coverage for %s", service.relativePath())
                    .containsExactlyInAnyOrderElementsOf(service.mutations());
            for (String name : service.mutations()) {
                String body = DraftMutationSourceContract.methodContaining(source, name,
                        "= " + service.helper() + "(id);");
                int locked = body.indexOf("= " + service.helper() + "(id);");
                assertTrue(locked >= 0, name + " must acquire the locked header");
                for (String guarded : List.of("getStatus()", "access.requireWritable(",
                        "requireReviewer(", "itemRepo.find", "repo.save(")) {
                    int boundary = body.indexOf(guarded);
                    if (guarded.equals("itemRepo.find") && body.contains("prelockItems")) {
                        // Inventory dimensions are sampled before the header to
                        // preserve the global inventory->document lock order.
                        // Business facts must be reloaded and their dimensions
                        // reconciled after the direct locked header read.
                        org.assertj.core.api.Assertions.assertThat(body).contains(
                                "stockService.lockInventory(prelockItems.stream()",
                                "requireSameInventoryDimensions(prelockItems, items)");
                        boundary = body.lastIndexOf(guarded);
                    }
                    if (boundary >= 0) assertTrue(locked < boundary,
                            service.relativePath() + ":" + name + " must lock before " + guarded);
                }
            }
            assertTrue(source.contains(service.entity()
                            + ".class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE"),
                    service.relativePath() + " must use a direct locked find");
            assertFalse(source.contains("em.lock("),
                    service.relativePath() + " must not read an unlocked entity and lock it afterwards");
        }
    }

    @Test
    void secondPurchaseRequestApprovalSeesCommittedStatusAndStopsBeforeSideEffects() {
        PurchaseRequestRepository repository = mock(PurchaseRequestRepository.class);
        PurchaseRequestItemRepository items = mock(PurchaseRequestItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        PurchaseRequestService service = new PurchaseRequestService(
                repository,
                items,
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                em,
                mock(com.uten.imp.common.integrity
                        .ProductionSupplySourceGuard.class),
                mock(PurchaseLineUnitPolicy.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.application.port.OrganizationReferencePort.class));
        UUID id = UUID.randomUUID();
        PurchaseRequest committed = new PurchaseRequest();
        committed.setStatus((short) 1);
        when(em.find(PurchaseRequest.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(committed);

        assertThatThrownBy(() -> service.approve(id)).isInstanceOf(ApiException.class);

        verify(em).find(PurchaseRequest.class, id, LockModeType.PESSIMISTIC_WRITE);
        verify(repository, never()).findById(any(UUID.class));
        verify(repository, never()).save(any(PurchaseRequest.class));
        verifyNoInteractions(items);
    }

    @Test
    void secondMaterialIssueApprovalStopsBeforeDuplicateInventoryMovement() {
        SubcontractMaterialIssueRepository repository = mock(SubcontractMaterialIssueRepository.class);
        SubcontractMaterialIssueItemRepository items = mock(SubcontractMaterialIssueItemRepository.class);
        StockService stock = mock(StockService.class);
        EntityManager em = mock(EntityManager.class);
        SubcontractMaterialIssueService service = new SubcontractMaterialIssueService(
                repository,
                items,
                stock,
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class),
                        mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class),
                org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));
        UUID id = UUID.randomUUID();
        SubcontractMaterialIssue committed = new SubcontractMaterialIssue();
        committed.setStatus((short) 1);
        when(em.find(SubcontractMaterialIssue.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(committed);

        assertThatThrownBy(() -> service.approve(id))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("仅草稿单据可审核");

        verify(em).find(SubcontractMaterialIssue.class, id, LockModeType.PESSIMISTIC_WRITE);
        verify(repository, never()).findById(any(UUID.class));
        verify(repository, never()).save(any(SubcontractMaterialIssue.class));
        verifyNoInteractions(items, stock);
    }

    private static LockedService service(String relativePath, String entity, String helper) {
        List<String> mutations = relativePath.contains("receipt/")
                ? List.of("update", "delete", "approveReceipt", "reverse")
                : relativePath.contains("/ret/")
                ? List.of("update", "delete", "approve", "reverse")
                : relativePath.contains("waste/")
                ? List.of("update", "delete", "approveInternal", "reverse")
                : List.of("update", "delete", "approve", "reverse");
        return new LockedService(relativePath, entity, helper, mutations);
    }

    private static LockedService financeOrderService(
            String relativePath, String entity, String helper, String... mutations) {
        return new LockedService(relativePath, entity, helper, List.of(mutations));
    }

    private record LockedService(
            String relativePath, String entity, String helper, List<String> mutations) { }
}
