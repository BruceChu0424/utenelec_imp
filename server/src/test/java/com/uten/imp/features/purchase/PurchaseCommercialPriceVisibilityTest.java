package com.uten.imp.features.purchase;

import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderItem;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.features.purchase.order.dto.OrderListItem;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.purchase.ret.PurchaseReturn;
import com.uten.imp.features.purchase.ret.PurchaseReturnItem;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.purchase.ret.dto.ReturnDetail;
import com.uten.imp.features.purchase.ret.dto.ReturnItemDto;
import com.uten.imp.features.purchase.ret.dto.ReturnListItem;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class PurchaseCommercialPriceVisibilityTest {

    @Mock private CommercialPriceVisibility commercialPriceVisibility;
    @Mock private ProductionSupplySourceGuard productionSourceGuard;
    @Mock private ProcurementApprovalProjectionQuery approvalProjection;
    @Mock private EmployeeNameResolver nameResolver;

    @InjectMocks private PurchaseOrderService orderService;
    @InjectMocks private PurchaseReturnService returnService;

    @BeforeEach
    void denyCommercialPricePermission() {
        when(commercialPriceVisibility.canViewPurchase()).thenReturn(false);
        ReflectionTestUtils.setField(orderService, "commercialPriceVisibility", commercialPriceVisibility);
        ReflectionTestUtils.setField(returnService, "commercialPriceVisibility", commercialPriceVisibility);
    }

    @Test
    void purchaseOrderListAndDetailMaskAllCommercialFields() {
        PurchaseOrder order = new PurchaseOrder();
        order.setId(UUID.randomUUID());
        order.setMakerId(UUID.randomUUID());
        order.setStatus((short) 0);
        order.setCurrencyId(UUID.randomUUID());
        order.setExchangeRate(new BigDecimal("7.2"));
        order.setTaxRate(new BigDecimal("13"));
        order.setSettlementMethodId(UUID.randomUUID());
        order.setSettlementStyleLegacy((short) 6);
        order.setTotalOriginal(new BigDecimal("10"));
        order.setTotalLocal(new BigDecimal("72"));

        PurchaseOrderItem entityItem = new PurchaseOrderItem();
        entityItem.setQty(new BigDecimal("3"));
        entityItem.setPrice(new BigDecimal("10"));
        entityItem.setAmountOriginal(new BigDecimal("30"));
        entityItem.setAmountLocal(new BigDecimal("216"));
        OrderItemDto item = ReflectionTestUtils.invokeMethod(orderService, "toItemDto", entityItem);

        OrderDetail detail = ReflectionTestUtils.invokeMethod(
                orderService, "toDetail", order, List.of(item));
        OrderListItem listItem = ReflectionTestUtils.invokeMethod(
                orderService, "toList", order, null, true);

        assertTrue(detail.isPriceMasked());
        assertNull(detail.getCurrencyId());
        assertNull(detail.getExchangeRate());
        assertNull(detail.getTaxRate());
        assertNull(detail.getSettlementMethodId());
        assertNull(detail.getSettlementStyleLegacy());
        assertNull(detail.getTotalOriginal());
        assertNull(detail.getTotalLocal());
        assertNull(detail.getItems().getFirst().getPrice());
        assertNull(detail.getItems().getFirst().getAmountOriginal());
        assertNull(detail.getItems().getFirst().getAmountLocal());
        assertEquals(new BigDecimal("3"), detail.getItems().getFirst().getQty());
        assertTrue(listItem.isPriceMasked());
        assertNull(listItem.getTotalLocal());
    }

    @Test
    void purchaseReturnListAndDetailMaskAllCommercialFields() {
        PurchaseReturn purchaseReturn = new PurchaseReturn();
        purchaseReturn.setId(UUID.randomUUID());
        purchaseReturn.setMakerId(UUID.randomUUID());
        purchaseReturn.setStatus((short) 0);
        purchaseReturn.setCurrencyId(UUID.randomUUID());
        purchaseReturn.setExchangeRate(new BigDecimal("7.2"));
        purchaseReturn.setTaxRate(new BigDecimal("13"));
        purchaseReturn.setSettlementMethodId(UUID.randomUUID());
        purchaseReturn.setSettlementStyleLegacy((short) 6);
        purchaseReturn.setTotalOriginal(new BigDecimal("10"));
        purchaseReturn.setTotalLocal(new BigDecimal("72"));

        PurchaseReturnItem entityItem = new PurchaseReturnItem();
        entityItem.setQty(new BigDecimal("2"));
        entityItem.setPrice(new BigDecimal("10"));
        entityItem.setAmountOriginal(new BigDecimal("20"));
        entityItem.setAmountLocal(new BigDecimal("144"));
        ReturnItemDto item = ReflectionTestUtils.invokeMethod(returnService, "toItemDto", entityItem);

        ReturnDetail detail = ReflectionTestUtils.invokeMethod(
                returnService, "toDetail", purchaseReturn, List.of(item));
        ReturnListItem listItem = ReflectionTestUtils.invokeMethod(
                returnService, "toList", purchaseReturn, true);

        assertTrue(detail.isPriceMasked());
        assertNull(detail.getCurrencyId());
        assertNull(detail.getExchangeRate());
        assertNull(detail.getTaxRate());
        assertNull(detail.getSettlementMethodId());
        assertNull(detail.getSettlementStyleLegacy());
        assertNull(detail.getTotalOriginal());
        assertNull(detail.getTotalLocal());
        assertNull(detail.getItems().getFirst().getPrice());
        assertNull(detail.getItems().getFirst().getAmountOriginal());
        assertNull(detail.getItems().getFirst().getAmountLocal());
        assertEquals(new BigDecimal("2"), detail.getItems().getFirst().getQty());
        assertTrue(listItem.isPriceMasked());
        assertNull(listItem.getTotalLocal());
    }
}
