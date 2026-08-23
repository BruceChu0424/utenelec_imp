package com.uten.imp.features.sales.ret;

import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesReturnQualityOwnerBoundaryTest {

    private static final String CORRECT_AUTHORITY = "sales_return_quality:correct";
    private static final String DISPOSE_AUTHORITY = "sales_return_quality:dispose";

    private final EntityManager em = mock(EntityManager.class);
    private final StockService stockService = mock(StockService.class);
    private final SecurityContextCurrentUser currentUser =
            mock(SecurityContextCurrentUser.class);
    private final TxSessionVars tx = mock(TxSessionVars.class);
    private final SalesReturnRepository returnRepo =
            mock(SalesReturnRepository.class);
    private final SalesDocumentAccessPolicy accessPolicy =
            mock(SalesDocumentAccessPolicy.class);
    private final SalesReturnQualityService service =
            new SalesReturnQualityService(
                    em, stockService, currentUser, tx, returnRepo, accessPolicy);

    @Test
    void handlerReadUsesTheSameCrossOwnerAuthorityAsDisposition() {
        UUID returnId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        SalesReturn salesReturn = ownedReturn(ownerId);
        when(returnRepo.findById(returnId)).thenReturn(Optional.of(salesReturn));
        BoundaryReached stop = new BoundaryReached();
        doThrow(stop).when(accessPolicy).requireReadable(
                ownerId, "销售退货单不存在", CORRECT_AUTHORITY, DISPOSE_AUTHORITY);

        assertThrows(BoundaryReached.class, () -> service.list(returnId));

        verify(accessPolicy).requireReadable(
                ownerId, "销售退货单不存在", CORRECT_AUTHORITY, DISPOSE_AUTHORITY);
    }

    @Test
    void dispositionChecksTheReturnOwnerBeforeLookingUpTheQualityRow() {
        UUID returnId = UUID.randomUUID();
        UUID returnItemId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        SalesReturn salesReturn = ownedReturn(ownerId);
        when(returnRepo.findById(returnId)).thenReturn(Optional.of(salesReturn));
        BoundaryReached stop = new BoundaryReached();
        doThrow(stop).when(accessPolicy).requireWritable(
                ownerId, "无权处置该销售退货质检冻结", DISPOSE_AUTHORITY);

        ReturnQualityDispositionRequest request =
                new ReturnQualityDispositionRequest(
                        "GOOD_RELEASE", BigDecimal.ONE, "检验合格",
                        "quality-owner-001");

        assertThrows(
                BoundaryReached.class,
                () -> service.dispose(returnId, returnItemId, request));

        verify(accessPolicy).requireWritable(
                ownerId, "无权处置该销售退货质检冻结", DISPOSE_AUTHORITY);
        verify(tx).bind();
    }

    private static SalesReturn ownedReturn(UUID ownerId) {
        SalesReturn salesReturn = new SalesReturn();
        salesReturn.setOwnerEmployeeId(ownerId);
        return salesReturn;
    }

    private static final class BoundaryReached extends RuntimeException {
    }
}
