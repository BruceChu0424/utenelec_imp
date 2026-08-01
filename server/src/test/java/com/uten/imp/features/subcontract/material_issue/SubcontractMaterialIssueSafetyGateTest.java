package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SubcontractMaterialIssueSafetyGateTest {

    @Test
    void draftApprovalFailsClosedBeforeReadingItemsOrPostingInventory() {
        SubcontractMaterialIssueRepository issueRepo =
                mock(SubcontractMaterialIssueRepository.class);
        SubcontractMaterialIssueItemRepository itemRepo =
                mock(SubcontractMaterialIssueItemRepository.class);
        StockService stockService = mock(StockService.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        EntityManager em = mock(EntityManager.class);
        SubcontractMaterialIssueService service =
                new SubcontractMaterialIssueService(
                        issueRepo,
                        itemRepo,
                        stockService,
                        tx,
                        em,
                        mock(SecurityContextCurrentUser.class),
                        mock(EmployeeNameResolver.class),
                        mock(DocNumberService.class));

        UUID id = UUID.randomUUID();
        SubcontractMaterialIssue document = new SubcontractMaterialIssue();
        document.setId(id);
        document.setStatus((short) 0);
        document.setWarehouseId(UUID.randomUUID());
        when(em.find(
                SubcontractMaterialIssue.class,
                id,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);

        ApiException error =
                assertThrows(ApiException.class, () -> service.approve(id));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("BOM 版本"));
        assertTrue(error.getMessage().contains("子件发料台账"));
        verify(tx).bind();
        verify(em).find(
                SubcontractMaterialIssue.class,
                id,
                LockModeType.PESSIMISTIC_WRITE);
        verify(issueRepo, never()).save(any(SubcontractMaterialIssue.class));
        verifyNoInteractions(itemRepo, stockService);
    }
}
