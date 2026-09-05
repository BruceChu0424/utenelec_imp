package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.quote.SalesQuoteItem;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SalesOrderCommercialAuthorityTest {

    @Test
    void serverComputesOrderAmountFromQuantityAndUnitPrice() {
        assertThat(SalesOrderService.authoritativeOrderAmount(
                new BigDecimal("3.5"), new BigDecimal("12.34")))
                .isEqualByComparingTo("43.1900");
    }

    @Test
    void negativeOrNonPositiveCommercialInputFailsClosed() {
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeOrderAmount(
                        BigDecimal.ZERO, BigDecimal.ONE))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeOrderAmount(
                        BigDecimal.ONE, new BigDecimal("-0.01")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() ->
                SalesOrderService.authoritativeOrderAmount(
                        BigDecimal.ONE, BigDecimal.ONE, new BigDecimal("-0.01")))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void writeDiscountNormalizesLegacyNoDiscountAndPadsToStorageScale() {
        assertThat(SalesOrderService.normalizeOrderDiscountForWrite(null))
                .isEqualByComparingTo("1.0000");
        assertThat(SalesOrderService.normalizeOrderDiscountForWrite(BigDecimal.ZERO))
                .isEqualByComparingTo("1.0000");
        assertThat(SalesOrderService.normalizeOrderDiscountForWrite(new BigDecimal("0.8765")))
                .isEqualByComparingTo("0.8765");
    }

    @Test
    void writeDiscountRejectsSurchargeNegativeAndBelowStoragePrecision() {
        assertThatThrownBy(() -> SalesOrderService.normalizeOrderDiscountForWrite(
                new BigDecimal("1.0001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不大于 1");
        assertThatThrownBy(() -> SalesOrderService.normalizeOrderDiscountForWrite(
                new BigDecimal("-0.1")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> SalesOrderService.normalizeOrderDiscountForWrite(
                new BigDecimal("0.00001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("四位小数");
        assertThatThrownBy(() -> SalesOrderService.normalizeOrderDiscountForWrite(
                new BigDecimal("0.87654")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("四位小数");
    }

    @Test
    void existingDraftLineKeepsItsFrozenPriceOnlyForTheSameUuidAndIdentity() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        SalesOrderItem stored = new SalesOrderItem();
        stored.setGoodsId(goodsId);
        stored.setColorId(colorId);
        stored.setUnitId(unitId);
        stored.setUnitRate(new BigDecimal("10.000000"));
        stored.setPrice(new BigDecimal("12.3400"));

        OrderItemLine unchanged = orderLine(goodsId, colorId, unitId, "10");
        unchanged.setId(stored.getId());
        var prices = new SalesOrderService.ExistingOrderPriceBook(List.of(stored));
        assertThat(prices.take(unchanged)).isEqualByComparingTo("12.3400");
        assertThat(prices.take(unchanged)).isNull();

        OrderItemLine changedGoods = orderLine(
                UUID.randomUUID(), colorId, unitId, "10.000000");
        changedGoods.setId(stored.getId());
        assertThat(new SalesOrderService.ExistingOrderPriceBook(List.of(stored))
                .take(changedGoods)).isNull();
    }

    @Test
    void quoteConversionUsesTheMatchingQuoteSnapshotAndConsumesItOnce() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        SalesQuoteItem quote = new SalesQuoteItem();
        quote.setLineNo(3);
        quote.setGoodsId(goodsId);
        quote.setColorId(colorId);
        quote.setUnitId(unitId);
        quote.setUnitRate(new BigDecimal("1.000000"));
        quote.setPrice(new BigDecimal("8.7500"));

        OrderItemLine line = orderLine(goodsId, colorId, unitId, "1");
        line.setLineNo(3);
        var prices = new SalesOrderService.TrustedQuotePriceBook(List.of(quote));
        assertThat(prices.take(line)).isEqualByComparingTo("8.7500");
        assertThat(prices.take(line)).isNull();
    }

    @Test
    void masterPriceIsRequiredAndClientPreviewMayNotOverrideIt() {
        UUID goodsId = UUID.randomUUID();
        assertThat(SalesOrderService.requireMasterOrderPrice(
                goodsId, new BigDecimal("6.2500")))
                .isEqualByComparingTo("6.2500");
        assertThatThrownBy(() ->
                SalesOrderService.requireMasterOrderPrice(goodsId, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("未维护销售单价");

        OrderItemLine line = new OrderItemLine();
        line.setPrice(new BigDecimal("6.2500"));
        assertThatCode(() -> SalesOrderService.requirePreviewPriceMatches(
                line, new BigDecimal("6.25"))).doesNotThrowAnyException();
        line.setPrice(null);
        assertThatCode(() -> SalesOrderService.requirePreviewPriceMatches(
                line, new BigDecimal("6.25"))).doesNotThrowAnyException();
        line.setPrice(new BigDecimal("6.2400"));
        assertThatThrownBy(() -> SalesOrderService.requirePreviewPriceMatches(
                line, new BigDecimal("6.25")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("单价已变化");
    }

    private static OrderItemLine orderLine(
            UUID goodsId, UUID colorId, UUID unitId, String unitRate) {
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(goodsId);
        line.setColorId(colorId);
        line.setUnitId(unitId);
        line.setUnitRate(new BigDecimal(unitRate));
        return line;
    }
}
