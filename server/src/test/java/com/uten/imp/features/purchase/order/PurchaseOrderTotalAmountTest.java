package com.uten.imp.features.purchase.order;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class PurchaseOrderTotalAmountTest {
    @Test void maskedRowsDoNotLeakOriginalTotalOrExactText() {
        var original = org.mockito.Mockito.mock(com.uten.imp.features.purchase.order.dto.OrderItemDto.class);
        org.mockito.Mockito.when(original.getTotalAmountInput()).thenReturn(new BigDecimal("100"));
        var masked = (com.uten.imp.features.purchase.order.dto.OrderItemDto) ReflectionTestUtils.invokeMethod(
                PurchaseOrderService.class, "maskItemPrices", original);
        assertThat(masked.getTotalAmountInput()).isNull();
        assertThat(masked.getTotalAmountInputExact()).isNull();
        assertThat(masked.getPriceExact()).isNull();
        assertThat(masked.getAmountOriginalExact()).isNull();
    }

    @SuppressWarnings("try")
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.CsvSource({"4,HALF_UP","10,DOWN"})
    void financeSubmissionAcceptsExactTotalAndRejectsReferencePriceProduct(int scale,String rounding) throws Exception {
        var order = new PurchaseOrder(); order.setExchangeRate(new BigDecimal("7.1"));
        order.setTotalOriginal(new BigDecimal("100")); order.setTotalLocal(new BigDecimal("710"));
        var item = new PurchaseOrderItem(); item.setQty(new BigDecimal("3000"));
        item.setTotalAmountInput(new BigDecimal("100"));
        try(var choice=com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of("money.reference-unit-price",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(scale,rounding)))){
        item.setPrice(MoneyPolicy.referenceUnitPrice(item.getTotalAmountInput(), item.getQty()));
        }
        order.setId(java.util.UUID.randomUUID());item.setId(java.util.UUID.randomUUID());
        item.setUnitId(java.util.UUID.randomUUID());item.setUnitRate(BigDecimal.ONE);
        order.setQuantitySemantics(com.uten.imp.common.finance.ProcurementQuantities.LEGACY);item.setQuantitySemantics(com.uten.imp.common.finance.ProcurementQuantities.LEGACY);
        var saved=org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementReferencePricePolicyService.class);
        var service=org.mockito.Mockito.mock(PurchaseOrderService.class,org.mockito.Mockito.CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"referencePricePolicies",saved);
        ReflectionTestUtils.setField(service,"em",org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class));
        item.setAmountOriginal(new BigDecimal("100")); item.setAmountLocal(new BigDecimal("710"));
        assertThatCode(() -> ReflectionTestUtils.invokeMethod(service,
                "requireFinanceCommercialAuthority", order, List.of(item))).doesNotThrowAnyException();
        item.setAmountOriginal(item.getQty().multiply(item.getPrice()));
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(service,
                "requireFinanceCommercialAuthority", order, List.of(item))).isInstanceOf(ApiException.class);
        org.mockito.Mockito.verify(saved,org.mockito.Mockito.times(2)).requireSavedOrder("PURCHASE",order.getId());
    }
}
