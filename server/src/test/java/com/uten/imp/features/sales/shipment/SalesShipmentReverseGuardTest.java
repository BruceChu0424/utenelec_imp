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
    void partialShipmentAmountComesFromAuthoritativeOrderTotal() {
        assertThat(SalesShipmentService.authoritativeShipmentAmount(
                new BigDecimal("123.45"),
                new BigDecimal("10"),
                new BigDecimal("3")))
                .isEqualByComparingTo("37.0350");

        assertThatThrownBy(() ->
                SalesShipmentService.authoritativeShipmentAmount(
                        new BigDecimal("-1"),
                        BigDecimal.TEN,
                        BigDecimal.ONE))
                .isInstanceOf(ApiException.class);
    }
}
