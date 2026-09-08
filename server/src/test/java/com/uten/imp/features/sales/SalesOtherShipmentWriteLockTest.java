package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipment;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipmentItemRepository;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipmentRepository;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

class SalesOtherShipmentWriteLockTest {
    @Test
    void negativeQuantityRateAndAmountsCannotReachInventory() {
        for (int invalidField = 0; invalidField < 3; invalidField++) {
            var document = new SalesOtherShipment();
            document.setStatus((short)1);
            document.setWarehouseId(UUID.randomUUID());
            document.setTotalOriginal(java.math.BigDecimal.ONE);
            document.setTotalLocal(java.math.BigDecimal.ONE);
            var item = new com.uten.imp.features.sales.other_shipment.SalesOtherShipmentItem();
            item.setQty(java.math.BigDecimal.ONE);
            item.setUnitRate(java.math.BigDecimal.ONE);
            item.setAmountOriginal(java.math.BigDecimal.ONE);
            item.setAmountLocal(java.math.BigDecimal.ONE);
            if (invalidField == 0) {
                item.setQty(java.math.BigDecimal.ONE.negate());
                item.setUnitRate(java.math.BigDecimal.ONE.negate());
            } else if (invalidField == 1) {
                item.setUnitRate(java.math.BigDecimal.ZERO);
            } else {
                item.setAmountLocal(java.math.BigDecimal.ONE.negate());
            }
            var repository = mock(SalesOtherShipmentRepository.class);
            var items = mock(SalesOtherShipmentItemRepository.class);
            var stock = mock(com.uten.imp.features.stock.StockService.class);
            var em = mock(EntityManager.class);
            when(repository.findById(document.getId())).thenReturn(Optional.of(document));
            when(em.find(SalesOtherShipment.class, document.getId(), LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
            when(items.findByShipmentIdOrderByLineNoAsc(document.getId())).thenReturn(java.util.List.of(item));
            var service = new SalesOtherShipmentService(repository, items, stock, mock(TxSessionVars.class),
                    em, null, mock(SalesDocumentAccessPolicy.class),
                org.mockito.Mockito.mock(com.uten.imp.features.sales.SalesMutationFootprintService.class));
            assertThrows(ApiException.class, () -> service.reverse(document.getId()));
            verifyNoInteractions(stock);
        }
    }

    @Test
    void retiredHistoricalWritesNeverReachDocumentOrInventoryMutations() {
        UUID id = UUID.randomUUID();
        SalesOtherShipment stale = new SalesOtherShipment();
        stale.setId(id);
        stale.setStatus((short) 0);
        SalesOtherShipment current = new SalesOtherShipment();
        current.setId(id);
        current.setStatus((short) 1);
        SalesOtherShipmentRepository documents = mock(SalesOtherShipmentRepository.class);
        SalesOtherShipmentItemRepository items = mock(SalesOtherShipmentItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        when(documents.findById(id)).thenReturn(Optional.of(stale));
        when(em.find(SalesOtherShipment.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(current);
        SalesOtherShipmentService service = new SalesOtherShipmentService(documents, items,
                null, mock(TxSessionVars.class), em, null,
                mock(SalesDocumentAccessPolicy.class),
                org.mockito.Mockito.mock(com.uten.imp.features.sales.SalesMutationFootprintService.class));
        assertThrows(ApiException.class, () -> service.update(id, new OtherShipmentSaveRequest()));
        assertThrows(ApiException.class, () -> service.delete(id));
        assertThrows(ApiException.class, () -> service.create(new OtherShipmentSaveRequest()));
        assertThrows(ApiException.class, () -> service.approve(id));
        verifyNoInteractions(em);
        verifyNoInteractions(items);
        verify(documents, never()).save(current);
        verify(documents, never()).save(stale);
    }
}
