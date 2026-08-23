package com.uten.imp.features.subcontract.ret;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SubcontractReturnAmountAuthorityTest {

    @Test
    void partialReturnUsesSourceProcessingPriceAndRate() {
        var amounts = SubcontractReturnAmountAuthority.sourceAmounts(
                new BigDecimal("1.2500"), new BigDecimal("8.0000"), new BigDecimal("1.234567"),
                new BigDecimal("2.5000"), new BigDecimal("20.0000"), new BigDecimal("24.6913"),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);

        assertThat(amounts.original()).isEqualByComparingTo("10.0000");
        assertThat(amounts.local()).isEqualByComparingTo("12.3457");
    }

    @Test
    void finalSliceAbsorbsTheSourceRoundingTail() {
        var amounts = SubcontractReturnAmountAuthority.sourceAmounts(
                BigDecimal.ONE, new BigDecimal("0.33335"), BigDecimal.ONE,
                new BigDecimal("3"), new BigDecimal("1.0001"), new BigDecimal("1.0001"),
                new BigDecimal("2"), new BigDecimal("0.6668"), new BigDecimal("0.6668"));

        assertThat(amounts.original()).isEqualByComparingTo("0.3333");
        assertThat(amounts.local()).isEqualByComparingTo("0.3333");
    }

    @Test
    void duplicateReceiptLineInOneReturnFailsClosed() {
        UUID receiptItemId = UUID.randomUUID();
        assertThatThrownBy(() -> SubcontractReturnAmountAuthority.requireDistinctReceiptItems(
                List.of(receiptItemId, receiptItemId)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能在一张退货单中重复引用");
    }

    @Test
    void invalidSourceCommercialFactsFailClosed() {
        assertThatThrownBy(() -> SubcontractReturnAmountAuthority.sourceAmounts(
                BigDecimal.ZERO, BigDecimal.ONE, BigDecimal.ONE,
                BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ONE,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("来源数量、加工单价、汇率或历史退货累计无效");
    }
}
