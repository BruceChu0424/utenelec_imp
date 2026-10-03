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

    @Test void financeSubmissionAcceptsExactTotalAndRejectsReferencePriceProduct() {
        var order = new PurchaseOrder(); order.setExchangeRate(new BigDecimal("7.1"));
        order.setTotalOriginal(new BigDecimal("100")); order.setTotalLocal(new BigDecimal("710"));
        var item = new PurchaseOrderItem(); item.setQty(new BigDecimal("3000"));
        item.setTotalAmountInput(new BigDecimal("100"));
        item.setPrice(MoneyPolicy.referenceUnitPrice(item.getTotalAmountInput(), item.getQty()));
        item.setAmountOriginal(new BigDecimal("100")); item.setAmountLocal(new BigDecimal("710"));
        assertThatCode(() -> ReflectionTestUtils.invokeMethod(PurchaseOrderService.class,
                "requireFinanceCommercialAuthority", order, List.of(item))).doesNotThrowAnyException();
        item.setAmountOriginal(item.getQty().multiply(item.getPrice()));
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(PurchaseOrderService.class,
                "requireFinanceCommercialAuthority", order, List.of(item))).isInstanceOf(ApiException.class);
    }
}
