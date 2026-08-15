package com.uten.imp.features.stock;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AuthorizedBalanceAdjustmentProtectionTest {

    @Test
    void ordinaryStockEditorCannotReverseAuthorizedAdjustment() {
        EntityManager entityManager = mock(EntityManager.class);
        StockDocumentRepository documents = mock(StockDocumentRepository.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        StockDocService service = service(documents, entityManager, currentUser);

        UUID documentId = UUID.randomUUID();
        StockDocument document = authorizedDocument(documentId, (short) 1);
        when(entityManager.find(
                StockDocument.class,
                documentId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "pmc-user",
                Set.of(),
                Set.of("stock_doc:edit"),
                false,
                true,
                false)));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.reverse(documentId));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(documents, never()).save(document);
    }

    @Test
    void authorizedAdjustmentAuditRecordCannotBeDeletedAfterReverse() {
        EntityManager entityManager = mock(EntityManager.class);
        StockDocumentRepository documents = mock(StockDocumentRepository.class);
        StockDocService service = service(
                documents,
                entityManager,
                mock(SecurityContextCurrentUser.class));

        UUID documentId = UUID.randomUUID();
        StockDocument document = authorizedDocument(documentId, (short) -1);
        when(entityManager.find(
                StockDocument.class,
                documentId,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.delete(documentId));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(documents, never()).save(document);
    }

    private static StockDocument authorizedDocument(UUID id, short status) {
        StockDocument document = new StockDocument();
        document.setId(id);
        document.setDocType("CHECK");
        document.setStatus(status);
        return document;
    }

    private static StockDocService service(
            StockDocumentRepository documents,
            EntityManager entityManager,
            SecurityContextCurrentUser currentUser) {
        StockBalanceAdjustmentCommandRepository commands =
                mock(StockBalanceAdjustmentCommandRepository.class);
        when(commands.existsByStockDocumentId(any(UUID.class))).thenReturn(true);
        return new StockDocService(
                documents,
                commands,
                mock(StockDocumentItemRepository.class),
                mock(StockBalanceRepository.class),
                mock(StockService.class),
                mock(StockReservationService.class),
                mock(TxSessionVars.class),
                mock(DocNumberService.class),
                entityManager,
                currentUser,
                mock(EmployeeNameResolver.class),
                mock(ChainNoticeService.class),
                mock(com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService.class),
                mock(ProductionCompletionReversePort.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.features.stock.StockDocAccessPolicy.class));
    }
}
