package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.quote.SalesQuoteItem;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-134 报价核定条款簿: 转单时按报价行号精确配对并带出 (单价, 折扣); 之后的修改按商业身份兜底,
 * 行号重排后报价转入的行仍被锁定; 没有单价的历史报价行在修改时不锁(转单时直接拒绝)。
 */
class SalesOrderQuoteTermsBookTest {

    private final UUID goodsA = UUID.randomUUID();
    private final UUID goodsB = UUID.randomUUID();
    private final UUID unit = UUID.randomUUID();

    @Test
    void conversionPairsByQuoteLineAndCarriesTheFinanceDiscount() {
        var book = new SalesOrderService.TrustedQuotePriceBook(
                List.of(quoteLine(1, goodsA, "10", "0.95"), quoteLine(2, goodsB, "8", "1")), "XB1", true);
        List<SalesOrderService.TrustedQuotePriceBook.Terms> terms =
                book.assign(List.of(orderLine(1, goodsA), orderLine(2, goodsB)), true);
        assertThat(terms.get(0).price()).isEqualByComparingTo("10");
        assertThat(terms.get(0).discount()).isEqualByComparingTo("0.95");
        assertThat(terms.get(0).discount().scale()).isEqualTo(4);
        assertThat(terms.get(1).discount()).isEqualByComparingTo("1");
        assertThat(book.quoteBillNo()).isEqualTo("XB1");
    }

    @Test
    void conversionRejectsRenumberedLinesButLaterEditsStillLockThemByIdentity() {
        List<SalesQuoteItem> quote = List.of(quoteLine(1, goodsA, "10", "0.95"), quoteLine(2, goodsB, "8", "0.9"));
        // 转单严格按行号: 行号对不上就没有条款(调用方 409)。
        assertThat(new SalesOrderService.TrustedQuotePriceBook(quote, "XB1", true)
                .assign(List.of(orderLine(5, goodsA)), true)).containsExactly((SalesOrderService.TrustedQuotePriceBook.Terms) null);
        // 修改时: 删掉第一行、第二行重排成 1 号, 再加一行报价外的货品 → B 仍配 0.9, 新货品不锁。
        UUID extra = UUID.randomUUID();
        var terms = new SalesOrderService.TrustedQuotePriceBook(quote, "XB1", false)
                .assign(List.of(orderLine(1, goodsB), orderLine(2, extra)), false);
        assertThat(terms.get(0).discount()).isEqualByComparingTo("0.9");
        assertThat(terms.get(1)).isNull();
    }

    @Test
    void eachQuoteLineLocksAtMostOneOrderLine() {
        var book = new SalesOrderService.TrustedQuotePriceBook(
                List.of(quoteLine(1, goodsA, "10", "0.95")), "XB1", false);
        var terms = book.assign(List.of(orderLine(1, goodsA), orderLine(2, goodsA)), false);
        assertThat(terms.get(0)).isNotNull();
        assertThat(terms.get(1)).as("同货品第二行是报价外新增, 不能共用一条核定").isNull();
    }

    @Test
    void financeListAndReviewShareOneMatchRuleWithOneToOnePairingAndUnitRate() {
        List<SalesQuoteItem> quote = List.of(quoteLine(1, goodsA, "10", "0.92"));
        // 报价转入行一致。
        var single = SalesOrderFinanceConfirmService.matchQuote(quote, "XB1", List.of(
                matchLine(1, goodsA, "1", "10", "0.92")));
        assertThat(single.matches()).containsExactly(true);
        assertThat(single.allLinesMatch()).isTrue();
        // 同货品同价同折扣再加一行: 报价只有一条核定, 第二行不一致(列表不能再显示「一致」)。
        var extraSameGoods = SalesOrderFinanceConfirmService.matchQuote(quote, "XB1", List.of(
                matchLine(1, goodsA, "1", "10", "0.92"), matchLine(2, goodsA, "1", "10", "0.92")));
        assertThat(extraSameGoods.matches()).containsExactly(true, false);
        assertThat(extraSameGoods.allLinesMatch()).isFalse();
        // 换算率不同不是同一条报价核定。
        var otherRate = SalesOrderFinanceConfirmService.matchQuote(quote, "XB1", List.of(
                matchLine(1, goodsA, "12", "10", "0.92")));
        assertThat(otherRate.terms()).containsExactly((SalesOrderService.TrustedQuotePriceBook.Terms) null);
        assertThat(otherRate.allLinesMatch()).isFalse();
        // 空/0 折扣按原价(1)比较; 历史脏折扣算不一致而不是报错。
        var plain = SalesOrderFinanceConfirmService.matchQuote(List.of(quoteLine(1, goodsA, "10", "1")), "XB1",
                List.of(matchLine(1, goodsA, "1", "10", "0")));
        assertThat(plain.allLinesMatch()).isTrue();
        var dirty = SalesOrderFinanceConfirmService.matchQuote(List.of(quoteLine(1, goodsA, "10", "1")), "XB1",
                List.of(matchLine(1, goodsA, "1", "10", "95")));
        assertThat(dirty.matches()).containsExactly(false);
    }

    @Test
    void missingQuotePriceBlocksConversionButIsSkippedWhenEditing() {
        SalesQuoteItem unpriced = quoteLine(1, goodsA, null, "1");
        assertThatThrownBy(() -> new SalesOrderService.TrustedQuotePriceBook(List.of(unpriced), "XB1", true))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("空或负数单价");
        var lenient = new SalesOrderService.TrustedQuotePriceBook(List.of(unpriced), "XB1", false);
        assertThat(lenient.assign(List.of(orderLine(1, goodsA)), false)).containsExactly(
                (SalesOrderService.TrustedQuotePriceBook.Terms) null);
    }

    private SalesQuoteItem quoteLine(int lineNo, UUID goods, String price, String discount) {
        SalesQuoteItem item = new SalesQuoteItem();
        item.setLineNo(lineNo);
        item.setGoodsId(goods);
        item.setUnitId(unit);
        item.setUnitRate(new BigDecimal("1.000000"));
        item.setPrice(price == null ? null : new BigDecimal(price));
        item.setDiscount(new BigDecimal(discount));
        return item;
    }

    private SalesOrderFinanceConfirmService.QuoteMatchLine matchLine(
            int lineNo, UUID goods, String unitRate, String price, String discount) {
        return new SalesOrderFinanceConfirmService.QuoteMatchLine(lineNo, goods, null, unit,
                new BigDecimal(unitRate), new BigDecimal(price), new BigDecimal(discount));
    }

    private OrderItemLine orderLine(int lineNo, UUID goods) {
        OrderItemLine line = new OrderItemLine();
        line.setLineNo(lineNo);
        line.setGoodsId(goods);
        line.setUnitId(unit);
        line.setUnitRate(BigDecimal.ONE);
        return line;
    }
}
