package com.uten.imp.features.purchase.request;

import com.uten.imp.common.docnumber.DocNumberService;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionPurchaseRequestFacadeTest {

    @Test
    void generatedDraftKeepsThePlanningWarehouse() {
        PurchaseRequestRepository requestRepo =
                mock(PurchaseRequestRepository.class);
        PurchaseRequestItemRepository itemRepo =
                mock(PurchaseRequestItemRepository.class);
        DocNumberService numberService = mock(DocNumberService.class);
        when(numberService.nextNumber(any())).thenReturn("CS-TEST");
        ProductionPurchaseRequestFacade facade =
                new ProductionPurchaseRequestFacade(
                        requestRepo,
                        itemRepo,
                        numberService,
                        mock(EntityManager.class));

        UUID warehouseId = UUID.randomUUID();
        facade.createProductionDraft(
                "PP-TEST",
                LocalDate.of(2026, 8, 7),
                warehouseId,
                List.of(new ProductionPurchaseRequestFacade.DraftLine(
                        UUID.randomUUID(),
                        UUID.randomUUID(),
                        null,
                        UUID.randomUUID(),
                        BigDecimal.ONE,
                        LocalDate.of(2026, 8, 6),
                        "execution shortage")),
                UUID.randomUUID(),
                UUID.randomUUID());

        ArgumentCaptor<PurchaseRequest> request =
                ArgumentCaptor.forClass(PurchaseRequest.class);
        verify(requestRepo, atLeastOnce()).save(request.capture());
        assertThat(request.getValue().getWarehouseId())
                .isEqualTo(warehouseId);
    }
}
