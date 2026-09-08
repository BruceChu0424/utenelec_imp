package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityItemDto;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SalesReturnQualityIdempotencyReplayTest {

    private final EntityManager em = mock(EntityManager.class);
    private final StockService stockService = mock(StockService.class);
    private final SecurityContextCurrentUser currentUser =
            mock(SecurityContextCurrentUser.class);
    private final TxSessionVars tx = mock(TxSessionVars.class);
    private final SalesReturnRepository returnRepo = mock(SalesReturnRepository.class);
    private final SalesDocumentAccessPolicy accessPolicy =
            mock(SalesDocumentAccessPolicy.class);
    private final SalesReturnQualityService service = new SalesReturnQualityService(
            em, stockService, currentUser, tx, returnRepo, accessPolicy,
                org.mockito.Mockito.mock(com.uten.imp.features.sales.SalesMutationFootprintService.class, org.mockito.Mockito.RETURNS_DEEP_STUBS), org.mockito.Mockito.mock(com.uten.imp.application.port.SalesReturnInventoryValuePort.class));

    @Test
    void exactReplayReturnsCurrentProjectionWithoutRepeatingStockEffects() {
        UUID returnId = UUID.randomUUID();
        UUID returnItemId = UUID.randomUUID();
        UUID qualityItemId = UUID.randomUUID();
        stubReplay(returnId, qualityItemId, BigDecimal.ONE);

        List<ReturnQualityItemDto> result = service.dispose(
                returnId, returnItemId, request(BigDecimal.ONE));

        assertTrue(result.isEmpty());
        verifyNoInteractions(stockService);
    }

    @Test
    void sameKeyWithDifferentPayloadFailsBeforeStockEffects() {
        UUID returnId = UUID.randomUUID();
        UUID returnItemId = UUID.randomUUID();
        UUID qualityItemId = UUID.randomUUID();
        stubReplay(returnId, qualityItemId, BigDecimal.ONE);

        assertThrows(ApiException.class,
                () -> service.dispose(returnId, returnItemId,
                        request(new BigDecimal("2"))));
        verifyNoInteractions(stockService);
    }

    private void stubReplay(UUID returnId, UUID qualityItemId,
                            BigDecimal storedQuantity) {
        SalesReturn salesReturn = new SalesReturn();
        salesReturn.setOwnerEmployeeId(UUID.randomUUID());
        when(returnRepo.findById(returnId)).thenReturn(Optional.of(salesReturn));

        Object[] qualityRow = new Object[13];
        qualityRow[0] = qualityItemId;
        qualityRow[10] = "PARTIAL";
        qualityRow[12] = Short.valueOf((short) 1);
        Query qualityQuery = queryReturning(java.util.Collections.singletonList(qualityRow));
        Query eventQuery = queryReturning(java.util.Collections.singletonList(new Object[]{
                qualityItemId, "GOOD_RELEASE", storedQuantity, "qualified"
        }));
        Query projectionQuery = queryReturning(List.of());

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("FROM sales_return_quality_items q")) {
                return qualityQuery;
            }
            if (sql.contains("FROM sales_return_quality_events")) {
                return eventQuery;
            }
            if (sql.contains("SELECT id, return_id, return_item_id")) {
                return projectionQuery;
            }
            throw new AssertionError("Unexpected SQL after idempotent replay: " + sql);
        });
    }

    private static Query queryReturning(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }

    private static ReturnQualityDispositionRequest request(BigDecimal quantity) {
        return new ReturnQualityDispositionRequest(
                "GOOD_RELEASE", quantity, "qualified", "quality-replay-001");
    }
}
