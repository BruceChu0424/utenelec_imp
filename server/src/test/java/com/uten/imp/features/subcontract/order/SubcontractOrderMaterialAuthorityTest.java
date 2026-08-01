package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractOrderMaterialAuthorityTest {

    private SubcontractOrderRepository orderRepo;
    private SubcontractOrderItemRepository itemRepo;
    private ProductionSubcontractSupplyTransitionPort productionSupply;
    private EntityManager em;
    private Query query;
    private SubcontractOrderService service;

    @BeforeEach
    void setUp() {
        orderRepo = mock(SubcontractOrderRepository.class);
        itemRepo = mock(SubcontractOrderItemRepository.class);
        productionSupply =
                mock(ProductionSubcontractSupplyTransitionPort.class);
        em = mock(EntityManager.class);
        query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        service = new SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                productionSupply,
                mock(ProductionSupplySourceGuard.class));
    }

    @Test
    void reverseIgnoresStaleLegacyChildTotalsAfterAllChildDocumentsAreReversed() {
        UUID id = UUID.randomUUID();
        SubcontractOrder document = document(id);
        SubcontractOrderItem item = item(id);
        item.setIssuedQty(new BigDecimal("999"));
        item.setMaterialReturnedQty(new BigDecimal("998"));
        stubDocument(id, document, item);
        when(query.getSingleResult()).thenReturn(false);

        service.reverse(id);

        assertEquals((short) -1, document.getStatus());
        verify(productionSupply).onSubcontractOrderReversed(id);
        verify(orderRepo).save(document);
    }

    @Test
    void reverseBlocksOnApprovedChildDocumentsEvenWhenLegacyTotalsAreZero() {
        UUID id = UUID.randomUUID();
        SubcontractOrder document = document(id);
        SubcontractOrderItem item = item(id);
        stubDocument(id, document, item);
        when(query.getSingleResult()).thenReturn(true);

        assertThrows(ApiException.class, () -> service.reverse(id));

        verify(productionSupply, never()).onSubcontractOrderReversed(any());
        verify(orderRepo, never()).save(any(SubcontractOrder.class));
    }

    private void stubDocument(
            UUID id,
            SubcontractOrder document,
            SubcontractOrderItem item) {
        when(em.find(
                SubcontractOrder.class,
                id,
                LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(itemRepo.findByOrderIdOrderByLineNoAsc(id))
                .thenReturn(List.of(item));
        when(orderRepo.findById(id)).thenReturn(Optional.of(document));
    }

    private static SubcontractOrder document(UUID id) {
        SubcontractOrder document = new SubcontractOrder();
        document.setId(id);
        document.setBillNo("EO202608010001");
        document.setBillDate(LocalDate.of(2026, 8, 1));
        document.setStatus((short) 1);
        document.setTotalLocal(BigDecimal.ZERO);
        document.setTotalOriginal(BigDecimal.ZERO);
        return document;
    }

    private static SubcontractOrderItem item(UUID orderId) {
        SubcontractOrderItem item = new SubcontractOrderItem();
        item.setOrderId(orderId);
        item.setGoodsId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.ONE);
        item.setReceivedQty(BigDecimal.ZERO);
        item.setReturnedQty(BigDecimal.ZERO);
        item.setIssuedQty(BigDecimal.ZERO);
        item.setMaterialReturnedQty(BigDecimal.ZERO);
        return item;
    }
}
