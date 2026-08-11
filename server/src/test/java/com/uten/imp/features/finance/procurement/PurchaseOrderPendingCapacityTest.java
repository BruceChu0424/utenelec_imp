package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderItem;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PurchaseOrderPendingCapacityTest {

    @Test
    void secondPendingOrderOnSameSourceCannotOverbookCapacity() {
        UUID orderId = UUID.randomUUID();
        UUID sourceItemId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();

        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setBillNo("PO-SECOND");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setSupplierId(supplierId);
        order.setExchangeRate(BigDecimal.ONE);
        order.setTotalOriginal(new BigDecimal("6.0000"));
        order.setTotalLocal(new BigDecimal("6.0000"));
        order.setStatus((short) 0);

        PurchaseOrderItem item = new PurchaseOrderItem();
        item.setOrderId(orderId);
        item.setRequestItemId(sourceItemId);
        item.setLineNo(1);
        item.setGoodsId(goodsId);
        item.setUnitId(unitId);
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("6.0000"));
        item.setPrice(BigDecimal.ONE);
        item.setAmountOriginal(new BigDecimal("6.0000"));
        item.setAmountLocal(new BigDecimal("6.0000"));

        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository itemRepo =
                mock(PurchaseOrderItemRepository.class);
        LinkedDocumentIntegrityService sourceIntegrity =
                mock(LinkedDocumentIntegrityService.class);
        EntityManager em = mock(EntityManager.class);
        Query sourceLockQuery = mock(Query.class);
        Query capacityQuery = mock(Query.class);
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);
        when(em.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(itemRepo.findByOrderIdOrderByLineNoAsc(orderId))
                .thenReturn(List.of(item));
        when(unitPolicy.normalizeAndValidate(
                goodsId, unitId, BigDecimal.ONE, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        unitId, BigDecimal.ONE));
        when(em.createNativeQuery(
                org.mockito.ArgumentMatchers.contains(
                        "FOR UPDATE OF source")))
                .thenReturn(sourceLockQuery);
        when(sourceLockQuery.setParameter(
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any()))
                .thenReturn(sourceLockQuery);
        when(sourceLockQuery.getResultList()).thenReturn(List.of(sourceItemId));
        when(em.createNativeQuery(
                org.mockito.ArgumentMatchers.contains(
                        "approval_case.status = 'PENDING'")))
                .thenReturn(capacityQuery);
        when(capacityQuery.setParameter(
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any()))
                .thenReturn(capacityQuery);
        when(capacityQuery.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{
                        sourceItemId,
                        new BigDecimal("10.0000"),
                        BigDecimal.ZERO,
                        new BigDecimal("5.0000")
                }));

        PurchaseOrderService service = new PurchaseOrderService(
                orderRepo,
                itemRepo,
                sourceIntegrity,
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                em,
                mock(DocNumberService.class),
                mock(ProductionSupplySourceGuard.class),
                unitPolicy,
                mock(ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.lockAndValidateFinanceSubmission(orderId));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("其它待财务审核订单"));
        org.mockito.Mockito.verify(sourceIntegrity)
                .validatePurchaseOrder(anyList());
    }
}
