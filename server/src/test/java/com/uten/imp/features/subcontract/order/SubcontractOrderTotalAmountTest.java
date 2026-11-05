package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.finance.ProcurementReferencePrice;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class SubcontractOrderTotalAmountTest {
    @Test void maskedRowsDoNotLeakOriginalTotalOrExactText() {
        var original = org.mockito.Mockito.mock(com.uten.imp.features.subcontract.order.dto.OrderItemDto.class);
        org.mockito.Mockito.when(original.getTotalAmountInput()).thenReturn(new BigDecimal("100"));
        var masked = (com.uten.imp.features.subcontract.order.dto.OrderItemDto) ReflectionTestUtils.invokeMethod(
                SubcontractOrderService.class, "maskItemPrices", original);
        assertThat(masked.getTotalAmountInput()).isNull();
        assertThat(masked.getTotalAmountInputExact()).isNull();
        assertThat(masked.getPriceExact()).isNull();
        assertThat(masked.getAmountOriginalExact()).isNull();
    }

    @Test void financeSubmissionAcceptsExactTotalAndRejectsReferencePriceProduct() throws Exception {
        // 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）：100/3000 除不尽，
        // 参考单价按四位 HALF_UP 反推（仅作一致性校验，不得回乘为货款）。
        try (var ignored = com.uten.imp.common.finance.BusinessPrecisionContext.use(java.util.Map.of(
                "money.reference-unit-price", new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(4, "HALF_UP")))) {
            var order = new SubcontractOrder(); order.setExchangeRate(new BigDecimal("7.1"));
            order.setTotalOriginal(new BigDecimal("100")); order.setTotalLocal(new BigDecimal("710"));
            var item = new SubcontractOrderItem(); item.setQty(new BigDecimal("3000"));
            // 2026-11-04 数量采用契约（0aaffa3aa/d533807ca V1033 范式）：送审校验需要单位换算率。
            item.setUnitRate(BigDecimal.ONE);
            item.setTotalAmountInput(new BigDecimal("100"));
            var reference = ProcurementReferencePrice.adopt(item.getTotalAmountInput(), item.getQty());
            item.setPrice(reference.price());
            item.setReferencePricePrecisionPolicy(reference.policy());
            item.setAmountOriginal(new BigDecimal("100")); item.setAmountLocal(new BigDecimal("710"));
            assertThatCode(() -> ReflectionTestUtils.invokeMethod(SubcontractOrderService.class,
                    "requireFinanceCommercialAuthority", order, List.of(item))).doesNotThrowAnyException();
            item.setAmountOriginal(item.getQty().multiply(item.getPrice()));
            assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(SubcontractOrderService.class,
                    "requireFinanceCommercialAuthority", order, List.of(item))).isInstanceOf(ApiException.class);
        }
    }
}
