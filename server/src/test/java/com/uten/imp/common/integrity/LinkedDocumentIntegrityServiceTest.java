package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class LinkedDocumentIntegrityServiceTest {

    private EntityManager em;
    private Query query;
    private LinkedDocumentIntegrityService service;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        service = new LinkedDocumentIntegrityService(em);
    }

    @Test
    void purchaseReceiptRejectsOrderFromAnotherSupplier() {
        UUID sourceItem = UUID.randomUUID();
        UUID requestedSupplier = UUID.randomUUID();
        UUID sourceSupplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                sourceItem, sourceSupplier, goods, color, unit,
                BigDecimal.ONE, (short) 1, false
        }));

        assertThrows(ApiException.class, () -> service.validatePurchaseReceipt(
                requestedSupplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(
                        sourceItem, goods, color, unit, BigDecimal.ONE))));
    }

    @Test
    void purchaseOrderRejectsAllocationBeyondRequestRemainder() {
        UUID requestItem = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                requestItem,
                goods,
                null,
                unit,
                BigDecimal.ONE,
                new BigDecimal("100"),
                new BigDecimal("80"),
                (short) 1,
                false
        }));

        assertThrows(ApiException.class, () -> service.validatePurchaseOrder(
                List.of(new LinkedDocumentIntegrityService.QuantityLinkedLine(
                        requestItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE,
                        new BigDecimal("30")))));
    }

    @Test
    void purchaseReturnRejectsReceiptPairedWithAnotherOrderItem() {
        UUID receiptItem = UUID.randomUUID();
        UUID actualOrderItem = UUID.randomUUID();
        UUID forgedOrderItem = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                receiptItem,
                supplier,
                goods,
                null,
                unit,
                BigDecimal.ONE,
                actualOrderItem,
                (short) 1
        }));

        assertThrows(ApiException.class, () -> service.validatePurchaseReturn(
                supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.receiptSource(
                        receiptItem,
                        forgedOrderItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE))));
    }

    @Test
    void subcontractOrderRejectsApplicationFromAnotherSupplier() {
        UUID applicationItem = UUID.randomUUID();
        UUID requestedSupplier = UUID.randomUUID();
        UUID sourceSupplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                applicationItem,
                sourceSupplier,
                goods,
                null,
                unit,
                BigDecimal.ONE,
                new BigDecimal("100"),
                BigDecimal.ZERO,
                (short) 1
        }));

        assertThrows(ApiException.class, () -> service.validateSubcontractOrder(
                requestedSupplier,
                List.of(new LinkedDocumentIntegrityService.QuantityLinkedLine(
                        applicationItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE,
                        BigDecimal.ONE))));
    }

    @Test
    void subcontractReturnRejectsReceiptPairedWithAnotherOrderItem() {
        UUID receiptItem = UUID.randomUUID();
        UUID actualOrderItem = UUID.randomUUID();
        UUID forgedOrderItem = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                receiptItem,
                supplier,
                goods,
                null,
                unit,
                BigDecimal.ONE,
                actualOrderItem,
                (short) 1
        }));

        assertThrows(ApiException.class, () -> service.validateSubcontractReturn(
                supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.receiptSource(
                        receiptItem,
                        forgedOrderItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE))));
    }

    @Test
    void subcontractWasteRejectsGoodsForgedAgainstMaterialIssue() {
        UUID issueItem = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID actualGoods = UUID.randomUUID();
        UUID forgedGoods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                issueItem,
                supplier,
                actualGoods,
                null,
                unit,
                BigDecimal.ONE,
                null,
                null,
                null,
                (short) 1
        }));

        assertThrows(ApiException.class, () ->
                service.validateSubcontractWaste(
                        supplier,
                        List.of(LinkedDocumentIntegrityService.LinkedLine.materialIssueSource(
                                issueItem,
                                null,
                                forgedGoods,
                                null,
                                unit,
                                BigDecimal.ONE,
                                null,
                                null))));
    }

    @Test
    void purchaseReceiptRejectsChangedUnitRate() {
        UUID sourceItem = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                sourceItem,
                supplier,
                goods,
                null,
                unit,
                new BigDecimal("12"),
                (short) 1,
                false
        }));

        assertThrows(ApiException.class, () -> service.validatePurchaseReceipt(
                supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(
                        sourceItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE))));
    }

    @Test
    void subcontractOrderRejectsChangedUnitRate() {
        UUID applicationItem = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[] {
                applicationItem,
                supplier,
                goods,
                null,
                unit,
                new BigDecimal("10"),
                new BigDecimal("100"),
                BigDecimal.ZERO,
                (short) 1
        }));

        assertThrows(ApiException.class, () -> service.validateSubcontractOrder(
                supplier,
                List.of(new LinkedDocumentIntegrityService.QuantityLinkedLine(
                        applicationItem,
                        goods,
                        null,
                        unit,
                        BigDecimal.ONE,
                        BigDecimal.TEN))));
    }

    @Test
    void subcontractWasteRequiresAnApprovedMaterialIssueSource() {
        assertThrows(ApiException.class, () ->
                service.validateSubcontractWaste(
                        UUID.randomUUID(),
                        List.of(LinkedDocumentIntegrityService.LinkedLine.materialIssueSource(
                                null,
                                null,
                                UUID.randomUUID(),
                                null,
                                UUID.randomUUID(),
                                BigDecimal.ONE,
                                null,
                                null))));
    }
}
