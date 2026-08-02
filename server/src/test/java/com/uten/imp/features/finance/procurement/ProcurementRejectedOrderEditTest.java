package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementRejectedOrderEditTest {

    @Test
    void rejectedProductionLinkedPurchaseOrderCanBeEditedAndResubmitted() {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setBillNo("PO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository itemRepo = mock(PurchaseOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isPurchaseOrderLinked(orderId)).thenReturn(true);
        when(unitPolicy.normalizeAndValidate(
                goodsId, unitId, BigDecimal.ONE, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        unitId, BigDecimal.ONE));
        when(projection.latestForOrder("PURCHASE", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        PurchaseOrderService service = new PurchaseOrderService(
                orderRepo,
                itemRepo,
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                em,
                mock(DocNumberService.class),
                sourceGuard,
                unitPolicy,
                projection,
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class));

        com.uten.imp.features.purchase.order.dto.OrderSaveRequest request =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        request.setItems(List.of(purchaseLine(goodsId, unitId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        verify(projection).requireMutable("PURCHASE", orderId);
        verify(sourceGuard, never()).requirePurchaseOrderMutable(orderId);
    }

    @Test
    void rejectedProductionLinkedSubcontractOrderCanBeEditedAndResubmitted() {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        com.uten.imp.features.subcontract.order.SubcontractOrder order =
                new com.uten.imp.features.subcontract.order.SubcontractOrder();
        order.setId(orderId);
        order.setBillNo("SO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        var orderRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderRepository.class);
        var itemRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(
                com.uten.imp.features.subcontract.order.SubcontractOrder.class,
                orderId,
                LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isSubcontractOrderLinked(orderId)).thenReturn(true);
        when(projection.latestForOrder("SUBCONTRACT", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        var service = new com.uten.imp.features.subcontract.order.SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                sourceGuard,
                projection,
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class));

        var request =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        request.setItems(List.of(subcontractLine(goodsId, unitId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        verify(projection).requireMutable("SUBCONTRACT", orderId);
        verify(sourceGuard, never()).requireSubcontractOrderMutable(orderId);
    }

    private static FinanceApproval rejectedApproval() {
        return new FinanceApproval(
                UUID.randomUUID(),
                "REJECTED",
                1,
                2,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "财务负责人",
                "价格需修正",
                OffsetDateTime.now(),
                List.of("SUBMIT_FINANCE"));
    }

    private static com.uten.imp.features.purchase.order.dto.OrderItemLine purchaseLine(
            UUID goodsId, UUID unitId) {
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(BigDecimal.TEN);
        line.setAmountLocal(BigDecimal.TEN);
        line.setRequestItemId(UUID.randomUUID());
        return line;
    }

    private static com.uten.imp.features.subcontract.order.dto.OrderItemLine subcontractLine(
            UUID goodsId, UUID unitId) {
        var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(BigDecimal.TEN);
        line.setAmountLocal(BigDecimal.TEN);
        line.setApplicationItemId(UUID.randomUUID());
        return line;
    }
}
