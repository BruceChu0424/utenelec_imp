package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SalesShipmentReverseGuardTest {

    @Test
    void activeReturnedQuantityBlocksShipmentReverse() {
        SalesShipmentItem item = new SalesShipmentItem();
        item.setReturnedQty(new BigDecimal("2"));
        item.setReturnedAmount(BigDecimal.ZERO);

        assertThatThrownBy(() -> SalesShipmentService.requireNoActiveReturn(item))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void activeReturnedAmountAlsoBlocksShipmentReverse() {
        SalesShipmentItem item = new SalesShipmentItem();
        item.setReturnedQty(BigDecimal.ZERO);
        item.setReturnedAmount(new BigDecimal("12.50"));

        assertThatThrownBy(() -> SalesShipmentService.requireNoActiveReturn(item))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void shippedLedgerMustCoverAggregatedReverseQuantity() {
        assertThat(SalesShipmentService.hasSufficientShippedForReverse(
                new BigDecimal("10"), new BigDecimal("10"))).isTrue();
        assertThat(SalesShipmentService.hasSufficientShippedForReverse(
                new BigDecimal("9.9999"), new BigDecimal("10"))).isFalse();
        assertThat(SalesShipmentService.hasSufficientShippedForReverse(
                new BigDecimal("10"), BigDecimal.ZERO)).isFalse();
    }

    @Test
    void linkedDimensionRequiresExactColorUnitAndPositiveRate() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        SalesShipmentService.requireLinkedDimension(
                goodsId, colorId, unitId, BigDecimal.ONE,
                goodsId, colorId, unitId, BigDecimal.ONE, "出货");

        assertThatThrownBy(() -> SalesShipmentService.requireLinkedDimension(
                goodsId, colorId, unitId, BigDecimal.ONE,
                goodsId, UUID.randomUUID(), unitId, BigDecimal.ONE, "出货"))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesShipmentService.requireLinkedDimension(
                goodsId, colorId, unitId, BigDecimal.ZERO,
                goodsId, colorId, unitId, BigDecimal.ONE, "出货"))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void partialShipmentsAllocateTheOrderTotalCumulativelyAndTheLastBatchTakesTheRemainder() {
        // 订单行 3 件共 100: 三次各出 1 件, 应收合计必须恰好 100(旧口径逐批 4 位四舍五入合计 99.9999)。
        BigDecimal total = new BigDecimal("100.0000");
        BigDecimal first = SalesShipmentService.authoritativeShipmentAmount(
                total, new BigDecimal("3"), BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = SalesShipmentService.authoritativeShipmentAmount(
                total, new BigDecimal("3"), BigDecimal.ONE, first, BigDecimal.ONE);
        BigDecimal third = SalesShipmentService.authoritativeShipmentAmount(
                total, new BigDecimal("3"), new BigDecimal("2"), first.add(second), BigDecimal.ONE);
        // 累计份额 33.3333 / 66.6667, 本批 = 累计份额差, 末批取余。
        assertThat(first).isEqualByComparingTo("33.3333");
        assertThat(second).isEqualByComparingTo("33.3334");
        assertThat(third).isEqualByComparingTo("33.3333");
        assertThat(first.add(second).add(third)).isEqualByComparingTo(total);
    }

    @Test
    void exactPriceOrderSplitsIntoExactProductsWithoutAnyRounding() {
        // 订单行金额 = 10 × 12.345 = 123.45: 部分出货 3 件就是 3 × 12.345 = 37.035, 不再截成 4 位。
        BigDecimal total = new BigDecimal("123.45");
        BigDecimal partial = SalesShipmentService.authoritativeShipmentAmount(
                total, BigDecimal.TEN, BigDecimal.ZERO, BigDecimal.ZERO, new BigDecimal("3"));
        BigDecimal rest = SalesShipmentService.authoritativeShipmentAmount(
                total, BigDecimal.TEN, new BigDecimal("3"), partial, new BigDecimal("7"));
        assertThat(partial).isEqualByComparingTo("37.035");
        assertThat(partial.add(rest)).isEqualByComparingTo(total);
    }

    @Test
    void shipmentBeyondTheOrderOrWithInvalidSourceFailsClosed() {
        assertThatThrownBy(() -> SalesShipmentService.authoritativeShipmentAmount(
                new BigDecimal("-1"), BigDecimal.TEN, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ONE))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesShipmentService.authoritativeShipmentAmount(
                BigDecimal.TEN, BigDecimal.TEN, new BigDecimal("9.5"), BigDecimal.ONE, BigDecimal.ONE))
                .isInstanceOf(ApiException.class);
    }
}
