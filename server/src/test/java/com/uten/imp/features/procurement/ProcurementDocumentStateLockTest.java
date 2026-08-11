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
            service("purchase/request/PurchaseRequestService.java", "PurchaseRequest", "requireRequestForUpdate"),
            financeOrderService(
                    "purchase/order/PurchaseOrderService.java",
                    "PurchaseOrder", "requireOrderForUpdate"),
            service("purchase/receipt/PurchaseReceiptService.java", "PurchaseReceipt", "requireReceiptForUpdate"),
            service("purchase/ret/PurchaseReturnService.java", "PurchaseReturn", "requireReturnForUpdate"),
            service("subcontract/application/SubcontractApplicationService.java", "SubcontractApplication", "requireApplicationForUpdate"),
            financeOrderService(
                    "subcontract/order/SubcontractOrderService.java",
                    "SubcontractOrder", "requireOrderForUpdate"),
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

            assertEquals(service.expectedLockCount(),
                    occurrences(source, "= " + service.helper() + "(id);"),
                    service.relativePath() + " must lock every scoped state transition before status checks");
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
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class));
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
                mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class));
        UUID id = UUID.randomUUID();
        SubcontractMaterialIssue committed = new SubcontractMaterialIssue();
        committed.setStatus((short) 1);
        when(em.find(SubcontractMaterialIssue.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(committed);

        assertThatThrownBy(() -> service.approve(id)).isInstanceOf(ApiException.class);

        verify(em).find(SubcontractMaterialIssue.class, id, LockModeType.PESSIMISTIC_WRITE);
        verify(repository, never()).findById(any(UUID.class));
        verify(repository, never()).save(any(SubcontractMaterialIssue.class));
        verifyNoInteractions(items, stock);
    }

    private static LockedService service(String relativePath, String entity, String helper) {
        return new LockedService(relativePath, entity, helper, 4);
    }

    private static LockedService financeOrderService(
            String relativePath, String entity, String helper) {
        // update/delete/submit-finance/apply-finance-approval/reverse
        return new LockedService(relativePath, entity, helper, 5);
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = source.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }

    private record LockedService(
            String relativePath, String entity, String helper, int expectedLockCount) {
    }
}
