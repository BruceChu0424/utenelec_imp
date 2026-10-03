package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.*;

class OrderAmountInputResponseTest {
    @Test void exactCompanionsPreserveNumbersBeyondJavascriptPrecision() throws Exception {
        var response = new OrderAmountInputResponse() {
            public BigDecimal getQty() { return new BigDecimal("3000"); }
            public BigDecimal getPrice() { return new BigDecimal("0.0333333333"); }
            public BigDecimal getAmountOriginal() { return new BigDecimal("100.000000000000000000000001"); }
            public BigDecimal getAmountLocal() { return null; }
        };
        response.setTotalAmountInput(response.getAmountOriginal());
        var json = new ObjectMapper().valueToTree(response);
        assertThat(json.get("totalAmountInputExact").textValue()).isEqualTo("100.000000000000000000000001");
        assertThat(json.get("amountOriginalExact").textValue()).isEqualTo("100.000000000000000000000001");
        assertThat(json.get("priceExact").textValue()).isEqualTo("0.0333333333");
        assertThat(json.get("qtyExact").textValue()).isEqualTo("3000");
        assertThat(json.get("amountLocalExact").isNull()).isTrue();
    }
}
