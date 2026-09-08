package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
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
import org.mockito.ArgumentMatchers;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 2026-09 起订货允许超过申请剩余量（超采备货）：提交财务不再做
 * 「已订 + 其它待审 + 本单 <= 申请量」容量校验，来源完整性（已审/未中止/维度一致）
 * 仍逐行校验。本测试锁定「超容量也可提交」的放行口径。
 */
class PurchaseOrderPendingCapacityTest {

    @Test
    void overbookingRequestRemainderNoLongerBlocksFinanceSubmission() {
        UUID orderId = UUID.randomUUID();
        UUID sourceItemId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID currencyId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();

        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setBillNo("PO-OVER");
        order.setBillDate(LocalDate.of(2026, 9, 3));
        order.setSupplierId(supplierId);
        order.setCurrencyId(currencyId);
        order.setExchangeRate(BigDecimal.ONE);
        order.setTaxRate(BigDecimal.ZERO);
        order.setTotalOriginal(new BigDecimal("6.0000"));
        order.setTotalLocal(new BigDecimal("6.0000"));
        order.setSettlementMethodId(UUID.randomUUID());
        order.setStatus((short) 0);

        PurchaseOrderItem item = new PurchaseOrderItem();
        item.setId(UUID.randomUUID());
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
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);
        when(em.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(itemRepo.findByOrderIdOrderByLineNoAsc(orderId))
                .thenReturn(List.of(item));
        when(unitPolicy.normalizeAndValidate(
                goodsId, unitId, BigDecimal.ONE, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        unitId, BigDecimal.ONE));
        // 送审前的结算方式有效性查询（settlement_methods 计数）
        Query settlementQuery = mock(Query.class);
        when(em.createNativeQuery(
                ArgumentMatchers.contains(
                        "FROM settlement_methods")))
                .thenReturn(settlementQuery);
        // V463 来源分配行查询（单来源行 = 全量 alloc）。
        Query sourcesQuery = mock(Query.class);
        when(em.createNativeQuery(
                ArgumentMatchers.contains(
                        "FROM purchase_order_item_sources")))
                .thenReturn(sourcesQuery);
        when(sourcesQuery.setParameter(
                ArgumentMatchers.anyString(),
                ArgumentMatchers.any()))
                .thenReturn(sourcesQuery);
        when(sourcesQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{item.getId(), sourceItemId, "REQ-1",
                        new BigDecimal("6.0000"), UUID.randomUUID()}));
        when(settlementQuery.setParameter(
                ArgumentMatchers.anyString(),
                ArgumentMatchers.any()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getSingleResult()).thenReturn(1L);
        Query currencyQuery = mock(Query.class);
        when(em.createNativeQuery(
                ArgumentMatchers.contains(
                        "FROM currencies")))
                .thenReturn(currencyQuery);
        when(currencyQuery.setParameter(
                ArgumentMatchers.anyString(),
                ArgumentMatchers.any()))
                .thenReturn(currencyQuery);
        when(currencyQuery.getSingleResult()).thenReturn(1L);

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
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                // 2026-09-05 cancel() 撤回财务弹卡用；本测试不触达，传 mock 即可。
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));

        // 数量超过申请剩余量：不再抛「超过申请剩余量」，送审校验通过。
        assertDoesNotThrow(() -> service.lockAndValidateFinanceSubmission(orderId));
        verify(sourceIntegrity).validatePurchaseOrder(anyList());
    }
}
