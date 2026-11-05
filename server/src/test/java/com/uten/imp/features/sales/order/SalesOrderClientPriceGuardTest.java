package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesPriceAuthority.FileCurrency;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 订货单服务端拦截(ADR-134): 带客户文件单价的行, 货品没有标价(0)或文件单价高于标价时不能直接下订货单
 * (与识别导入在订货单上的拦截同口径, 直接调接口也一样); 报价转来、财务核定单价的行不拦。
 */
class SalesOrderClientPriceGuardTest {

    private static final FileCurrency BASE = new FileCurrency(null, true, BigDecimal.ONE);
    private static final FileCurrency USD = new FileCurrency("USD", false, new BigDecimal("7.1"));
    private static final FileCurrency USD_NO_RATE = new FileCurrency("USD", false, null);

    private static OrderItemLine line(String clientPrice) {
        OrderItemLine line = new OrderItemLine();
        line.setClientPrice(clientPrice == null ? null : new BigDecimal(clientPrice));
        return line;
    }

    private static void check(OrderItemLine line, SalesOrderService.TrustedQuotePriceBook.Terms quoted, String list,
                              FileCurrency currency) {
        SalesOrderService.requireOrderableClientPrice(line, quoted, new BigDecimal(list), currency, 3);
    }

    @Test
    void zeroListPriceWithAClientPriceIsBlocked() {
        assertThatThrownBy(() -> check(line("5"), null, "0", BASE))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("第 3 行").hasMessageContaining("报价单")
                .extracting(e -> ((ApiException) e).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThatCode(() -> check(line(null), null, "0", BASE)).as("没有文件单价的 0 价货品照旧")
                .doesNotThrowAnyException();
    }

    @Test
    void clientPriceAboveListIsBlockedOnTheComputedDiscount() {
        // 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）改写：MoneyPolicy 精确商原样保留，
        // 不再统一取四位；10.0004 / 10 = 1.00004 > 1 按高于标价拦下（旧契约四舍五入成 1 折放行的口径作废）。
        assertThatThrownBy(() -> check(line("10.01"), null, "10", BASE)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> check(line("10.0004"), null, "10", BASE)).as("精确商 1.00004 高于标价")
                .isInstanceOf(ApiException.class);
        assertThatCode(() -> check(line("9"), null, "10", BASE)).doesNotThrowAnyException();
    }

    @Test
    void foreignFilesAreAboveListOnlyWhenBothReadingsAre() {
        assertThatCode(() -> check(line("1.2"), null, "10", USD)).as("1.2 美元 × 7.1 < 10").doesNotThrowAnyException();
        assertThatThrownBy(() -> check(line("12"), null, "10", USD)).isInstanceOf(ApiException.class);
        assertThatCode(() -> check(line("12"), null, "10", USD_NO_RATE)).as("没有参考汇率判断不了, 不拦")
                .doesNotThrowAnyException();
    }

    @Test
    void quoteDerivedLinesKeepFinancePrices() {
        SalesOrderService.TrustedQuotePriceBook.Terms gift =
                new SalesOrderService.TrustedQuotePriceBook.Terms(BigDecimal.ZERO, BigDecimal.ONE);
        assertThatCode(() -> check(line("5"), gift, "0", BASE)).doesNotThrowAnyException();
    }
}
